import AppKit

@MainActor
enum PetIcons {
    static func menuBarImage() -> NSImage? {
        let bundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "MenuBarTemplate", withExtension: "pdf", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "DSH 桌宠"
        return image
    }
}
