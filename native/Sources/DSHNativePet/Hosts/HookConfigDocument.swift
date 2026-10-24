import Foundation
import Darwin

enum HookConfigDocument {
    enum ConfigError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }

    static func load(_ path: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path), options: .fragmentsAllowed)
        guard let object = value as? [String: Any] else {
            throw ConfigError.invalid("\(path.path)：配置必须是 JSON 对象")
        }
        return object
    }

    static func merge(config: [String: Any], command: String, events: [String], remove: Bool = false) throws -> [String: Any] {
        var result = config
        var hooks: [String: Any] = [:]
        if let value = result["hooks"] {
            guard let object = value as? [String: Any] else { throw ConfigError.invalid("hooks 必须是对象") }
            hooks = object
        }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { throw ConfigError.invalid("事件 \(event) 必须是数组") }
            var kept: [[String: Any]] = []
            for value in groups {
                guard var group = value as? [String: Any], let handlers = group["hooks"] as? [Any] else {
                    throw ConfigError.invalid("事件 \(event) 的分组必须包含 hooks 数组")
                }
                let remaining = handlers.filter { value in
                    guard let handler = value as? [String: Any] else { return true }
                    return !(handler["type"] as? String == "command" && handler["command"] as? String == command)
                }
                if remaining.count == handlers.count { kept.append(group) }
                else if !remaining.isEmpty {
                    group["hooks"] = remaining
                    kept.append(group)
                }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = kept }
        }
        if !remove {
            for event in events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 2]]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") }
        else { result["hooks"] = hooks }
        return result
    }

    static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    @discardableResult
    static func save(path: URL, command: String, events: [String], remove: Bool = false,
                     now: Date = Date(), replace: (URL, URL) throws -> Void = HostFileWriter.replace) throws -> Bool {
        let original = try load(path)
        let merged = try merge(config: original, command: command, events: events, remove: remove)
        guard !equal(original, merged) else { return false }
        let manager = FileManager.default
        var mode = 0o600
        if manager.fileExists(atPath: path.path) {
            let attributes = try manager.attributesOfItem(atPath: path.path)
            mode = (attributes[.posixPermissions] as! NSNumber).intValue
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            let micros = Int((now.timeIntervalSince1970 - floor(now.timeIntervalSince1970)) * 1_000_000)
            let stamp = formatter.string(from: now) + String(format: "%06dZ", micros)
            let backup = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".dsh-native-pet-" + stamp + ".bak")
            let fd = open(backup.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
            try handle.write(contentsOf: Data(contentsOf: path))
            try handle.synchronize()
            try handle.close()
        }
        var data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try HostFileWriter.write(data, to: path, mode: mode, replace: replace)
        return true
    }
}

enum HostFileWriter {
    static func replace(_ temporary: URL, _ destination: URL) throws {
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    static func write(_ data: Data, to destination: URL, mode: Int,
                      replace: (URL, URL) throws -> Void = replace) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var template = Array(directory.appendingPathComponent(".pet-hooks-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        let temporary = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        defer { try? manager.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard fchmod(fd, mode_t(mode)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        try handle.close()
        try replace(temporary, destination)
    }
}
