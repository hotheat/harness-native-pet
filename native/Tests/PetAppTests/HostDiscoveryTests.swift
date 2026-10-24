import Foundation
import Testing
@testable import DSHNativePet

struct HostDiscoveryTests {
    @Test func resolvesDefaultAndEnvironmentPathsAgainstInjectedHome() {
        let home = URL(fileURLWithPath: "/tmp/pet-home")
        let defaults = HostDiscovery(home: home, environment: [:])
        #expect(defaults.configPath(.codex).path == "/tmp/pet-home/.codex/hooks.json")
        #expect(defaults.configPath(.claudeCode).path == "/tmp/pet-home/.claude/settings.json")
        #expect(defaults.profilesDirectory.path == "/tmp/pet-home/.dsh/profiles")
        let custom = HostDiscovery(home: home, environment: ["CODEX_HOME": "/tmp/custom-codex", "CLAUDE_CONFIG_DIR": "~/claude", "DSH_HOME": "/tmp/custom-dsh"])
        #expect(custom.configPath(.codex).path == "/tmp/custom-codex/hooks.json")
        #expect(custom.configPath(.claudeCode).path == "/tmp/pet-home/claude/settings.json")
        #expect(custom.profilesDirectory.path == "/tmp/custom-dsh/profiles")
        #expect(custom.installedHelper == defaults.installedHelper)
    }

    @Test func detectsHelperMissingOutdatedCurrentAndBundledMissing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pet-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appendingPathComponent("bundled")
        let discovery = HostDiscovery(home: home, environment: [:], bundledHelper: bundled)
        #expect(discovery.helperStatus() == .bundledMissing)
        try Data("new".utf8).write(to: bundled)
        #expect(discovery.helperStatus() == .missing)
        try HostFileWriter.write(Data("old".utf8), to: discovery.installedHelper, mode: 0o700)
        #expect(discovery.helperStatus() == .outdated)
        _ = try HelperSync.install(bundled: bundled, installed: discovery.installedHelper)
        #expect(discovery.helperStatus() == .current)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discovery.installedHelper.path)
        #expect(discovery.helperStatus() == .outdated)
    }

    @Test func detectsConfiguredPartialUnrelatedAndMalformedHooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pet-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = HostDiscovery(home: home, environment: [:])
        #expect(try !discovery.configuration(.codex).hasOwnedHandlers)
        #expect(try !discovery.configuration(.codex).consistent)
        try HostFileWriter.write(Data(#"{"hooks":{"Unrelated":[]}}"#.utf8), to: discovery.configPath(.codex), mode: 0o600)
        #expect(try !discovery.configuration(.codex).hasOwnedHandlers)
        let command = HookTarget.codex.command(helperPath: discovery.installedHelper.path)
        _ = try HookConfigDocument.save(path: discovery.configPath(.codex), command: command, events: ["Stop"])
        #expect(try discovery.configuration(.codex).hasOwnedHandlers)
        #expect(try !discovery.configuration(.codex).consistent)
        _ = try HookConfigDocument.save(path: discovery.configPath(.codex), command: command, events: HookTarget.codex.events)
        #expect(try discovery.configuration(.codex).consistent)
        #expect(try !discovery.configuration(.claudeCode).hasOwnedHandlers)
        try Data(#"{"hooks":{"Stop":[{}]}}"#.utf8).write(to: discovery.configPath(.codex))
        #expect(throws: HookConfigDocument.ConfigError.self) { try discovery.configuration(.codex) }
    }

    @Test func dshDiscoveryIsReadOnlyAndDistinguishesInstalledEnabledAndBrokenProfiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pet-dsh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let discovery = HostDiscovery(home: home, environment: ["DSH_HOME": home.appendingPathComponent("custom-dsh").path])
        #expect(try discovery.dshProfiles().isEmpty)
        let profiles = [
            "enabled": #"{"dependencies":{"dsh-native-pet":"file:/tmp/plugin"},"dsh":{"profile":{"bundles":["dsh-native-pet"]}}}"#,
            "disabled": #"{"dependencies":{"dsh-native-pet":"*"},"dsh":{"profile":{"bundles":[]}}}"#,
            "absent": #"{"dependencies":{"other":"*"}}"#,
            "broken": "bad json",
        ]
        for (name, text) in profiles {
            try HostFileWriter.write(Data(text.utf8), to: discovery.profilesDirectory.appendingPathComponent("\(name)/package.json"), mode: 0o600)
        }
        let found = try discovery.dshProfiles()
        #expect(found.map(\.name) == ["absent", "broken", "disabled", "enabled"])
        #expect(found.map(\.installed) == [false, false, true, true])
        #expect(found.map(\.enabled) == [false, false, false, true])
        #expect(found[1].error != nil)
        for profile in found {
            #expect(try String(contentsOf: profile.path, encoding: .utf8) == profiles[profile.name])
        }
    }
}
