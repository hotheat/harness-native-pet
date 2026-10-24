import Foundation
import Darwin

enum HelperSync {
    static func sync(bundled: URL, installed: URL) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: installed.path) else { return false }
        let data = try Data(contentsOf: bundled)
        guard try Data(contentsOf: installed) != data else { return false }
        let temporary = installed.deletingLastPathComponent().appendingPathComponent(".pet-hook-\(UUID())")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        guard rename(temporary.path, installed.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return true
    }
}
