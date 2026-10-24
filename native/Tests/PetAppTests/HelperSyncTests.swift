import Foundation
import Testing
@testable import DSHNativePet

struct HelperSyncTests {
    @Test func installCreatesPrivateParentsAndAlwaysReplacesEvenMatchingHelper() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("pet-install-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let bundled = directory.appendingPathComponent("bundled")
        let installed = directory.appendingPathComponent("private/bin/pet-hook")
        try Data("helper".utf8).write(to: bundled)
        #expect(try HelperSync.install(bundled: bundled, installed: installed))
        let inode = try manager.attributesOfItem(atPath: installed.path)[.systemFileNumber] as! NSNumber
        #expect(try HelperSync.install(bundled: bundled, installed: installed))
        #expect(try manager.attributesOfItem(atPath: installed.path)[.systemFileNumber] as! NSNumber != inode)
        #expect(try manager.attributesOfItem(atPath: installed.path)[.posixPermissions] as! NSNumber == 0o700)
        #expect(try manager.attributesOfItem(atPath: installed.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber == 0o700)
        #expect(throws: (any Error).self) { try HelperSync.install(bundled: directory.appendingPathComponent("missing"), installed: installed) }
        #expect(try Data(contentsOf: installed) == Data("helper".utf8))
        #expect(try manager.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path) == ["pet-hook"])
    }

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
