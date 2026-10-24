import Foundation
import PetCore
import PetIPC
import Testing
@testable import DSHNativePet

@MainActor
private final class ManualHostClock {
    var date = Date(timeIntervalSince1970: 100)
    var actions: [@MainActor () -> Void] = []
    var cancelled: Set<Int> = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        #expect(delay == 30)
        let index = actions.count
        actions.append(action)
        return { self.cancelled.insert(index) }
    }

    func advance(_ seconds: TimeInterval) {
        date.addTimeInterval(seconds)
        for (index, action) in actions.enumerated() where !cancelled.contains(index) { action() }
    }
}

@MainActor
struct HostConnectionModelTests {
    private func discovery(_ directory: URL) throws -> HostDiscovery {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("bundled-hook")
        try Data("helper".utf8).write(to: helper)
        return HostDiscovery(home: directory, environment: [:], bundledHelper: helper)
    }

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pet-model-\(UUID())") }

    @Test func saveInstallsSelectedHostsRefreshesHelperAndRemovesOnlyOwnedHandlers() throws {
        let home = directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = try discovery(home)
        let model = HostConnectionModel(discovery: discovery)
        #expect(model.rows.allSatisfy { !$0.selected && !$0.configured })
        model.select(.codex, selected: true)
        model.save()
        #expect(model.saveErrors.isEmpty)
        #expect(model.rows[0].configured)
        #expect(model.helperStatus == .current)
        #expect(!FileManager.default.fileExists(atPath: discovery.configPath(.claudeCode).path))
        let bytes = try Data(contentsOf: discovery.configPath(.codex))
        let inode = try FileManager.default.attributesOfItem(atPath: discovery.installedHelper.path)[.systemFileNumber] as! NSNumber
        model.save()
        #expect(try Data(contentsOf: discovery.configPath(.codex)) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: discovery.installedHelper.path)[.systemFileNumber] as! NSNumber != inode)
        let configDirectory = discovery.configPath(.codex).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: configDirectory.path) == ["hooks.json"])
        var config = try HookConfigDocument.load(discovery.configPath(.codex))
        config["env"] = ["keep": true]
        try JSONSerialization.data(withJSONObject: config).write(to: discovery.configPath(.codex))
        model.select(.claudeCode, selected: true)
        model.save()
        #expect(model.rows.allSatisfy { $0.configured })
        model.select(.codex, selected: false)
        model.save()
        #expect(try HookConfigDocument.equal(HookConfigDocument.load(discovery.configPath(.codex)), ["env": ["keep": true]]))
        #expect(try discovery.configuration(.claudeCode).consistent)
        #expect(FileManager.default.fileExists(atPath: discovery.installedHelper.path))
        model.reload()
        #expect(!model.rows[0].selected && model.rows[1].selected)
    }

    @Test func malformedHostDoesNotPreventOtherHostSavingAndLeavesDSHUntouched() throws {
        let home = directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = try discovery(home)
        let invalid = Data(#"{"hooks":{"Stop":[{}]}}"#.utf8)
        try HostFileWriter.write(invalid, to: discovery.configPath(.codex), mode: 0o600)
        let profile = discovery.profilesDirectory.appendingPathComponent("web/package.json")
        let dsh = Data(#"{"dependencies":{"dsh-native-pet":"*"},"dsh":{"profile":{"bundles":["dsh-native-pet"]}}}"#.utf8)
        try HostFileWriter.write(dsh, to: profile, mode: 0o600)
        let model = HostConnectionModel(discovery: discovery)
        #expect(model.rows[0].error != nil)
        #expect(model.dshProfiles.count == 1)
        model.select(.codex, selected: true)
        model.select(.claudeCode, selected: true)
        model.save()
        #expect(model.saveErrors[.codex] != nil)
        #expect(model.savedTargets == [.claudeCode])
        #expect(try Data(contentsOf: discovery.configPath(.codex)) == invalid)
        #expect(try Data(contentsOf: profile) == dsh)
        #expect(model.rows[1].configured)
    }

    @Test func helperFailurePreservesSelectedHostConfigAndStillAllowsRemoval() throws {
        let home = directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = try discovery(home)
        let model = HostConnectionModel(discovery: discovery)
        model.select(.codex, selected: true)
        model.save()
        try FileManager.default.removeItem(at: discovery.bundledHelper)
        model.select(.codex, selected: false)
        model.select(.claudeCode, selected: true)
        model.save()
        #expect(model.saveErrors[.claudeCode] != nil)
        #expect(!model.rows[0].configured)
        #expect(!FileManager.default.fileExists(atPath: discovery.configPath(.claudeCode).path))
    }

    @Test func threeLayersWaitOnlyForMatchingProviderAndTimeoutWithoutRunLoop() async throws {
        let home = directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = try discovery(home)
        let clock = ManualHostClock()
        let model = HostConnectionModel(discovery: discovery, probe: { _ in .success(()) },
                                        now: { clock.date }, schedule: clock.schedule)
        for target in HookTarget.allCases { model.select(target, selected: true) }
        model.save()
        model.noteActivity(provider: .codex)
        await model.testAll()
        #expect(model.rows.allSatisfy { $0.tests.socket == .passed && $0.tests.configuration == .passed })
        #expect(model.rows[0].tests.activity == .waiting(clock.date.addingTimeInterval(30)))
        model.noteActivity(provider: .codex)
        #expect(model.rows[0].tests.activity == .passed)
        #expect(model.rows[1].tests.activity == .waiting(clock.date.addingTimeInterval(30)))
        clock.advance(30)
        #expect(model.rows[0].tests.activity == .passed)
        #expect(model.rows[1].tests.activity.isFailure)
        model.noteActivity(provider: .claudeCode)
        #expect(model.rows[1].tests.activity.isFailure)
    }

    @Test func retestAndReloadInvalidateOldTimeoutsAndLateEvents() async throws {
        let home = directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = try discovery(home)
        let clock = ManualHostClock()
        let model = HostConnectionModel(discovery: discovery, probe: { _ in .success(()) }, now: { clock.date }, schedule: clock.schedule)
        model.select(.codex, selected: true)
        model.save()
        await model.test(target: .codex)
        let oldAction = clock.actions[0]
        clock.date.addTimeInterval(10)
        await model.test(target: .codex)
        clock.date.addTimeInterval(20)
        oldAction()
        #expect(model.rows[0].tests.activity == .waiting(clock.date.addingTimeInterval(10)))
        clock.date.addTimeInterval(10)
        model.noteActivity(provider: .codex)
        #expect(model.rows[0].tests.activity.isFailure)
        await model.test(target: .codex)
        model.reload()
        clock.advance(60)
        model.noteActivity(provider: .codex)
        #expect(model.rows[0].tests == HostConnectionModel.TestResults())
    }

    @Test func reportsSocketAndConfigurationFailuresSeparately() async throws {
        let home = directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = try discovery(home)
        let model = HostConnectionModel(discovery: discovery, probe: { _ in .failure(.system("connect", ENOENT)) })
        await model.test(target: .codex)
        #expect(model.rows[0].tests.socket.isFailure)
        #expect(model.rows[0].tests.configuration.isFailure)
        #expect(model.rows[0].tests.activity.isFailure)
        model.select(.codex, selected: true)
        model.save()
        try Data("changed helper".utf8).write(to: discovery.bundledHelper)
        await model.test(target: .codex)
        #expect(model.rows[0].tests.configuration.isFailure)
        #expect(model.helperStatus == .outdated)
    }
}
