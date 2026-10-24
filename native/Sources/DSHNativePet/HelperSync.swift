import Foundation
import Darwin

enum HelperSync {
    static func sync(bundled: URL, installed: URL) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: installed.path) else { return false }
        let data = try Data(contentsOf: bundled)
        guard try Data(contentsOf: installed) != data else { return false }
        return try install(bundled: bundled, installed: installed)
    }

    static func install(bundled: URL, installed: URL) throws -> Bool {
        try HostFileWriter.write(Data(contentsOf: bundled), to: installed, mode: 0o700)
        return true
    }
}
