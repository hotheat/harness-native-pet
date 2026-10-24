import Foundation
import Testing
@testable import DSHNativePet

struct HelperSyncTests {
    @Test func replacesDifferentHelperAtomicallyAndLeavesMatchingOrMissingHelperAlone() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("pet-helper-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let bundled = directory.appendingPathComponent("bundled")
        let installed = directory.appendingPathComponent("pet-hook")
        try Data("new helper".utf8).write(to: bundled)
        #expect(try !HelperSync.sync(bundled: bundled, installed: installed))
        #expect(!manager.fileExists(atPath: installed.path))
        try Data("old helper".utf8).write(to: installed)
        let old = try manager.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? NSNumber
        #expect(try HelperSync.sync(bundled: bundled, installed: installed))
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: installed))
        let attributes = try manager.attributesOfItem(atPath: installed.path)
        #expect(attributes[.systemFileNumber] as? NSNumber != old)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o700)
        #expect(try !HelperSync.sync(bundled: bundled, installed: installed))
        #expect(try manager.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber)
        #expect(try Set(manager.contentsOfDirectory(atPath: directory.path)) == ["bundled", "pet-hook"])
    }
}
