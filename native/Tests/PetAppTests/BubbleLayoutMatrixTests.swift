import AppKit
import PetCore
import SwiftUI
import Testing
@testable import DSHNativePet

@Suite("气泡布局矩阵", .serialized)
@MainActor
struct BubbleLayoutMatrixTests {
    @Test func titleMatrixFitsTwoLinesWithoutClipping() throws {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for skin in PetSkin.allCases {
            let assets = try PetAssets(skin: skin)
            let view = PetView(assets: assets)
            view.frame = NSRect(origin: .zero, size: try assets.requiredPanelSize(characterHeight: 100))
            for count in [6, 10, 15, 18, 30, 64] {
                let title = String(repeating: "中", count: count)
                for (scenario, presentation) in presentations(title: title) {
                    let text = PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: view.bounds.width - 14)
                    try view.render(pose: presentation.pose, text: text)
                    view.layoutSubtreeIfNeeded()
                    // PetView gives the hosting view bounds.width - 14; SwiftUI adds 7pt on each side.
                    let bubbleWidth = view.bounds.width - 14
                    let textWidth = bubbleWidth - 14
                    let storage = NSTextStorage(string: view.displayText, attributes: [.font: font])
                    let layout = NSLayoutManager()
                    let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
                    container.lineFragmentPadding = 0
                    layout.addTextContainer(container)
                    storage.addLayoutManager(layout)
                    layout.ensureLayout(for: container)
                    let glyphs = layout.glyphRange(for: container)
                    var lines = 0
                    layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
                    let measured = (view.displayText as NSString).boundingRect(
                        with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                    let height = max(measured.height, layout.usedRect(for: container).height) + 4
                    let sample = "\(skin.rawValue) / \(count)字 / \(scenario): width=\(bubbleWidth), lines=\(lines), height=\(height), frame=\(view.bubbleFrame.height), text=\(text.debugDescription)"
                    print("BubbleLayoutMatrix \(sample)")
                    #expect(view.displayText == text, Comment(rawValue: sample))
                    #expect(view.bubbleFrame.width == bubbleWidth, Comment(rawValue: sample))
                    #expect(lines <= 2, Comment(rawValue: sample))
                    #expect(height <= 32, Comment(rawValue: sample))
                    // The unlimited SwiftUI reference detects actual lineLimit/clamp clipping;
                    // AppKit and SwiftUI can choose different punctuation line breaks.
                    let unlimited = NSHostingView(rootView: Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2).padding(.horizontal, 7)
                        .frame(width: bubbleWidth))
                    #expect(unlimited.fittingSize.height <= 32, Comment(rawValue: sample))
                    #expect(unlimited.fittingSize.height <= view.bubbleFrame.height, Comment(rawValue: sample))
                    #expect(glyphs.length == layout.numberOfGlyphs, Comment(rawValue: sample))
                    #expect(view.bubbleFrame.height > 0 && view.bubbleFrame.height <= 32, Comment(rawValue: sample))
                    #expect(view.bubbleFrame.midY == view.bounds.height - 19, Comment(rawValue: sample))
                }
            }
        }
    }

    @Test func fittingUsesWidthAndPreservesGraphemeBoundaries() {
        let narrowWidth = PetPreferences.Size.small.panelSize.width - 14
        let wideWidth = PetPreferences.Size.large.panelSize.width - 14
        for grapheme in ["中", "e\u{0301}", "👩‍💻"] {
            let title = String(repeating: grapheme, count: 64)
            var counts: [Int] = []
            for width in [narrowWidth, wideWidth] {
                let text = PetBubbleFit.text(title: title, status: "已完成", bubbleWidth: width)
                #expect(text.hasPrefix("「") && text.hasSuffix("…」已完成"))
                let retained = String(text.dropFirst().dropLast("…」已完成".count))
                #expect(!retained.isEmpty)
                #expect(retained.allSatisfy { String($0) == grapheme })
                counts.append(retained.count)
            }
            #expect(counts[1] > counts[0])
        }
    }

    private func presentations(title: String) -> [(String, PetPresentation)] {
        let now = Date(timeIntervalSince1970: 1000)
        var result: [(String, PetPresentation)] = []
        for scenario in ["等待", "完成", "并行完成"] {
            let store = PetStore()
            func session(_ phase: SessionPhase, result: SessionResult? = nil) -> SessionSnapshot {
                SessionSnapshot(sessionId: "title", turn: 1, phase: phase, activeTools: 0,
                                pendingApprovals: phase == .waiting ? 1 : 0, result: result, title: title)
            }
            let others = scenario == "并行完成" ? [SessionSnapshot(sessionId: "other", turn: 1, phase: .working,
                                                                 activeTools: 1, pendingApprovals: 0, result: nil)] : []
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1,
                                       sessions: [session(scenario == "等待" ? .waiting : .thinking)] + others), at: now)
            if scenario != "等待" {
                store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 2,
                                           sessions: [session(.completed, result: SessionResult(id: "done", outcome: "completed"))] + others), at: now)
            }
            result.append((scenario, store.presentation(at: now)))
        }
        return result
    }
}
