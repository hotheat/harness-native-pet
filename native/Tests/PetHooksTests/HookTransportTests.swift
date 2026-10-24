import Darwin
import Foundation
import PetCore
import Testing
@testable import PetHooks

private enum HookTestError: Error { case socket(Int32), executableMissing, processTimeout }

private final class HookTestSocket {
    let directory = URL(fileURLWithPath: "/tmp/afkh-\(UUID().uuidString.prefix(10))", isDirectory: true)
    let fd: Int32
    var path: String { directory.appendingPathComponent("pet.sock").path }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookTestError.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let error = errno
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw HookTestError.socket(error)
        }
    }

    func receive() throws -> Data {
        let deadline = HookDeadline(milliseconds: 1_000)
        try deadline.poll(fd, events: Int16(POLLIN))
        let client = accept(fd, nil, nil)
        guard client >= 0 else { throw HookTestError.socket(errno) }
        defer { Darwin.close(client) }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try deadline.poll(client, events: Int16(POLLIN))
            let count = Darwin.read(client, &bytes, bytes.count)
            guard count >= 0 else { throw HookTestError.socket(errno) }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            if data.last == 0x0A { return data }
        }
    }

    deinit {
        Darwin.close(fd)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized)
struct HookTransportTests {
    private let input = Data(#"{"hook_event_name":"Stop","session_id":"session","turn_id":"turn","prompt_id":"prompt","last_assistant_message":"secret answer"}"#.utf8)

    @Test func realSocketReceivesOneNewlineDelimitedEvent() throws {
        let listener = try HookTestSocket()
        let event = try #require(try HookAdapter.normalize(input, provider: .codex))
        try HookTransport.send(HookAdapter.encode(event), socketPath: listener.path, deadline: HookDeadline())
        let received = try listener.receive()
        #expect(received.last == 0x0A)
        #expect(try JSONDecoder().decode(PetActivityEvent.self, from: received) == event)
    }

    @Test func absentAppFailsFastAndNeverCreatesRuntimeDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp/afkh-missing-\(UUID().uuidString.prefix(10))")
        let start = Date()
        #expect(throws: HookIOError.self) {
            try HookTransport.send(input, socketPath: directory.appendingPathComponent("pet.sock").path, deadline: HookDeadline())
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func stdinWithoutEOFIsBoundedAndOversizedInputIsBounded() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let start = Date()
        #expect(throws: HookIOError.self) {
            try HookTransport.readInput(fd: pipe.fileHandleForReading.fileDescriptor, deadline: HookDeadline(milliseconds: 50))
        }
        #expect(Date().timeIntervalSince(start) < 0.5)

        let file = URL(fileURLWithPath: "/tmp/afkh-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 32, count: HookAdapter.maximumInputBytes + 1).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #expect(throws: HookIOError.self) {
            try HookTransport.readInput(fd: handle.fileDescriptor, deadline: HookDeadline())
        }
    }

    private func executable() throws -> URL {
        let arguments = CommandLine.arguments
        let bundleIndex = arguments.firstIndex(of: "--test-bundle-path")
        let binaryPath = bundleIndex.map { arguments[$0 + 1] } ?? arguments[0]
        var directory = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        for _ in 0..<6 {
            let binary = directory.appendingPathComponent("PetHookCLI")
            if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            directory.deleteLastPathComponent()
        }
        throw HookTestError.executableMissing
    }

    private func run(_ arguments: [String], data: Data?, directory: URL) throws -> (Int32, Data, String, TimeInterval) {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_NATIVE_PET_RUNTIME_DIR"] = directory.path
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let start = Date()
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? stdin.fileHandleForWriting.close()
        }
        if let data {
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
        }
        while process.isRunning {
            guard Date().timeIntervalSince(start) < 3 else { throw HookTestError.processTimeout }
            Thread.sleep(forTimeInterval: 0.005)
        }
        process.waitUntilExit()
        return (process.terminationStatus, stdout.fileHandleForReading.readDataToEndOfFile(),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), Date().timeIntervalSince(start))
    }

    @Test func cliDryRunIsMetadataOnlyAndProductionNeverChangesHostDecision() throws {
        let missing = URL(fileURLWithPath: "/tmp/afkh-no-app-\(UUID().uuidString.prefix(10))")
        let dry = try run(["claude-code", "--dry-run"], data: input, directory: missing)
        #expect(dry.0 == 0)
        let event = try JSONDecoder().decode(PetActivityEvent.self, from: dry.1)
        #expect(event.provider == .claudeCode)
        #expect(event.turnId == "prompt")
        #expect(!String(decoding: dry.1, as: UTF8.self).contains("secret answer"))
        for arguments in [["codex"], ["codex", "--strict"]] {
            let result = try run(arguments, data: input, directory: missing)
            #expect(result.0 == (arguments.contains("--strict") ? 1 : 0))
            #expect(String(decoding: result.1, as: UTF8.self) == "{}\n")
            #expect(result.2 == "pet-hook: event not delivered\n")
            #expect(result.3 < 1)
        }
        let malformed = try run(["claude-code"], data: Data("secret broken payload".utf8), directory: missing)
        #expect(malformed.0 == 0)
        #expect(String(decoding: malformed.1, as: UTF8.self) == "{}\n")
        #expect(!malformed.2.contains("secret"))
        let stalled = try run(["codex"], data: nil, directory: missing)
        #expect(stalled.0 == 0)
        #expect(stalled.3 < 1)
    }

    @Test func cliDeliversToRealSocketAndExitsWithoutWaitingForReply() throws {
        let listener = try HookTestSocket()
        let result = try run(["codex", "--strict"], data: input, directory: listener.directory)
        #expect(result.0 == 0)
        #expect(String(decoding: result.1, as: UTF8.self) == "{}\n")
        #expect(result.2.isEmpty)
        #expect(result.3 < 1)
        let event = try JSONDecoder().decode(PetActivityEvent.self, from: listener.receive())
        #expect(event.provider == .codex)
        #expect(event.kind == .turnEnded)
    }
}
