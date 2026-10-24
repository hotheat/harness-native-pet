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
        #expect(view.displayText == "1 个会话待处理，请查看 DSH")
        let twoLineFrame = view.bubbleFrame
        #expect(twoLineFrame.width == 126)
        #expect(twoLineFrame.height > 20)
        #expect(twoLineFrame.height <= 32)
        #expect(twoLineFrame.midY == view.bounds.height - 19)
        try view.render(pose: .waiting, text: "待处理")
        view.layoutSubtreeIfNeeded()
        #expect(twoLineFrame.height - view.bubbleFrame.height >= 10)
        #expect(twoLineFrame.midY == view.bubbleFrame.midY)
        try view.render(pose: .waiting, text: "第一行\n第二行\n第三行")
        view.layoutSubtreeIfNeeded()
        #expect(view.bubbleFrame.height == twoLineFrame.height)
        view.frame.size.width = 220
        try view.render(pose: .waiting, text: "1 个会话待处理，请查看 DSH")
        view.layoutSubtreeIfNeeded()
        #expect(view.bubbleFrame.width == 206)
        #expect(view.bubbleFrame.height < twoLineFrame.height)
        view.frame.size.width = 140
        view.layoutSubtreeIfNeeded()
        #expect(view.bubbleFrame == twoLineFrame)
        #expect(view.frame.size == PetPreferences.Size.medium.panelSize)
    }
}
