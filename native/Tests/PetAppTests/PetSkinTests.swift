import AppKit
import AVFoundation
import Combine
import PetCore
import Testing
@testable import DSHNativePet

@Suite("角色即时切换", .serialized)
@MainActor
struct PetSkinTests {
    @Test func preferencesPersistSkinAndKeepDefaultGirl() {
        let name = "PetSkinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PetPreferences(defaults: defaults)
        #expect(preferences.skin == .character)
        #expect(preferences.size.characterHeight == 100)
        preferences.skin = .dshPet
        #expect(PetPreferences(defaults: defaults).skin == .dshPet)
        preferences.skin = .character
        #expect(PetPreferences(defaults: defaults).skin == .character)
    }

    @Test func defaultTruePreferencesReadBooleansAndStringValues() {
        let cases: [(value: Any?, expected: Bool)] = [
            (nil, true),
            (false, false),
            (true, true),
            ("NO", false),
            ("YES", true),
        ]
        for item in cases {
            let name = "PetSkinTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            if let value = item.value {
                defaults.set(value, forKey: "pet.visible")
                defaults.set(value, forKey: "pet.animations")
            }
            let preferences = PetPreferences(defaults: defaults)
            #expect(preferences.visible == item.expected)
            #expect(preferences.animations == item.expected)
        }
    }

    @Test func bothSkinsKeepSizeAndFootAnchorAcrossNinePoses() throws {
        _ = NSApplication.shared
        for skin in PetSkin.allCases {
            let assets = try PetAssets(skin: skin)
            try assets.validateAll()
            let view = PetView(assets: assets)
            for size in PetPreferences.Size.allCases {
                view.characterHeight = size.characterHeight
                let panelSize = try assets.requiredPanelSize(characterHeight: size.characterHeight)
                #expect(panelSize.width >= size.panelSize.width)
                #expect(panelSize.height >= size.panelSize.height)
                view.frame = NSRect(origin: .zero, size: panelSize)
                for pose in PetPose.allCases {
                    try view.render(pose: pose, text: "状态")
                    view.layoutSubtreeIfNeeded()
                    let image = try assets.image(for: pose)
                    let scale = view.characterLayer.bounds.height / CGFloat(image.cgImage.height)
                    #expect(abs(view.characterLayer.position.y - 8) < 0.001)
                    #expect(abs(view.characterLayer.position.x - panelSize.width / 2) < 0.001)
                    #expect(abs(view.characterLayer.anchorPoint.y - (1 - image.anchor.y)) < 0.001)
                    #expect(abs(image.referenceHeight * scale - size.characterHeight) < 0.001)
                    let top = 8 + (image.anchor.y * CGFloat(image.cgImage.height) - image.visibleBounds.minY) * scale
                    #expect(top <= panelSize.height - 44 + 0.001)
                    let anchorX = image.anchor.x * CGFloat(image.cgImage.width)
                    let left = panelSize.width / 2 + (image.visibleBounds.minX - anchorX) * scale
                    let right = panelSize.width / 2 + (image.visibleBounds.maxX - anchorX) * scale
                    let bottom = 8 + (image.anchor.y * CGFloat(image.cgImage.height) - image.visibleBounds.maxY) * scale
                    #expect(left >= 7 - 0.001)
                    #expect(right <= panelSize.width - 7 + 0.001)
                    #expect(bottom >= 0)
                    #expect(view.videoPlayback.isActive == false)
                    #expect((assets.videoURL(for: pose) != nil) == (skin == .dshPet))
                }
            }
        }
    }

    @Test func defaultDSHIdleBodyMeasuresExactly100Points() throws {
        _ = NSApplication.shared
        let assets = try PetAssets(skin: .dshPet)
        let image = try assets.image(for: .idle)
        #expect(image.referenceHeight == 265)
        let view = PetView(assets: assets)
        view.frame = NSRect(origin: .zero, size: try assets.requiredPanelSize(characterHeight: 100))
        try view.render(pose: .idle, text: "状态")
        view.layoutSubtreeIfNeeded()
        let scale = view.characterLayer.bounds.height / CGFloat(image.cgImage.height)
        #expect(abs(265 * scale - 100) < 0.001)
        #expect(image.visibleBounds.height * scale > 122)
        #expect(view.frame.height > PetPreferences.Size.medium.panelSize.height)
        let effectTop = 8 + (image.anchor.y * CGFloat(image.cgImage.height) - image.visibleBounds.minY) * scale
        #expect(view.bubbleFrame.minY - effectTop >= 10)
    }

    @Test func menuPreferencesSwitchSamePoseWithoutResettingDSHState() throws {
        _ = NSApplication.shared
        let name = "PetSkinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PetPreferences(defaults: defaults)
        let menu = StatusMenu(preferences: preferences)
        let girl = try PetAssets()
        let dsh = try PetAssets(skin: .dshPet)
        let view = PetView(assets: girl)
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 154)
        let store = PetStore()
        store.apply(SourceSnapshot(sourceId: "skin-test", sourceLabel: "DSH", seq: 1, sessions: [
            SessionSnapshot(sessionId: "keep-session", turn: 2, phase: .working, activeTools: 1, pendingApprovals: 0, result: nil),
        ]))
        let state = store.presentation()
        for skin in [PetSkin.character, .dshPet, .character] {
            menu.selectSkin(skin)
            view.useAssets(preferences.skin == .character ? girl : dsh)
            try view.render(pose: store.presentation().pose, text: PetMessageProjector.bubble(state, pose: state.pose, bubbleWidth: view.bounds.width - 14))
            view.layoutSubtreeIfNeeded()
            #expect(view.skin == skin)
            #expect(view.currentPose == .working)
            #expect(view.characterLayer.contents != nil)
            #expect(view.characterHeight == 100)
            #expect(view.frame == NSRect(x: 0, y: 0, width: 140, height: 154))
            #expect(store.presentation().sessions.map(\.session.sessionId) == ["keep-session"])
            #expect(store.presentation().activeCount == state.activeCount)
        }
    }

    @Test func videoDecodesTransparentFramesAndReleasesOnAnimationOffAndSkinSwitch() async throws {
        _ = NSApplication.shared
        let girl = try PetAssets()
        let dsh = try PetAssets(skin: .dshPet)
        let panel = PetPanel(frame: NSRect(origin: NSPoint(x: 30, y: 30), size: try dsh.requiredPanelSize(characterHeight: 100)))
        let view = PetView(assets: dsh)
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { view.stopVideo(); panel.close() }
        try view.render(pose: .working, text: "执行中", animated: true)
        view.layoutSubtreeIfNeeded()
        weak var oldPlayer = view.videoPlayback.player
        weak var oldLayer = view.videoPlayback.videoLayer
        var decoded: PetVideoPlayback.DecodedFrame?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            if view.videoPlayback.hasDecodedFrame, let frame = view.videoPlayback.decodedFrame(), frame.time > 0.1 {
                decoded = frame
                break
            }
        }
        let first = try #require(decoded)
        #expect(first.transparentPixels > 0)
        #expect(first.opaquePixels > 0)
        for _ in 0..<40 {
            if view.characterLayer.contents == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(view.characterLayer.contents == nil)
        try await Task.sleep(for: .milliseconds(350))
        let second = try #require(view.videoPlayback.decodedFrame())
        #expect(second.time > first.time)
        #expect(first.image.dataProvider?.data != second.image.dataProvider?.data)
        try view.render(pose: .working, text: "执行中", animated: false)
        #expect(!view.videoPlayback.isActive)
        #expect(view.videoPlayback.videoLayer == nil)
        #expect(view.characterLayer.contents != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(oldPlayer == nil)
        #expect(oldLayer == nil)
        try view.render(pose: .working, text: "执行中", animated: true)
        #expect(view.videoPlayback.isActive)
        view.useAssets(girl)
        try view.render(pose: .working, text: "执行中", animated: true)
        #expect(!view.videoPlayback.isActive)
        #expect(view.currentPose == .working)
        #expect(view.skin == .character)
        // 让旧的KVO任务获得执行机会，不能清除新人物PNG或重新创建播放器。
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.characterLayer.contents != nil)
        #expect(!view.videoPlayback.isActive)
        view.useAssets(dsh)
        try view.render(pose: .waiting, text: "等待", animated: true)
        #expect(view.videoPlayback.isActive)
        view.stopVideo()
        #expect(!view.videoPlayback.isActive)
        #expect(view.videoPlayback.videoLayer == nil)
        #expect(view.characterLayer.contents != nil)
    }
}
