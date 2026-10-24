import Foundation
import Dispatch
import Darwin
import Testing
import PetCore
@testable import PetIPC

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var events: [String] { lock.withLock { stored } }
}

private enum TestFailure: Error { case system(Int32), timeout }

private final class POSIXClient {
    private var fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure.system(errno) }
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: path.utf8) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close()
            throw TestFailure.system(code)
        }
    }

    func write(_ value: String) throws { try write(Data(value.utf8)) }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written, 0)
                guard count > 0 else { throw TestFailure.system(errno) }
                written += count
            }
        }
    }

    func finishWrites() { Darwin.shutdown(fd, SHUT_WR) }

    func expectClosed() throws {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 3000) > 0 else { throw TestFailure.timeout }
        var byte: UInt8 = 0
        #expect(Darwin.recv(fd, &byte, 1, 0) == 0)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    deinit { close() }
}

@Suite(.serialized)
struct UnixSocketServerTests {
    @Test @MainActor func shortLivedSnapshotCompletionIsSilentAndEOFRemovesSession() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let store = PetStore()
        let recorder = Recorder()
        try server.start(onMessage: { message in
            Task { @MainActor in
                if case .snapshot(let snapshot) = message { store.apply(snapshot) }
                recorder.append("frame:\(store.presentation().sessions.count):\(store.presentation().pose)")
            }
        }, onDisconnect: { source in
            Task { @MainActor in
                store.disconnect(sourceID: source)
                recorder.append("eof:\(store.presentation().sessions.count)")
            }
        }, onReady: { recorder.append("ready") })
        while recorder.events.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let client = try POSIXClient(path: server.socketPath)
        try client.write(#"{"type":"snapshot","sourceId":"short-hook","sourceLabel":"Codex","seq":1,"sessions":[{"sessionId":"s","turn":1,"phase":"completed","activeTools":0,"pendingApprovals":0,"result":{"id":"r","outcome":"completed"}}]}"# + "\n")
        client.close()
        let deadline = Date().addingTimeInterval(3)
        while recorder.events.count < 3 {
            guard Date() < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.events == ["ready", "frame:1:idle", "eof:0"])
    }

    private func location() -> URL {
        URL(fileURLWithPath: "/tmp/dnp-\(UUID().uuidString.prefix(12))", isDirectory: true)
    }

    private func wait(_ timeout: TimeInterval = 3, for condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TestFailure.timeout }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func start(_ server: UnixSocketServer, _ recorder: Recorder) throws {
        let ready = DispatchSemaphore(value: 0)
        try server.start(onMessage: { message in recorder.append("message:\(message.sourceID):\(message.sequence)") },
                         onDisconnect: { recorder.append("disconnect:\($0)") },
                         onError: { recorder.append("error:\($0)"); ready.signal() },
                         onReady: { ready.signal() })
        guard ready.wait(timeout: .now() + 3) == .success else { throw TestFailure.timeout }
        #expect(!recorder.events.contains(where: { $0.hasPrefix("error:") }))
    }

    private func snapshot(_ source: String = "a", seq: Int = 1) -> String {
        "{\"type\":\"snapshot\",\"sourceId\":\"\(source)\",\"sourceLabel\":\"DSH\",\"seq\":\(seq),\"sessions\":[]}\n"
    }

    private func activity(_ id: String = "e") -> String {
        #"{"type":"activity","provider":"codex","sessionId":"same","turnId":"t","eventId":""# + id + #"","kind":"turnEnded","occurredAt":1000,"toolId":null}"#
    }

    @Test @MainActor func shortLivedActivityEOFDeliversStopAndPreservesSessionWithoutHeartbeat() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let store = PetStore()
        let recorder = Recorder()
        try server.start(onMessage: { message in
            Task { @MainActor in
                if case .activity(let event) = message { store.apply(event) }
                recorder.append("activity")
            }
        }, onDisconnect: { source in
            Task { @MainActor in
                store.disconnect(sourceID: source)
                recorder.append("disconnect")
            }
        }, onReady: { recorder.append("ready") })
        let deadline = Date().addingTimeInterval(3)
        while recorder.events.isEmpty {
            guard Date() < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        // EOF also completes a valid final JSON frame without a newline.
        let first = try POSIXClient(path: server.socketPath)
        try first.write(activity())
        first.close()
        while recorder.events.count < 2 {
            guard Date() < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = try POSIXClient(path: server.socketPath)
        try second.write(activity() + "\n")
        second.close()
        while recorder.events.count < 3 {
            guard Date() < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        server.stop()
        #expect(recorder.events == ["ready", "activity", "activity"])
        #expect(store.presentation().sessions.count == 1)
        #expect(store.presentation().sessions.first?.phase == .completed)
        #expect(store.drainNotices().map(\.kind) == [.ended])
    }

    @Test func activityAndSnapshotConnectionModesCannotMix() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let recorder = Recorder()
        try start(server, recorder)
        let persistent = try POSIXClient(path: server.socketPath)
        try persistent.write(snapshot() + activity() + "\n")
        try wait { recorder.events.count == 2 }
        #expect(recorder.events == ["message:a:1", "disconnect:a"])
        let oneShot = try POSIXClient(path: server.socketPath)
        try oneShot.write(activity() + "\n" + snapshot("other"))
        try wait { recorder.events.count == 3 }
        oneShot.close()
        persistent.close()
        server.stop()
        #expect(recorder.events == ["message:a:1", "disconnect:a", "message:hook:codex:0"])
    }

    @Test func consecutiveShortLivedActivityConnectionsDoNotDropFramesOrDisconnectSources() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let recorder = Recorder()
        try start(server, recorder)
        for index in 0..<100 {
            let client = try POSIXClient(path: server.socketPath)
            try client.write(activity("event-\(index)") + (index.isMultiple(of: 2) ? "\n" : ""))
            client.close()
        }
        try wait { recorder.events.count == 100 }
        server.stop()
        #expect(recorder.events.count == 100)
        #expect(recorder.events.allSatisfy { $0 == "message:hook:codex:0" })
    }

