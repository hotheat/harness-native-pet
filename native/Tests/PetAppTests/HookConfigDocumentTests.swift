import Foundation
import Testing
@testable import DSHNativePet

struct HookConfigDocumentTests {
    @Test func quotingMatchesSharedFixturesAndRealPythonShlex() throws {
        let cases = try fixtures()["quotes"] as! [[String: String]]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import json,shlex,sys; print(json.dumps([shlex.quote(p) for p in json.load(sys.stdin)]))"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: cases.map { $0["path"]! }))
        try input.fileHandleForWriting.close()
        let quoted = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as! [String]
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        for (index, item) in cases.enumerated() {
            let path = item["path"]!
            #expect(HookTarget.shellQuote(path) == item["quoted"])
            #expect(HookTarget.shellQuote(path) == quoted[index])
            for target in HookTarget.allCases {
                #expect(target.command(helperPath: path) == quoted[index] + " " + target.rawValue)
            }
        }
    }

    private func fixtures() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/fixtures/host-hooks.json"))) as! [String: Any]
    }

    @Test func sharedMergeFixtures() throws {
        let fixtures = try fixtures()
        let events = fixtures["events"] as! [String: [String]]
        for target in HookTarget.allCases { #expect(target.events == events[target.rawValue]) }
        for item in fixtures["cases"] as! [[String: Any]] {
            let config = item["config"] as! [String: Any]
            let command = item["command"] as! String
            let target = item["target"] as! String
            let remove = item["operation"] as! String == "remove"
            if item["error"] != nil {
                #expect(throws: HookConfigDocument.ConfigError.self) {
                    try HookConfigDocument.merge(config: config, command: command, events: events[target]!, remove: remove)
                }
            } else {
                let result = try HookConfigDocument.merge(config: config, command: command, events: events[target]!, remove: remove)
                #expect(HookConfigDocument.equal(result, item["expected"] as! [String: Any]), Comment(rawValue: item["name"] as! String))
                #expect(HookConfigDocument.equal(result, try HookConfigDocument.merge(config: result, command: command, events: events[target]!, remove: remove)))
            }
        }
    }

    @Test func atomicSaveBacksUpPreservesModeAndSkipsUnchangedBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pet-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        let original = Data("{\"env\": {\"keep\": true}}".utf8)
        try original.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        let inode = try attributes(path)[.systemFileNumber] as! NSNumber
        #expect(try HookConfigDocument.save(path: path, command: "pet-hook codex", events: ["Stop"], now: Date(timeIntervalSince1970: 0)))
        #expect(try attributes(path)[.systemFileNumber] as! NSNumber != inode)
        #expect(try attributes(path)[.posixPermissions] as! NSNumber == 0o640)
        let backup = directory.appendingPathComponent("settings.json.dsh-native-pet-19700101T000000000000Z.bak")
        #expect(try Data(contentsOf: backup) == original)
        #expect(try attributes(backup)[.posixPermissions] as! NSNumber == 0o600)
        let installed = try Data(contentsOf: path)
        let installedInode = try attributes(path)[.systemFileNumber] as! NSNumber
        #expect(try !HookConfigDocument.save(path: path, command: "pet-hook codex", events: ["Stop"]))
        #expect(try Data(contentsOf: path) == installed)
        #expect(try attributes(path)[.systemFileNumber] as! NSNumber == installedInode)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
        #expect(try HookConfigDocument.save(path: path, command: "pet-hook codex", events: ["Stop"], remove: true))
        #expect(try HookConfigDocument.equal(HookConfigDocument.load(path), ["env": ["keep": true]]))
    }

    @Test func renameFailureLeavesOriginalAndCleansTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pet-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hooks.json")
        let original = Data("{\"keep\": 42}".utf8)
        try original.write(to: path)
        let inode = try attributes(path)[.systemFileNumber] as! NSNumber
        #expect(throws: POSIXError.self) {
            try HookConfigDocument.save(path: path, command: "pet-hook codex", events: ["Stop"], replace: { temporary, destination in
                #expect(temporary.deletingLastPathComponent() == destination.deletingLastPathComponent())
                #expect(try Data(contentsOf: destination) == original)
                throw POSIXError(.EACCES)
            })
        }
        #expect(try Data(contentsOf: path) == original)
        #expect(try attributes(path)[.systemFileNumber] as! NSNumber == inode)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 2)
        #expect(!files.contains { $0.hasPrefix(".pet-hooks-") })
    }

    @Test func invalidDocumentsNeverChangeOrCreateBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pet-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hooks.json")
        for text in ["bad json", "[]", "null", #"{"hooks":[]}"#, #"{"hooks":{"Stop":"bad"}}"#, #"{"hooks":{"Stop":[{}]}}"#] {
            let bytes = Data(text.utf8)
            try bytes.write(to: path)
            #expect(throws: (any Error).self) { try HookConfigDocument.save(path: path, command: "ours", events: ["Stop"]) }
            #expect(try Data(contentsOf: path) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hooks.json"])
        }
    }

    @Test func missingConfigUsesPrivateDirectoriesAndDefaultMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pet-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nested/hooks.json")
        #expect(try !HookConfigDocument.save(path: path, command: "ours", events: ["Stop"], remove: true))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try HookConfigDocument.save(path: path, command: "ours", events: ["Stop"]))
        #expect(try attributes(path)[.posixPermissions] as! NSNumber == 0o600)
        #expect(try attributes(path.deletingLastPathComponent())[.posixPermissions] as! NSNumber == 0o700)
    }

    private func attributes(_ path: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path.path)
    }
}
