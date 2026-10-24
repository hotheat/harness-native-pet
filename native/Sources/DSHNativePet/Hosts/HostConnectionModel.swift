import Foundation
import Combine
import PetCore
import PetIPC

@MainActor
final class HostConnectionModel: ObservableObject {
    enum LayerResult: Equatable {
        case idle, checking, passed, failed(String), waiting(Date)

        var title: String {
            switch self {
            case .idle: "未测试"
            case .checking: "检测中"
            case .passed: "通过"
            case .failed(let reason): reason
            case .waiting: "等待宿主真实事件，请在宿主发起一次操作（30 秒）"
            }
        }
        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    struct TestResults: Equatable {
        var socket: LayerResult = .idle
        var configuration: LayerResult = .idle
        var activity: LayerResult = .idle
    }

    struct HostRow: Identifiable {
        var id: HookTarget { target }
        let target: HookTarget
        let path: URL
        var selected = false
        var configured = false
        var hasOwnedHandlers = false
        var error: String?
        var tests = TestResults()

        var status: String {
            if configured { target == .codex ? "已配置，需在 /hooks 审核启用" : "已配置，重启 Claude Code 生效" }
            else { hasOwnedHandlers ? "配置不完整，保存可修复" : "未配置" }
        }
    }

    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    private struct Pending {
        let token: UUID
        let deadline: Date
    }

    @Published private(set) var rows: [HostRow] = []
    @Published private(set) var dshProfiles: [HostDiscovery.DSHProfile] = []
    @Published private(set) var discoveryError: String?
    @Published private(set) var helperStatus: HostDiscovery.HelperStatus = .missing
    @Published private(set) var savedTargets: [HookTarget] = []
    @Published private(set) var saveErrors: [HookTarget: String] = [:]
    @Published private(set) var saveMessage: String?

    let discovery: HostDiscovery
    let socketPath: String
    private let probe: @Sendable (String) -> Result<Void, PetIPCError>
    private let now: () -> Date
    private let schedule: Scheduler
    private var tokens: [HookTarget: UUID] = [:]
    private var pending: [HookTarget: Pending] = [:]
    private var cancellations: [HookTarget: () -> Void] = [:]

    init(discovery: HostDiscovery = HostDiscovery(), socketPath: String = PetRuntimeLocation.socketPath,
         probe: @escaping @Sendable (String) -> Result<Void, PetIPCError> = { SocketProbe.probe(path: $0) },
         now: @escaping () -> Date = Date.init,
         schedule: @escaping Scheduler = HostConnectionModel.scheduleTimeout) {
        self.discovery = discovery
        self.socketPath = socketPath
        self.probe = probe
        self.now = now
        self.schedule = schedule
        reload()
    }

    static func scheduleTimeout(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            action()
        }
        return { task.cancel() }
    }

    func reload() {
        for cancel in cancellations.values { cancel() }
        cancellations.removeAll()
        pending.removeAll()
        tokens.removeAll()
        rows = HookTarget.allCases.map { target in
            var row = HostRow(target: target, path: discovery.configPath(target))
            do {
                let config = try discovery.configuration(target)
                row.configured = config.consistent
                row.hasOwnedHandlers = config.hasOwnedHandlers
                row.selected = config.hasOwnedHandlers
            } catch { row.error = error.localizedDescription }
            return row
        }
        refreshDiscovery()
        savedTargets = []
        saveErrors = [:]
        saveMessage = nil
    }

    func select(_ target: HookTarget, selected: Bool) {
        guard let index = rows.firstIndex(where: { $0.target == target }) else { return }
        rows[index].selected = selected
        saveMessage = nil
    }

