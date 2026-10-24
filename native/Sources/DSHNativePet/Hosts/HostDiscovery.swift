import Foundation

struct HostDiscovery {
    enum HelperStatus: Equatable {
        case missing, outdated, current, bundledMissing, unreadable(String)

        var title: String {
            switch self {
            case .missing: "未安装，保存时安装"
            case .outdated: "需要更新，保存时更新"
            case .current: "已安装且一致"
            case .bundledMissing: "应用内缺少 pet-hook，请使用完整应用包"
            case .unreadable(let error): "无法读取：\(error)"
            }
        }
    }

    struct Configuration {
        let hasOwnedHandlers: Bool
        let consistent: Bool
    }

    struct DSHProfile: Identifiable, Equatable {
        var id: String { path.path }
        let name: String
        let path: URL
        let installed: Bool
        let enabled: Bool
        let error: String?

        var status: String { installed ? (enabled ? "已安装并启用" : "已安装，未启用") : "未安装" }
    }

    let home: URL
    let environment: [String: String]
    let bundledHelper: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         bundledHelper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pet-hook")) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.environment = environment
        self.bundledHelper = bundledHelper
    }

    var installedHelper: URL { home.appendingPathComponent("Library/Application Support/dsh-native-pet/bin/pet-hook") }
    var profilesDirectory: URL { directory(variable: "DSH_HOME", fallback: ".dsh").appendingPathComponent("profiles") }

    func configPath(_ target: HookTarget) -> URL {
        switch target {
        case .codex: directory(variable: "CODEX_HOME", fallback: ".codex").appendingPathComponent("hooks.json")
        case .claudeCode: directory(variable: "CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("settings.json")
        }
    }

    private func directory(variable: String, fallback: String) -> URL {
        guard let path = environment[variable] else { return home.appendingPathComponent(fallback) }
        let expanded: String
        if path == "~" { expanded = home.path }
        else if path.hasPrefix("~/") { expanded = home.appendingPathComponent(String(path.dropFirst(2))).path }
        else { expanded = path }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    func configuration(_ target: HookTarget) throws -> Configuration {
        let config = try HookConfigDocument.load(configPath(target))
        let command = target.command(helperPath: installedHelper.path)
        let installed = try HookConfigDocument.merge(config: config, command: command, events: target.events)
        let hooks = config["hooks"] as? [String: [[String: Any]]] ?? [:]
        let owned = hooks.values.joined().contains { group in
            (group["hooks"] as! [Any]).contains { value in
                guard let handler = value as? [String: Any] else { return false }
                return handler["type"] as? String == "command" && handler["command"] as? String == command
            }
        }
        return Configuration(hasOwnedHandlers: owned,
                             consistent: HookConfigDocument.equal(config, installed))
    }

    func helperStatus() -> HelperStatus {
        let manager = FileManager.default
        guard manager.fileExists(atPath: bundledHelper.path) else { return .bundledMissing }
        guard manager.fileExists(atPath: installedHelper.path) else { return .missing }
        do {
            let matches = try Data(contentsOf: bundledHelper) == Data(contentsOf: installedHelper)
            let attributes = try manager.attributesOfItem(atPath: installedHelper.path)
            return matches && (attributes[.posixPermissions] as! NSNumber).intValue & 0o100 != 0 ? .current : .outdated
        } catch { return .unreadable(error.localizedDescription) }
    }

    func dshProfiles() throws -> [DSHProfile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: profilesDirectory.path) else { return [] }
        let directories = try manager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        return directories.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
            let path = directory.appendingPathComponent("package.json")
            guard manager.fileExists(atPath: path.path) else { return nil }
            do {
                let object = try HookConfigDocument.load(path)
                let dependencies = object["dependencies"] as? [String: Any] ?? [:]
                let profile = (object["dsh"] as? [String: Any])?["profile"] as? [String: Any]
                let bundles = profile?["bundles"] as? [String] ?? []
                return DSHProfile(name: directory.lastPathComponent, path: path,
                                  installed: dependencies["dsh-native-pet"] as? String != nil,
                                  enabled: bundles.contains("dsh-native-pet"), error: nil)
            } catch {
                return DSHProfile(name: directory.lastPathComponent, path: path, installed: false, enabled: false,
                                  error: "无法读取 profile：\(error.localizedDescription)")
            }
        }
    }
}
