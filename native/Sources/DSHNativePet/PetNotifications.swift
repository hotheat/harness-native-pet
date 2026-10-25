import AppKit
import Foundation
import PetCore
import UserNotifications

enum PetNotificationAuthorization: String, Sendable {
    case notDetermined, authorized, denied, provisional, unavailable, recording

    @MainActor static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    var title: String {
        switch self {
        case .notDetermined: "尚未授权"
        case .authorized: "已授权"
        case .denied: "已拒绝，请在系统设置中允许通知"
        case .provisional: "静默授权"
        case .unavailable: "通知服务不可用"
        case .recording: "测试记录模式"
        }
    }
}

@MainActor
protocol PetNotificationAdapter: AnyObject {
    var onOpen: ((String, String) -> Void)? { get set }
    func authorization(request: Bool) async -> PetNotificationAuthorization
    func submit(_ notice: PetNotificationContent, completion: @escaping @MainActor @Sendable (String?) -> Void)
}

/// 仅正常应用启动使用；测试和截图路径使用录制 adapter。
@MainActor
final class SystemPetNotificationAdapter: NSObject, PetNotificationAdapter, UNUserNotificationCenterDelegate {
    var onOpen: ((String, String) -> Void)?
    private let center: UNUserNotificationCenter

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    func authorization(request: Bool) async -> PetNotificationAuthorization {
        await Self.systemAuthorization(request: request)
    }

    // UserNotifications 的异步调用在非隔离上下文内完成，只传回 Sendable 值。
    // 避免在 MainActor 上创建被 SDK 后台队列调用的 completion closure。
    private nonisolated static func systemAuthorization(request: Bool) async -> PetNotificationAuthorization {
        let center = UNUserNotificationCenter.current()
        if request {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { return .unavailable }
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .unavailable
        }
    }

    func submit(_ notice: PetNotificationContent, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        Task { @MainActor in
            let error = await Self.systemSubmit(notice)
            completion(error)
        }
    }

    private nonisolated static func systemSubmit(_ notice: PetNotificationContent) async -> String? {
        let content = Self.content(for: notice)
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return nil
        } catch { return error.localizedDescription }
    }

    nonisolated static func content(for notice: PetNotificationContent) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if notice.sound { content.sound = .default }
        content.threadIdentifier = notice.threadIdentifier
        content.userInfo = notice.userInfo
        return content
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let source = info["sourceId"] as? String, let session = info["sessionId"] as? String {
            Task { @MainActor [weak self] in self?.onOpen?(source, session) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

@MainActor
final class RecordingPetNotificationAdapter: PetNotificationAdapter {
    var onOpen: ((String, String) -> Void)?
    private(set) var notices: [PetNotificationContent] = []
    private let logURL: URL?

    init(logURL: URL? = nil) throws {
        self.logURL = logURL
        if let logURL {
            try Data().write(to: logURL)
        }
    }

    func authorization(request: Bool) async -> PetNotificationAuthorization { .recording }

    func submit(_ notice: PetNotificationContent, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        do {
            if let logURL {
                let payload: [String: Any] = [
                    "id": notice.id, "sourceId": notice.userInfo["sourceId"] ?? "", "sourceLabel": notice.sourceLabel,
                    "sessionId": notice.userInfo["sessionId"] ?? "", "kind": notice.kind.rawValue,
                    "title": notice.title, "body": notice.body, "sound": notice.sound,
                    "threadIdentifier": notice.threadIdentifier, "userInfo": notice.userInfo,
                ]
                var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                data.append(0x0a)
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            notices.append(notice)
            completion(nil)
        } catch { completion(error.localizedDescription) }
    }
}

/// 每次刷新先排空领域提醒，姿态优先级不参与通知分发。
@MainActor
final class PetNotificationDispatcher {
    private let adapter: any PetNotificationAdapter
    private(set) var requestCount = 0
    private var didRequestAuthorization = false
    var onError: (@MainActor (String?) -> Void)?
    var onOpen: ((String, String) -> Void)? {
        get { adapter.onOpen }
        set { adapter.onOpen = newValue }
    }

    init(adapter: any PetNotificationAdapter) { self.adapter = adapter }

    func authorization(request: Bool) async -> PetNotificationAuthorization {
        let status = await adapter.authorization(request: false)
        guard request, status == .notDetermined, !didRequestAuthorization else { return status }
        didRequestAuthorization = true
        return await adapter.authorization(request: true)
    }

    func refresh(store: PetStore, enabled: Bool, minimumDuration: TimeInterval = 0, showSessionTitles: Bool = false, at: Date = Date()) {
        let notices = store.drainNotices(at: at)
        guard enabled else { return }
        for notice in notices {
            if [.ended, .interrupted].contains(notice.kind), let duration = notice.turnDuration, duration < minimumDuration { continue }
            requestCount += 1
            let sound = notice.kind == .waiting || notice.kind == .error
            let content = PetMessageProjector.notificationContent(notice, sound: sound, showSessionTitle: showSessionTitles)
            adapter.submit(content) { [weak self] error in
                self?.onError?(error)
            }
        }
    }
}
