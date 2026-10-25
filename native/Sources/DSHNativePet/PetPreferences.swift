import AppKit
import Combine

enum PetSkin: String, CaseIterable, Identifiable {
    case character
    case dshPet
    var id: String { rawValue }
    var title: String { switch self { case .character: "小女孩"; case .dshPet: "DSH Pet" } }
    var resourceDirectory: String { switch self { case .character: "Character"; case .dshPet: "DSHPet" } }
}

@MainActor
final class PetPreferences: ObservableObject {
    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var title: String { switch self { case .small: "小"; case .medium: "中"; case .large: "大" } }
        var characterHeight: CGFloat { switch self { case .small: 42; case .medium: 100; case .large: 150 } }
        var panelSize: NSSize { NSSize(width: max(140, characterHeight + 14), height: characterHeight + 54) }
    }
    private let defaults: UserDefaults
    private let persistChanges: Bool
    let noticeMinimumSeconds: TimeInterval
    @Published var skin: PetSkin { didSet { if persistChanges { defaults.set(skin.rawValue, forKey: "pet.skin") } } }
    @Published var visible: Bool { didSet { if persistChanges { defaults.set(visible, forKey: "pet.visible") } } }
    @Published var clickThrough: Bool { didSet { if persistChanges { defaults.set(clickThrough, forKey: "pet.clickThrough") } } }
    @Published var animations: Bool { didSet { if persistChanges { defaults.set(animations, forKey: "pet.animations") } } }
    @Published var systemNotifications: Bool { didSet { if persistChanges { defaults.set(systemNotifications, forKey: "pet.systemNotifications") } } }
    @Published var notificationSessionTitle: Bool { didSet { if persistChanges { defaults.set(notificationSessionTitle, forKey: "pet.notificationSessionTitle") } } }
    @Published var size: Size { didSet { if persistChanges { defaults.set(size.rawValue, forKey: "pet.size") } } }

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        let minimum = defaults.object(forKey: "pet.noticeMinimumSeconds")
        noticeMinimumSeconds = (minimum as? NSNumber)?.doubleValue ?? (minimum as? String).flatMap(Double.init) ?? 10
        skin = PetSkin(rawValue: defaults.string(forKey: "pet.skin") ?? "") ?? .character
        visible = defaults.object(forKey: "pet.visible") == nil ? true : defaults.bool(forKey: "pet.visible")
        clickThrough = defaults.bool(forKey: "pet.clickThrough")
        animations = defaults.object(forKey: "pet.animations") == nil ? true : defaults.bool(forKey: "pet.animations")
        systemNotifications = defaults.object(forKey: "pet.systemNotifications") == nil ? true : defaults.bool(forKey: "pet.systemNotifications")
        notificationSessionTitle = defaults.bool(forKey: "pet.notificationSessionTitle")
        size = Size(rawValue: defaults.string(forKey: "pet.size") ?? "") ?? .medium
    }

    func savePosition(_ frame: NSRect, screen: NSScreen) {
        guard persistChanges else { return }
        let area = screen.visibleFrame
        defaults.set(screenID(screen), forKey: "pet.screen")
        defaults.set((frame.minX - area.minX) / max(1, area.width - frame.width), forKey: "pet.x")
        defaults.set((frame.minY - area.minY) / max(1, area.height - frame.height), forKey: "pet.y")
    }

    func restoredFrame(size: NSSize, screens: [NSScreen] = NSScreen.screens) -> NSRect {
        let screen = screens.first { screenID($0) == defaults.string(forKey: "pet.screen") } ?? screens.first
        guard let area = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        let x = defaults.object(forKey: "pet.x") as? Double ?? 0.9
        let y = defaults.object(forKey: "pet.y") as? Double ?? 0.08
        return PetPanel.constrain(NSRect(x: area.minX + min(1, max(0, x)) * max(0, area.width - size.width),
                                         y: area.minY + min(1, max(0, y)) * max(0, area.height - size.height),
                                         width: size.width, height: size.height), to: area)
    }

    private func screenID(_ screen: NSScreen) -> String {
        String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "")
    }
}
