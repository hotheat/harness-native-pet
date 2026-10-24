import AppKit
import Combine
import PetCore
import PetIPC
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PetStore()
    private let server = UnixSocketServer()
    private let automated: Bool
    let preferences: PetPreferences
    let status = PetStatusModel()
    let hostConnections = HostConnectionModel()
    var panel: PetPanel?
    var petView: PetView?
    private var animator: PetAnimator?
    private var assetsBySkin: [PetSkin: PetAssets] = [:]
    var statusMenu: StatusMenu?
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var deadlineTimer: Timer?
    private var terminationSignals: [DispatchSourceSignal] = []
    private var lastInteraction = Date()
    private var lastActivity = Date()
    private var pokeUntil = Date.distantPast
    private var dragging = false
    private var systemSuspensions: Set<String> = []
    var stopped = false
    var demoPose: PetPose?
    var capturePath: String?
    var captureDelay: TimeInterval = 1
    private var captureLive = false
    var switchCaptureDirectory: URL?
    private var notifications: PetNotificationDispatcher?
    private var notificationLogPath: String?
    private var canRequestNotificationAuthorization = false

    private static let automationFlags: Set<String> = ["--smoke-test", "--demo", "--demo-pose", "--capture-preview",
                                                       "--capture-live", "--capture-skin-switch", "--capture-after", "--notification-log"]

    override init() {
        automated = Self.isAutomation(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        preferences = PetPreferences(persistChanges: !automated)
        super.init()
    }

    static func isAutomation(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains { automationFlags.contains($0) } || environment["XCTestConfigurationFilePath"] != nil
    }

    static func validateAutomationArguments(_ arguments: [String]) throws {
        let valueFlags: Set<String> = ["--skin", "--demo-pose", "--capture-preview", "--capture-live",
                                      "--capture-skin-switch", "--capture-after", "--notification-log"]
        for (index, flag) in arguments.enumerated() where valueFlags.contains(flag) {
            guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else {
                throw AppError.invalidArgument("\(flag) 需要值")
            }
        }
        let flags = Set(arguments.filter { automationFlags.contains($0) || $0 == "--skin" })
        for flag in flags where arguments.filter({ $0 == flag }).count > 1 {
            throw AppError.invalidArgument("\(flag) 不能重复")
        }
        let captures = flags.intersection(["--capture-preview", "--capture-live", "--capture-skin-switch"])
        let demos = flags.intersection(["--demo", "--demo-pose"])
        guard captures.count <= 1, demos.count <= 1,
              !(flags.contains("--smoke-test") && !flags.subtracting(["--smoke-test", "--skin"]).isEmpty),
              !(demos.count > 0 && captures.contains("--capture-live")),
              !flags.contains("--capture-after") || !captures.isEmpty else {
            throw AppError.invalidArgument("自动化参数组合无效")
        }
        if let index = arguments.firstIndex(of: "--skin"), PetSkin(rawValue: arguments[index + 1]) == nil {
            throw AppError.invalidArgument("未知 --skin")
        }
        if let index = arguments.firstIndex(of: "--demo-pose"), PetPose(rawValue: arguments[index + 1]) == nil {
            throw AppError.invalidArgument("未知 --demo-pose")
        }
        if let index = arguments.firstIndex(of: "--capture-after") {
            guard let delay = TimeInterval(arguments[index + 1]), delay.isFinite, (0...60).contains(delay) else {
                throw AppError.invalidArgument("--capture-after 必须为 0 至 60 秒")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        do {
            try Self.validateAutomationArguments(arguments)
            for skin in PetSkin.allCases {
                let assets = try PetAssets(skin: skin)
                try assets.validateAll()
                assetsBySkin[skin] = assets
            }
            if let index = arguments.firstIndex(of: "--skin"), arguments.indices.contains(index + 1) {
                preferences.skin = PetSkin(rawValue: arguments[index + 1])!
            }
            let assets = assetsBySkin[preferences.skin]!
            if arguments.contains("--smoke-test") {
                print("DSHNativePet smoke OK: \(PetPose.allCases.count) poses per skin loaded; skins=\(PetSkin.allCases.count); resources=\(assets.resourceRoot.path)")
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--demo-pose"), arguments.indices.contains(index + 1) {
                demoPose = PetPose(rawValue: arguments[index + 1])
            } else if arguments.contains("--demo") { demoPose = .idle }
            if let index = arguments.firstIndex(of: "--capture-preview"), arguments.indices.contains(index + 1) {
                capturePath = arguments[index + 1]
                if demoPose == nil { demoPose = .idle }
            }
            if let index = arguments.firstIndex(of: "--capture-live"), arguments.indices.contains(index + 1) {
                capturePath = arguments[index + 1]
                captureLive = true
            }
            if let index = arguments.firstIndex(of: "--capture-after"), arguments.indices.contains(index + 1) {
                captureDelay = TimeInterval(arguments[index + 1])!
            }
            if let index = arguments.firstIndex(of: "--capture-skin-switch"), arguments.indices.contains(index + 1) {
                switchCaptureDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                preferences.skin = .character
            }
            if let index = arguments.firstIndex(of: "--notification-log") {
                notificationLogPath = arguments[index + 1]
            }
            if !automated, Bundle.main.bundleURL.pathExtension == "app" {
                do {
                    _ = try HelperSync.sync(bundled: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pet-hook"),
                                            installed: FileManager.default.homeDirectoryForCurrentUser
                                                .appendingPathComponent("Library/Application Support/dsh-native-pet/bin/pet-hook"))
                } catch { fputs("DSHNativePet helper sync: \(error.localizedDescription)\n", stderr) }
            }
            let notificationAdapter: any PetNotificationAdapter
            if automated {
                notificationAdapter = try RecordingPetNotificationAdapter(logURL: notificationLogPath.map { URL(fileURLWithPath: $0) })
            } else {
                notificationAdapter = SystemPetNotificationAdapter()
            }
            let notifications = PetNotificationDispatcher(adapter: notificationAdapter)
            notifications.onError = { [weak self] error in self?.status.notificationError = error }
            notifications.onOpen = { [weak self] source, session in self?.showSession(sourceId: source, sessionId: session) }
            self.notifications = notifications
            canRequestNotificationAuthorization = !automated
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status.notificationAuthorization = await notifications.authorization(request: !self.automated && self.preferences.systemNotifications)
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
            guard let self else { return }
            let presentation = self.store.presentation()
            if presentation.pose == .waiting, let session = presentation.sessions.first(where: { $0.phase == .waiting }) {
                self.showSession(sourceId: session.sourceId, sessionId: session.sessionId)
            } else { self.pokeUntil = Date().addingTimeInterval(1.2) }
            self.refresh()
        }
        view.onDrag = { [weak self] value in self?.dragging = value; self?.refresh() }
        view.onDragEnd = { [weak self] in self?.savePosition() }
    }

    private func startIPC() -> Bool {
        let events = PetEventDispatcher(store: store,
            onUpdate: { [weak self] event in
                guard let self else { return }
                if case .message(.activity(let activity)) = event {
                    self.hostConnections.noteActivity(provider: activity.provider)
                }
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
            onReady: { [weak self] in self?.status.connectionError = nil },
            onIncompatible: { [weak self] in self?.status.protocolWarning = $0 })
        do {
            try server.start(onMessage: { events.enqueue(.message($0)) },
                             onDisconnect: { events.enqueue(.disconnect($0)) },
                             onError: { events.enqueue(.listenerError($0)) },
                             onReady: { events.enqueue(.ready) },
                             onIncompatible: { events.enqueue(.incompatible($0)) })
        } catch PetIPCError.alreadyRunning {
            print("DSHNativePet: already running; second instance exits")
            shutdown()
            NSApp.terminate(nil)
            return false
        } catch {
            fail(error)
            return false
        }
        return true
    }

    func applyPreferences() {
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
        notifications?.refresh(store: store, enabled: preferences.systemNotifications,
                               minimumDuration: preferences.noticeMinimumSeconds, at: now)
        let presentation = store.presentation(at: now)
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let deadline = store.nextDeadline(after: now) {
            let timer = Timer(fire: deadline.addingTimeInterval(0.01), interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            deadlineTimer = timer
        }
        guard let view = petView, let panel else { return }
        status.update(presentation)
        statusMenu?.update(summary: status.summary, error: status.connectionError,
                           sourceLabels: status.sourceLabels, authorization: status.notificationAuthorization,
                           protocolWarning: status.protocolWarning)
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
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        if presentation.activeCount > 0, let feedback = presentation.feedback, feedback.pose == .completed,
           pose == .working || pose == .thinking {
            let remaining = "\(presentation.activeCount) " + (pose == .working ? "执行中" : "思考中")
            if let source = feedback.sourceLabel { return "\(source)\n本轮结束 · \(remaining)" }
            return "\(feedback.text)，\(remaining)"
        }
        return presentation.text
    }

    private func showSession(sourceId: String, sessionId: String) {
        status.focusedSessionID = nil
        showSettings()
        DispatchQueue.main.async { [weak self] in
            self?.status.focusedSessionID = PetStatusModel.rowID(sourceId: sourceId, sessionId: sessionId)
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DSH 桌宠设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, status: status, hostConnections: hostConnections))
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
        center.addObserver(self, selector: #selector(displayOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
    @objc private func screensChanged(_ notification: Notification) { panel?.constrainToScreens() }
    @objc private func displayOptionsChanged(_ notification: Notification) { refresh() }

    func fail(_ error: Error) {
        fputs("DSHNativePet: \(error.localizedDescription)\n", stderr)
        if !automated {
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
        deadlineTimer?.invalidate()
        deadlineTimer = nil
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
