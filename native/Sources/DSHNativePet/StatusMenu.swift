import AppKit

@MainActor
final class StatusMenu: NSObject {
    private let statusItem: NSStatusItem
    private let preferences: PetPreferences
    private let summary = NSMenuItem(title: "暂无宿主状态", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "来源：无", action: nil, keyEquivalent: "")
    private let notificationStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let notificationItem = NSMenuItem(title: "系统通知", action: #selector(toggleNotifications), keyEquivalent: "")
    private(set) var sourceSummary = "来源：无"
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let visibleItem = NSMenuItem(title: "显示桌宠", action: #selector(toggleVisible), keyEquivalent: "")
    private let throughItem = NSMenuItem(title: "点击穿透", action: #selector(toggleThrough), keyEquivalent: "")
    private let animationItem = NSMenuItem(title: "播放动画", action: #selector(toggleAnimations), keyEquivalent: "")
    private var skinItems: [(PetSkin, NSMenuItem)] = []
    private var sizeItems: [(PetPreferences.Size, NSMenuItem)] = []
    var onSettings: (() -> Void)?
    var onInteraction: (() -> Void)?

    init(preferences: PetPreferences) {
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = PetIcons.menuBarImage()
        statusItem.button?.toolTip = "DSH Native Pet"
        let menu = NSMenu()
        menu.addItem(summary)
        menu.addItem(sourceItem)
        errorItem.isHidden = true
        menu.addItem(errorItem)
        menu.addItem(.separator())
        for item in [visibleItem, throughItem, animationItem, notificationItem] { item.target = self; menu.addItem(item) }
        menu.addItem(notificationStatusItem)
        let skinMenu = NSMenu(title: "角色")
        for skin in PetSkin.allCases {
            let item = NSMenuItem(title: skin.title, action: #selector(changeSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = skin.rawValue
            skinMenu.addItem(item)
            skinItems.append((skin, item))
        }
        let skinItem = NSMenuItem(title: "角色", action: nil, keyEquivalent: "")
        skinItem.submenu = skinMenu
        menu.addItem(skinItem)
        let sizeMenu = NSMenu(title: "大小")
        for size in PetPreferences.Size.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            sizeMenu.addItem(item)
            sizeItems.append((size, item))
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置与会话状态…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DSH 桌宠", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        update(summary: "暂无宿主状态", error: nil)
    }

    func update(summary text: String, error: String?, sourceLabels: [String] = [],
                authorization: PetNotificationAuthorization = .notDetermined) {
        sourceSummary = "来源：" + (sourceLabels.isEmpty ? "无" : sourceLabels.joined(separator: "、"))
        sourceItem.title = sourceSummary
        notificationStatusItem.title = "通知权限：\(authorization.title)"
        notificationItem.state = preferences.systemNotifications ? .on : .off
        summary.title = text
        errorItem.title = error.map { "连接错误：\($0)" } ?? ""
        errorItem.isHidden = error == nil
        visibleItem.state = preferences.visible ? .on : .off
        throughItem.state = preferences.clickThrough ? .on : .off
        animationItem.state = preferences.animations ? .on : .off
        for (skin, item) in skinItems { item.state = preferences.skin == skin ? .on : .off }
        for (size, item) in sizeItems { item.state = preferences.size == size ? .on : .off }
    }

    func setSystemNotifications(_ enabled: Bool) {
        onInteraction?()
        preferences.systemNotifications = enabled
    }
    @objc private func toggleNotifications() { setSystemNotifications(!preferences.systemNotifications) }
    @objc private func toggleVisible() { onInteraction?(); preferences.visible.toggle() }
    @objc private func toggleThrough() { onInteraction?(); preferences.clickThrough.toggle() }
    @objc private func toggleAnimations() { onInteraction?(); preferences.animations.toggle() }
    func selectSkin(_ skin: PetSkin) {
        onInteraction?()
        preferences.skin = skin
    }
    @objc private func changeSkin(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let skin = PetSkin(rawValue: value) else { return }
        selectSkin(skin)
    }
    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let size = PetPreferences.Size(rawValue: value) else { return }
        onInteraction?()
        preferences.size = size
    }
    @objc private func settings() { onInteraction?(); onSettings?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