    func save() {
        savedTargets = []
        saveErrors = [:]
        var valid: [HookTarget] = []
        for index in rows.indices {
            rows[index].error = nil
            let target = rows[index].target
            do {
                _ = try discovery.configuration(target)
                valid.append(target)
            } catch { recordError(target, error) }
        }
        var helperError: Error?
        if rows.contains(where: { $0.selected && valid.contains($0.target) }) {
            do { _ = try HelperSync.install(bundled: discovery.bundledHelper, installed: discovery.installedHelper) }
            catch { helperError = error }
        }
        for target in valid {
            let index = rows.firstIndex { $0.target == target }!
            let selected = rows[index].selected
            do {
                if selected, let helperError { throw helperError }
                let current = try discovery.configuration(target)
                if selected ? !current.consistent : current.hasOwnedHandlers {
                    try HookConfigDocument.save(path: discovery.configPath(target), command: target.command(helperPath: discovery.installedHelper.path),
                                                events: target.events, remove: !selected)
                }
                let updated = try discovery.configuration(target)
                rows[index].configured = updated.consistent
                rows[index].hasOwnedHandlers = updated.hasOwnedHandlers
                rows[index].tests = TestResults()
                cancelTest(target)
                if selected || current.hasOwnedHandlers { savedTargets.append(target) }
            } catch { recordError(target, error) }
        }
        refreshDiscovery()
        saveMessage = saveErrors.isEmpty ? "已保存" : "已保存 \(savedTargets.count) 项，失败 \(saveErrors.count) 项"
    }

    private func recordError(_ target: HookTarget, _ error: Error) {
        let reason = error.localizedDescription
        saveErrors[target] = reason
        if let index = rows.firstIndex(where: { $0.target == target }) { rows[index].error = reason }
    }

    private func refreshDiscovery() {
        helperStatus = discovery.helperStatus()
        do {
            dshProfiles = try discovery.dshProfiles()
            discoveryError = nil
        } catch {
            dshProfiles = []
            discoveryError = error.localizedDescription
        }
    }

    func test(target: HookTarget) async {
        cancelTest(target)
        let token = UUID()
        tokens[target] = token
        let index = rows.firstIndex { $0.target == target }!
        rows[index].tests = TestResults(socket: .checking, configuration: .checking)
        let probe = self.probe
        let path = socketPath
        let result = await Task.detached { probe(path) }.value
        guard tokens[target] == token else { return }
        switch result {
        case .success: rows[index].tests.socket = .passed
        case .failure(let error): rows[index].tests.socket = .failed(error.description)
        }
        do {
            let config = try discovery.configuration(target)
            rows[index].configured = config.consistent
            rows[index].hasOwnedHandlers = config.hasOwnedHandlers
            helperStatus = discovery.helperStatus()
            if !config.consistent { rows[index].tests.configuration = .failed("hooks 未配置或不完整，请勾选并保存") }
            else if helperStatus != .current { rows[index].tests.configuration = .failed("helper：\(helperStatus.title)") }
            else { rows[index].tests.configuration = .passed }
        } catch { rows[index].tests.configuration = .failed(error.localizedDescription) }
        guard rows[index].tests.socket == .passed, rows[index].tests.configuration == .passed else {
            rows[index].tests.activity = .failed("先修复 socket 和配置，再测试真实事件")
            return
        }
        let deadline = now().addingTimeInterval(30)
        pending[target] = Pending(token: token, deadline: deadline)
        rows[index].tests.activity = .waiting(deadline)
        cancellations[target] = schedule(30) { [weak self] in self?.expire(target, token: token) }
    }

    func testAll() async {
        for target in HookTarget.allCases { await test(target: target) }
    }

    func noteActivity(provider: PetProvider) {
        let target: HookTarget = provider == .codex ? .codex : .claudeCode
        guard let pending = pending[target] else { return }
        if now() >= pending.deadline { expire(target, token: pending.token); return }
        let index = rows.firstIndex { $0.target == target }!
        rows[index].tests.activity = .passed
        cancelTest(target)
    }

    private func expire(_ target: HookTarget, token: UUID) {
        guard let waiting = pending[target], waiting.token == token, now() >= waiting.deadline else { return }
        let index = rows.firstIndex { $0.target == target }!
        rows[index].tests.activity = .failed("未收到宿主事件；请确认宿主启用 hooks 后重试")
        cancelTest(target)
    }

    private func cancelTest(_ target: HookTarget) {
        cancellations.removeValue(forKey: target)?()
        pending.removeValue(forKey: target)
        tokens.removeValue(forKey: target)
    }
}
