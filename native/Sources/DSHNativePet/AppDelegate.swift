import AppKit
import Combine
import PetCore
import PetIPC
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PetStore()
    private let server = UnixSocketServer()
    private let preferences: PetPreferences = {
        let automationFlags: Set<String> = ["--smoke-test", "--demo", "--demo-pose", "--capture-preview",
                                            "--capture-live", "--capture-skin-switch", "--notification-log"]
        return PetPreferences(persistChanges: !ProcessInfo.processInfo.arguments.contains { automationFlags.contains($0) })
    }()
    private let status = PetStatusModel()
    private var panel: PetPanel?
    private var petView: PetView?
    private var animator: PetAnimator?
    private var assetsBySkin: [PetSkin: PetAssets] = [:]
    private var statusMenu: StatusMenu?
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var terminationSignals: [DispatchSourceSignal] = []
    private var lastInteraction = Date()
    private var lastActivity = Date()
    private var pokeUntil = Date.distantPast
    private var dragging = false
    private var systemSuspensions: Set<String> = []
    private var stopped = false
    private var demoPose: PetPose?
    private var capturePath: String?
    private var captureDelay: TimeInterval = 1
    private var captureLive = false
    private var switchCaptureDirectory: URL?
    private var notifications: PetNotificationDispatcher?
    private var notificationLogPath: String?
    private var canRequestNotificationAuthorization = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        do {
            for skin in PetSkin.allCases {
                let assets = try PetAssets(skin: skin)
                try assets.validateAll()
                assetsBySkin[skin] = assets
            }
            if let index = arguments.firstIndex(of: "--skin"), arguments.indices.contains(index + 1) {
                guard let skin = PetSkin(rawValue: arguments[index + 1]) else { throw AppError.invalidArgument("未知 --skin") }
                preferences.skin = skin
            }
            let assets = assetsBySkin[preferences.skin]!
            if arguments.contains("--smoke-test") {
                print("DSHNativePet smoke OK: \(PetPose.allCases.count) poses per skin loaded; skins=\(PetSkin.allCases.count); resources=\(assets.resourceRoot.path)")
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--demo-pose"), arguments.indices.contains(index + 1) {
                demoPose = PetPose(rawValue: arguments[index + 1])
                guard demoPose != nil else { throw AppError.invalidArgument("未知 --demo-pose") }
            } else if arguments.contains("--demo") { demoPose = .idle }
            if let index = arguments.firstIndex(of: "--capture-preview"), arguments.indices.contains(index + 1) {
                capturePath = arguments[index + 1]
                if demoPose == nil { demoPose = .idle }
            }
            if let index = arguments.firstIndex(of: "--capture-live"), arguments.indices.contains(index + 1) {
                capturePath = arguments[index + 1]
                captureLive = true
                guard demoPose == nil else { throw AppError.invalidArgument("--capture-live 不能与演示模式同时使用") }
            }
            if let index = arguments.firstIndex(of: "--capture-after"), arguments.indices.contains(index + 1) {
                guard let delay = TimeInterval(arguments[index + 1]), delay.isFinite, (0...60).contains(delay) else {
                    throw AppError.invalidArgument("--capture-after 必须为 0 至 60 秒")
                }
                captureDelay = delay
            }
            if let index = arguments.firstIndex(of: "--capture-skin-switch"), arguments.indices.contains(index + 1) {
                switchCaptureDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                preferences.skin = .character
            }
            if let index = arguments.firstIndex(of: "--notification-log") {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                    throw AppError.invalidArgument("--notification-log 需要 JSONL 文件路径")
                }
                notificationLogPath = arguments[index + 1]
            }
            let automated = demoPose != nil || capturePath != nil || switchCaptureDirectory != nil || notificationLogPath != nil
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let notificationAdapter: any PetNotificationAdapter
            if automated {
                notificationAdapter = try RecordingPetNotificationAdapter(logURL: notificationLogPath.map { URL(fileURLWithPath: $0) })
            } else {
                notificationAdapter = SystemPetNotificationAdapter()
            }
            let notifications = PetNotificationDispatcher(adapter: notificationAdapter)
            notifications.onError = { [weak self] error in self?.status.notificationError = error }
            self.notifications = notifications
            canRequestNotificationAuthorization = !automated
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status.notificationAuthorization = await notifications.authorization(request: !automated && self.preferences.systemNotifications)
                self.refresh()
            }
            let frame = preferences.restoredFrame(size: try assets.requiredPanelSize(characterHeight: preferences.size.characterHeight))
            let panel = PetPanel(frame: frame)
            let view = PetView(assets: assets)
            view.characterHeight = preferences.size.characterHeight
            view.frame = panel.contentLayoutRect
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            self.panel = panel
            petView = view
            animator = PetAnimator(layer: view.characterLayer)
            connectInteractions(view)
            status.socketPath = server.socketPath
            let menu = StatusMenu(preferences: preferences)
            menu.onSettings = { [weak self] in self?.showSettings() }
            menu.onInteraction = { [weak self] in self?.lastInteraction = Date() }
            statusMenu = menu
            observeSystemLifecycle()
            observeTerminationSignals()
            preferences.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.applyPreferences() }
            }.store(in: &subscriptions)
            preferences.$systemNotifications.dropFirst().removeDuplicates().sink { [weak self] enabled in
                Task { @MainActor [weak self] in
                    guard let self, let notifications = self.notifications else { return }
                    self.status.notificationAuthorization = await notifications.authorization(
                        request: self.canRequestNotificationAuthorization && enabled)
                    self.refresh()
                }
            }.store(in: &subscriptions)
            if demoPose == nil, !startIPC() { return }
            applyPreferences()
            if capturePath != nil || switchCaptureDirectory != nil { panel.orderFrontRegardless(); refresh() }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            if switchCaptureDirectory != nil { captureSkinSwitch() }
            if capturePath != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) { [weak self] in self?.capturePreview() }
            }
        } catch {
            fail(error)
        }
    }

    private func connectInteractions(_ view: PetView) {
        view.onInteraction = { [weak self] in self?.lastInteraction = Date() }
        view.onPoke = { [weak self] in
            self?.pokeUntil = Date().addingTimeInterval(1.2)
            self?.refresh()
        }
        view.onDrag = { [weak self] value in self?.dragging = value; self?.refresh() }
        view.onDragEnd = { [weak self] in self?.savePosition() }
    }

    private func startIPC() -> Bool {
        let events = PetEventDispatcher(store: store,
            onUpdate: { [weak self] event in
                guard let self else { return }
                self.refresh()
                let stateEvent: Bool
                switch event {
                case .message(.snapshot), .message(.activity): stateEvent = true
                default: stateEvent = false
                }
                if (self.captureLive || self.switchCaptureDirectory != nil) && stateEvent {
                    print("DSHNativePet live update: pose=\(self.store.presentation().pose.rawValue)")
                    fflush(stdout)
                }
            },
            onError: { [weak self] error in self?.status.connectionError = error },
            onReady: { [weak self] in self?.status.connectionError = nil })
        do {
            try server.start(onMessage: { events.enqueue(.message($0)) },
                             onDisconnect: { events.enqueue(.disconnect($0)) },
                             onError: { events.enqueue(.listenerError($0)) },
                             onReady: { events.enqueue(.ready) })
        } catch PetIPCError.alreadyRunning {
            print("DSHNativePet: already running; second instance exits")
            shutdown()
            NSApp.terminate(nil)
            return false
        } catch { status.connectionError = error.localizedDescription }
        return true
    }

    private func applyPreferences() {
        guard let panel else { return }
        if capturePath == nil {
            guard let assets = assetsBySkin[preferences.skin] else { return }
            let size: NSSize
            do { size = try assets.requiredPanelSize(characterHeight: preferences.size.characterHeight) }
            catch { status.connectionError = error.localizedDescription; return }
            var frame = panel.frame
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true)
            petView?.characterHeight = preferences.size.characterHeight
            panel.constrainToScreens()
            panel.ignoresMouseEvents = preferences.clickThrough
            if preferences.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        refresh()
    }

    private func refresh() {
        guard !stopped else { return }
        let now = Date()
        notifications?.refresh(store: store, enabled: preferences.systemNotifications, at: now)
        guard let view = petView, let panel else { return }
        let presentation = store.presentation(at: now)
        status.update(presentation)
        statusMenu?.update(summary: status.summary, error: status.connectionError,
                           sourceLabels: status.sourceLabels, authorization: status.notificationAuthorization)
        if presentation.activeCount > 0 || presentation.waitingCount > 0 || [.completed, .error].contains(presentation.pose) {
            lastActivity = now
        }
        var pose = presentation.pose
        if pose == .idle, now.timeIntervalSince(max(lastInteraction, lastActivity)) >= 60 { pose = .sleeping }
        if now < pokeUntil { pose = .poke }
        if dragging { pose = .drag }
        if let demoPose { pose = demoPose }
        var text = Self.presentationText(presentation, pose: pose)
        if demoPose != nil { text = "预览 · \(pose.rawValue)" }
        if status.connectionError != nil { text = "连接异常，查看菜单栏" }
        let animated = preferences.animations && panel.isVisible && systemSuspensions.isEmpty
        if let assets = assetsBySkin[preferences.skin], view.skin != preferences.skin {
            animator?.stop()
            view.useAssets(assets)
        }
        do { try view.render(pose: pose, text: text, animated: animated) }
        catch { status.connectionError = error.localizedDescription }
        animator?.render(pose: pose, animated: animated && view.skin == .character && capturePath == nil)
    }

    static func presentationText(_ presentation: PetPresentation, pose: PetPose) -> String {
        if pose == .sleeping {
            return presentation.connectedSources == 0 ? "休息中 · 暂无宿主状态" : "休息中"
        }
        if presentation.activeCount > 0 {
            return presentation.text
                .replacingOccurrences(of: "：本轮回应已结束，", with: "\n本轮结束 · ")
                .replacingOccurrences(of: " 个会话仍在执行", with: " 执行中")
                .replacingOccurrences(of: " 个会话仍在思考", with: " 思考中")
        }
        return presentation.text
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DSH 桌宠设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, status: status))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func savePosition() {
        guard capturePath == nil, notificationLogPath == nil, let panel, let screen = panel.screen else { return }
        preferences.savePosition(panel.frame, screen: screen)
    }

    private func observeSystemLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(suspend), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(resume), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func observeTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { @Sendable in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            source.resume()
            terminationSignals.append(source)
        }
    }

    @objc private func suspend(_ notification: Notification) {
        systemSuspensions.insert(suspensionKey(notification.name))
        refresh()
    }
    @objc private func resume(_ notification: Notification) {
        systemSuspensions.remove(suspensionKey(notification.name))
        refresh()
    }
    private func suspensionKey(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: "system"
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification: "display"
        default: "lock"
        }
    }
    @objc private func screensChanged(_ notification: Notification) { panel?.constrainToScreens(); savePosition() }

    private func capturePreview() {
        guard let capturePath else { return }
        do {
            try writeCapture(to: URL(fileURLWithPath: capturePath))
            NSApp.terminate(nil)
        } catch { fail(error) }
    }

    private func captureSkinSwitch() {
        guard let directory = switchCaptureDirectory else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let originalFrame = self.panel?.frame
                let originalFoot = self.panel.map { NSPoint(x: $0.frame.midX, y: $0.frame.minY + 8) }
                let originalSizePreference = self.preferences.size
                for (index, skin) in [PetSkin.character, .dshPet, .character].enumerated() {
                    self.statusMenu?.selectSkin(skin)
                    self.applyPreferences()
                    try await Task.sleep(for: .seconds(max(1.5, self.captureDelay)))
                    guard !self.stopped else { return }
                    let foot = self.panel.map { NSPoint(x: $0.frame.midX, y: $0.frame.minY + 8) }
                    guard foot == originalFoot, self.preferences.size == originalSizePreference else {
                        throw AppError.invalidArgument("换肤改变了脚底坐标或尺寸偏好")
                    }
                    if index == 2, self.panel?.frame != originalFrame {
                        throw AppError.invalidArgument("切回小女孩后窗口未恢复")
                    }
                    try self.writeCapture(to: directory.appendingPathComponent("\(index + 1)-\(skin.rawValue).png"))
                }
                NSApp.terminate(nil)
            } catch { self.fail(error) }
        }
    }

    private func writeCapture(to url: URL) throws {
        guard let view = petView, let panel else { throw AppError.invalidArgument("桌宠窗口尚未创建") }
        view.layoutSubtreeIfNeeded()
        let decoded = view.videoPlayback.decodedFrame()
        if view.videoPlayback.isActive, decoded == nil {
            throw AppError.invalidArgument("视频尚无可读取的实际解码帧")
        }
        let savedContents = view.characterLayer.contents
        let videoHidden = view.videoPlayback.videoLayer?.isHidden
        if let decoded {
            view.characterLayer.contents = decoded.image
            view.videoPlayback.videoLayer?.isHidden = true
        }
        defer {
            view.characterLayer.contents = savedContents
            if let videoHidden { view.videoPlayback.videoLayer?.isHidden = videoHidden }
        }
        CATransaction.flush()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AppError.invalidArgument("无法创建窗口截图")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.invalidArgument("无法编码窗口截图")
        }
        try png.write(to: url)
        let presentation = store.presentation()
        let evidence: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "skin": view.skin.rawValue,
            "pose": view.currentPose?.rawValue ?? "",
            "source": decoded == nil ? "poster" : "AVPlayerItemVideoOutput",
            "videoTime": decoded?.time ?? 0,
            "decodedTransparentPixels": decoded?.transparentPixels ?? 0,
            "decodedOpaquePixels": decoded?.opaquePixels ?? 0,
            "playerActive": view.videoPlayback.isActive,
            "playerReady": view.videoPlayback.hasDecodedFrame,
            "characterHeight": view.characterHeight,
            "sizePreference": preferences.size.rawValue,
            "footPosition": NSStringFromPoint(NSPoint(x: panel.frame.midX, y: panel.frame.minY + 8)),
            "footScreenX": panel.frame.midX,
            "footScreenY": panel.frame.minY + 8,
            "frame": NSStringFromRect(panel.frame),
            "connectedSources": presentation.connectedSources,
            "sessionIDs": presentation.sessions.map(\.sessionId),
            "sourceLabels": status.sourceLabels,
            "sessions": presentation.sessions.map { ["sourceId": $0.sourceId, "sourceLabel": $0.sourceLabel,
                                                      "sessionId": $0.sessionId, "phase": $0.phase.rawValue,
                                                      "isStale": $0.isStale] as [String: Any] },
            "notificationRequestCount": notifications?.requestCount ?? 0,
            "notificationAuthorization": status.notificationAuthorization.rawValue,
            "systemNotifications": preferences.systemNotifications,
            "storePose": presentation.pose.rawValue,
            "presentationText": presentation.text,
            "displayText": view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? "",
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.deletingPathExtension().appendingPathExtension("json"))
        print("Preview captured from live PetPanel: \(url.path); state=\(demoPose?.rawValue ?? presentation.pose.rawValue); skin=\(view.skin.rawValue); pose=\(view.currentPose?.rawValue ?? ""); source=\(decoded == nil ? "poster" : "AVPlayerItemVideoOutput"); videoTime=\(decoded?.time ?? 0); playerActive=\(view.videoPlayback.isActive)")
        fflush(stdout)
    }

    private func fail(_ error: Error) {
        fputs("DSHNativePet: \(error.localizedDescription)\n", stderr)
        let arguments = ProcessInfo.processInfo.arguments
        if !arguments.contains("--smoke-test") && !arguments.contains("--capture-live") && !arguments.contains("--capture-preview") && !arguments.contains("--capture-skin-switch") && !arguments.contains("--notification-log") {
            let alert = NSAlert()
            alert.messageText = "DSH 桌宠无法启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        shutdown()
        Darwin.exit(1)
    }

    private func shutdown() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        animator?.stop()
        petView?.stopVideo()
        savePosition()
        server.stop()
        for signal in terminationSignals { signal.cancel() }
        terminationSignals.removeAll()
        subscriptions.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let notifications else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status.notificationAuthorization = await notifications.authorization(request: false)
            self.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    enum AppError: LocalizedError {
        case invalidArgument(String)
        var errorDescription: String? { switch self { case let .invalidArgument(message): message } }
    }
}
