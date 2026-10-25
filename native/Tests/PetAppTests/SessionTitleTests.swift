import AppKit
import PetCore
import Testing
@testable import DSHNativePet

@Suite("会话标题呈现", .serialized)
@MainActor
struct SessionTitleTests {
    private let now = Date(timeIntervalSince1970: 1000)

    private func session(_ id: String, _ title: String?, phase: SessionPhase = .waiting,
                         result: SessionResult? = nil) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, turn: 1, phase: phase, activeTools: 0,
                        pendingApprovals: phase == .waiting ? 1 : 0, result: result, title: title)
    }

    private func state(_ sessions: [SessionSnapshot]) -> PetPresentation {
        let store = PetStore()
        store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1, sessions: sessions), at: now)
        return store.presentation(at: now)
    }

    @Test func waitingTitlesRespectCountsAndUseOnlyTheFirstAvailableTitle() {
        let cases: [([SessionSnapshot], String)] = [
            ([session("a", "修复登录")], "「修复登录」等待确认"),
            ([session("a", "修复登录"), session("b", nil, phase: .working)], "「修复登录」等待确认，1 个仍在执行"),
            ([session("a", "登录"), session("b", "搜索")], "「登录」等 2 个待处理"),
            ([session("a", nil), session("b", "搜索"), session("c", nil, phase: .thinking)], "「搜索」等 2 个待处理"),
            ([session("a", "一"), session("b", "二"), session("c", "三"), session("d", "四")], "「一」等 4 个待处理"),
        ]
        for (sessions, expected) in cases {
            let presentation = state(sessions)
            #expect(PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == expected)
        }
        for sessions in [[session("a", nil)], [session("a", nil), session("b", nil)]] {
            let presentation = state(sessions)
            #expect(PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "\(presentation.waitingCount) 个会话待处理，请查看 DSH")
        }
    }

    @Test func titlesAreFlattenedAndTruncatedOnlyInApplication() {
        #expect(PetMessageProjector.sessionTitle(" 标题\n下一行\t项目 ", limit: 40) == "标题 下一行 项目")
        #expect(PetMessageProjector.sessionTitle("\n\t", limit: 18) == nil)
        #expect(PetMessageProjector.sessionTitle(String(repeating: "中", count: 18), limit: 18) == String(repeating: "中", count: 18))
        let long = String(repeating: "中", count: 41)
        let single = state([session("a", long)])
        #expect(single.sessions.first?.session.title == long)
        #expect(PetMessageProjector.bubble(single, pose: .waiting, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "「\(String(repeating: "中", count: 13))…」等待确认")
        let multiple = state([session("a", long), session("b", "短标题")])
        #expect(PetMessageProjector.bubble(multiple, pose: .waiting, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "「\(String(repeating: "中", count: 11))…」等 2 个待处理")
        let model = PetStatusModel()
        model.update(single)
        #expect(model.sessionRows.first?.title == "DSH · \(String(repeating: "中", count: 40))…")
        #expect(model.sessionRows.first?.detail == "等待决定，请在宿主查看 · 工具 0 · 待决定 1")
        model.update(multiple)
        #expect(model.sessionRows.count == 2)
        #expect(model.sessionRows.last?.title == "DSH · 短标题")
        model.update(state([session("1234567890abcdefghijklmnopqrstuvwxyz", nil)]))
        #expect(model.sessionRows.first?.title == "DSH · 1234567890abcdefghijklmnopqrst")
    }

    @Test func completedTitleWorksAloneAndAlongsideOtherActivity() {
        for phase in [SessionPhase.idle, .working, .thinking, .waiting] {
            let store = PetStore()
            let other = session("other", "其他", phase: phase)
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1,
                                       sessions: [session("done", "整理资料", phase: .thinking), other]), at: now)
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 2,
                                       sessions: [session("done", "整理资料", phase: .completed,
                                                          result: SessionResult(id: "r", outcome: "completed")), other]), at: now)
            let presentation = store.presentation(at: now)
            let expected: String
            switch phase {
            case .working: expected = "「整理资料」\n本轮结束 · 1 执行中"
            case .thinking: expected = "「整理资料」\n本轮结束 · 1 思考中"
            case .waiting: expected = "「其他」等待确认"
            default: expected = "「整理资料」已完成"
            }
            #expect(PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == expected)
        }
        let long = String(repeating: "中", count: 30)
        let completed = PresentedFeedback(pose: .completed, kind: .completed, sourceLabel: "DSH", title: long)
        for (pose, activeCount, expected) in [(PetPose.completed, 0, "「\(String(repeating: "中", count: 14))…」已完成"),
                                               (.working, 1, "「\(String(repeating: "中", count: 8))…」\n本轮结束 · 1 执行中"),
                                               (.thinking, 1, "「\(String(repeating: "中", count: 8))…」\n本轮结束 · 1 思考中")] {
            let presentation = PetPresentation(pose: pose, activeCount: activeCount,
                                               waitingCount: 0, connectedSources: 1, sessions: [], feedback: completed)
            #expect(PetMessageProjector.bubble(presentation, pose: pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == expected)
        }
        for provider in [PetProvider.codex, .claudeCode] {
            let store = PetStore()
            store.apply(PetActivityEvent(provider: provider, sessionId: "s", turnId: "t", eventId: "end",
                                         kind: .turnEnded, occurredAt: 1000, toolId: nil, label: "project"), at: now)
            let presentation = store.presentation(at: now)
            #expect(PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "「project」已完成")
        }
    }

    @Test func otherPosesAndNonCompletedFeedbackKeepExistingText() {
        for kind in [PetActivityKind.failed, .interrupted, .turnStarted, .running] {
            let store = PetStore()
            store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "e",
                                         kind: kind, occurredAt: 1000, toolId: nil, label: "project"), at: now)
            let presentation = store.presentation(at: now)
            let expected: String
            switch kind {
            case .failed: expected = "本轮回应出错，请查看 Codex"
            case .interrupted: expected = "Codex：本轮回应已中断"
            case .turnStarted: expected = "正在思考"
            default: expected = "1 个会话正在执行"
            }
            #expect(PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == expected)
            #expect(PetMessageProjector.bubble(presentation, pose: .sleeping, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "休息中")
        }
    }

    @Test func titleBubblesRenderWithinExistingFrames() throws {
        _ = NSApplication.shared
        var presentations = [
            state([session("a", "重构会话标题")]),
            state([session("a", "重构会话标题"), session("b", "harness-native-pet")]),
            state([session("a", "harness-native-pet")]),
        ]
        let store = PetStore()
        store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "end",
                                     kind: .turnEnded, occurredAt: 1000, toolId: nil, label: "harness-native-pet"), at: now)
        presentations.append(store.presentation(at: now))
        store.apply(PetActivityEvent(provider: .claudeCode, sessionId: "other", turnId: "t", eventId: "start",
                                     kind: .running, occurredAt: 1000, toolId: nil), at: now)
        presentations.append(store.presentation(at: now))
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        for skin in PetSkin.allCases {
            let assets = try PetAssets(skin: skin)
            let view = PetView(assets: assets)
            view.frame = NSRect(origin: .zero, size: try assets.requiredPanelSize(characterHeight: 100))
            for presentation in presentations {
                let text = PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: view.bounds.width - 14)
                try view.render(pose: presentation.pose, text: text)
                view.layoutSubtreeIfNeeded()
                #expect(view.displayText == text)
                #expect(view.bubbleFrame.height > 0 && view.bubbleFrame.height <= 32)
                #expect(view.bubbleFrame.midY == view.bounds.height - 19)
                let textBounds = (text as NSString).boundingRect(
                    with: NSSize(width: view.bounds.width - 28, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                #expect(textBounds.height <= lineHeight * 2, Comment(rawValue: text))
            }
        }
    }
}