    @Test func fragmentedAndCoalescedFramesDiscardStaleSequence() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let recorder = Recorder()
        try start(server, recorder)
        let client = try POSIXClient(path: server.socketPath)
        let frame = snapshot()
        try client.write(String(frame.prefix(20)))
        try client.write(String(frame.dropFirst(20)) + #"{"type":"heartbeat","sourceId":"a","seq":2}"# + "\n" + snapshot(seq: 1) + snapshot(seq: 3))
        try wait { recorder.events.count == 3 }
        #expect(recorder.events == ["message:a:1", "message:a:2", "message:a:3"])
        client.close()
        try wait { recorder.events.count == 4 }
        server.stop()
        server.stop()
        #expect(recorder.events.filter { $0 == "disconnect:a" }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: server.socketPath))
    }

    @Test func sourceReplacementDoesNotLetOldCloseRemoveNewSource() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let recorder = Recorder()
        try start(server, recorder)
        let first = try POSIXClient(path: server.socketPath)
        try first.write(snapshot(seq: 5))
        try wait { recorder.events.count == 1 }
        let second = try POSIXClient(path: server.socketPath)
        try second.write(snapshot(seq: 1))
        try wait { recorder.events.count == 3 }
        first.close()
        try second.write(snapshot(seq: 2))
        try wait { recorder.events.count == 4 }
        #expect(recorder.events == ["message:a:5", "disconnect:a", "message:a:1", "message:a:2"])
        second.close()
        try wait { recorder.events.count == 5 }
        #expect(recorder.events.last == "disconnect:a")
    }

    @Test func identityChangeAndInvalidFrameFinalizeExactlyOnce() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let recorder = Recorder()
        try start(server, recorder)
        let client = try POSIXClient(path: server.socketPath)
        try client.write(snapshot() + snapshot("spoof", seq: 2))
        try wait { recorder.events.count == 2 }
        client.close()
        #expect(recorder.events == ["message:a:1", "disconnect:a"])
        let invalid = try POSIXClient(path: server.socketPath)
        try invalid.write(#"{"type":"heartbeat","sourceId":"b","seq":1}"# + "\n")
        invalid.close()
        server.stop()
        #expect(recorder.events == ["message:a:1", "disconnect:a"])
    }

    @Test func invalidOversizedFrameDisconnectsAndRestartReacquiresLock() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        let recorder = Recorder()
        try start(server, recorder)
        defer { server.stop() }
        let another = UnixSocketServer(runtimeDirectory: directory)
        #expect(throws: PetIPCError.self) { try another.start(onMessage: { _ in }, onDisconnect: { _ in }) }
        let client = try POSIXClient(path: server.socketPath)
        try client.write(snapshot())
        try wait { recorder.events.count == 1 }
        try client.write(Data(repeating: 32, count: BridgeMessage.maximumLineBytes + 1))
        try wait { recorder.events.count == 2 }
        #expect(recorder.events.last == "disconnect:a")
        server.stop()
        try start(another, Recorder())
        another.stop()
        #expect(!FileManager.default.fileExists(atPath: server.socketPath))
    }

    @Test func inactivityExpiresWithoutCompletionOrDuplicateDisconnect() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        let recorder = Recorder()
        try start(server, recorder)
        defer { server.stop() }
        let client = try POSIXClient(path: server.socketPath)
        try client.write(snapshot())
        try wait { recorder.events.count == 1 }
        try wait(17) { recorder.events.count == 2 }
        client.close()
        server.stop()
        #expect(recorder.events == ["message:a:1", "disconnect:a"])
    }

    @Test func failedPreparationPreservesExistingNonSocketFile() throws {
        let directory = location()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("pet.sock")
        try Data("keep".utf8).write(to: socket)
        let server = UnixSocketServer(runtimeDirectory: directory)
        #expect(throws: PetIPCError.self) { try server.start(onMessage: { _ in }, onDisconnect: { _ in }) }
        #expect(try String(contentsOf: socket, encoding: .utf8) == "keep")
        server.stop()
    }
    @Test(arguments: [true, false]) func incompatibleVersionClosesOnlyItsClient(newline: Bool) throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        let recorder = Recorder()
        try server.start(onMessage: { recorder.append("message:\($0.sourceID):\($0.sequence)") },
                         onDisconnect: { recorder.append("disconnect:\($0)") },
                         onError: { recorder.append("error:\($0)") },
                         onIncompatible: { _ in recorder.append("incompatible") })
        let healthy = try POSIXClient(path: server.socketPath)
        try healthy.write(snapshot())
        try wait { recorder.events.count == 1 }
        let bad = try POSIXClient(path: server.socketPath)
        try bad.write(#"{"type":"heartbeat","sourceId":"bad","seq":1,"v":2}"# + (newline ? "\n" : ""))
        if !newline { bad.finishWrites() }
        try bad.expectClosed()
        try wait { recorder.events.count == 2 }
        #expect(recorder.events == ["message:a:1", "incompatible"])
        try healthy.write(snapshot(seq: 2))
        try wait { recorder.events.count == 3 }
        #expect(recorder.events.last == "message:a:2")
    }

}
