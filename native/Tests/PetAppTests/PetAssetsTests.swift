import AppKit
import PetCore
import Testing
@testable import DSHNativePet

@Suite("角色素材", .serialized)
@MainActor
struct PetAssetsTests {
    @Test func bundledResourcesLoadAllNinePoses() throws {
        let assets = try PetAssets()
        try assets.validateAll()
        #expect(assets.manifest.poses.count == PetPose.allCases.count)
        for pose in PetPose.allCases {
            let image = try assets.image(for: pose)
            #expect(image.cgImage.width > 0)
            #expect(image.cgImage.height > 0)
            #expect((0...1).contains(image.anchor.x))
            #expect((0...1).contains(image.anchor.y))
        }
    }

    @Test func anchorKeepsFootAtSharedBaseline() throws {
        _ = NSApplication.shared
        let assets = try PetAssets()
        let view = PetView(assets: assets)
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        for pose in PetPose.allCases {
            try view.render(pose: pose, text: "")
            view.layoutSubtreeIfNeeded()
            #expect(abs(view.characterLayer.position.y - 8) < 0.001)
            #expect(abs(view.characterLayer.position.x - 110) < 0.001)
            let image = try assets.image(for: pose)
            #expect(abs(view.characterLayer.anchorPoint.y - (1 - image.anchor.y)) < 0.001)
            let scale = view.characterLayer.bounds.height / CGFloat(image.cgImage.height)
            #expect(abs(image.visibleBounds.height * scale - 100) < 0.001)
        }
    }

    @Test func invalidManifestIsRejectedAtIOBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"canvas\":{\"width\":1024,\"height\":1024},\"poses\":{}}".utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try PetAssets(directory: root) }
    }

    @Test func allSizesReserveRoomForStatusAndJump() throws {
        _ = NSApplication.shared
        let assets = try PetAssets()
        let view = PetView(assets: assets)
        for size in PetPreferences.Size.allCases {
            view.characterHeight = size.characterHeight
            view.frame = NSRect(origin: .zero, size: size.panelSize)
            for pose in PetPose.allCases {
                try view.render(pose: pose, text: "状态")
                view.layoutSubtreeIfNeeded()
                let image = try assets.image(for: pose)
                let scale = view.characterLayer.bounds.height / CGFloat(image.cgImage.height)
                let top = view.characterLayer.position.y + (image.anchor.y * CGFloat(image.cgImage.height) - image.visibleBounds.minY) * scale
                #expect(top + 9 <= size.panelSize.height - 34 + 0.001)
                #expect(abs(image.visibleBounds.height * scale - size.characterHeight) < 0.001)
                #expect(image.visibleBounds.height * scale <= 150.001)
            }
        }
    }

    @Test func stopRemovesAnimationsAndReenablesSamePose() {
        let layer = CALayer()
        let animator = PetAnimator(layer: layer)
        animator.render(pose: .working, animated: true)
        #expect(layer.animationKeys()?.isEmpty == false)
        animator.stop()
        #expect(layer.animationKeys()?.isEmpty != false)
        animator.render(pose: .working, animated: true)
        #expect(layer.animationKeys()?.isEmpty == false)
        animator.render(pose: .sleeping, animated: true)
        #expect(layer.animationKeys()?.isEmpty != false)
    }

    @Test func waitingMessageWrapsWithinFixedTwoLineFrame() throws {
        _ = NSApplication.shared
        let view = PetView(assets: try PetAssets())
        view.frame = NSRect(origin: .zero, size: PetPreferences.Size.medium.panelSize)
        try view.render(pose: .waiting, text: "1 个会话待处理，请查看 DSH")
        view.layoutSubtreeIfNeeded()
        let label = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(label.maximumNumberOfLines == 2)
        #expect(label.cell?.usesSingleLineMode == false)
        #expect(label.cell?.isScrollable == false)
        #expect(label.cell?.wraps == true)
        #expect(label.lineBreakMode == .byWordWrapping)
        #expect(label.font?.pointSize == 11)
        #expect(label.frame.size == NSSize(width: 126, height: 30))
        let measured = try #require(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 126, height: 1000)))
        #expect(measured.height > 20)
        #expect(measured.height <= 30)
        #expect(view.frame.size == PetPreferences.Size.medium.panelSize)
    }
}
