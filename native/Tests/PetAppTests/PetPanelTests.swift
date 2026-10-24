import AppKit
import Testing
@testable import DSHNativePet

@Suite("原生窗口", .serialized)
@MainActor
struct PetPanelTests {
    @Test func nonactivatingTransparentPanel() {
        _ = NSApplication.shared
        let panel = PetPanel(frame: NSRect(x: 10, y: 10, width: 220, height: 220))
        defer { panel.close() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.level == .floating)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.ignoresMouseEvents = true
        #expect(panel.ignoresMouseEvents)
        panel.ignoresMouseEvents = false
        #expect(!panel.ignoresMouseEvents)
    }

    @Test func constrainIncludesNegativeCoordinateDisplays() {
        let screen = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = NSRect(x: -2000, y: 1000, width: 220, height: 220)
        let constrained = PetPanel.constrain(frame, to: screen)
        #expect(constrained.minX == -1920)
        #expect(constrained.maxY == screen.maxY)
        #expect(constrained.size == frame.size)
    }

    @Test func oversizedPanelHasStableVisibleOrigin() {
        let area = NSRect(x: 50, y: 50, width: 100, height: 100)
        let result = PetPanel.constrain(NSRect(x: -100, y: 300, width: 280, height: 280), to: area)
        #expect(result.origin == area.origin)
    }

    @Test func preferencesPersistWithoutTaskState() {
        let name = "PetAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PetPreferences(defaults: defaults)
        #expect(preferences.visible)
        #expect(preferences.animations)
        #expect(preferences.size == .medium)
        #expect(preferences.size.characterHeight == 100)
        #expect(preferences.size.panelSize == NSSize(width: 140, height: 154))
        preferences.clickThrough = true
        preferences.size = .large
        preferences.visible = false
        let restored = PetPreferences(defaults: defaults)
        #expect(restored.clickThrough)
        #expect(restored.size == .large)
        #expect(!restored.visible)
        #expect(restored.restoredFrame(size: NSSize(width: 220, height: 220), screens: []).origin == .zero)
    }
}
