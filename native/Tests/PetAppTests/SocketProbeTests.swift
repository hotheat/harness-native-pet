import Foundation
import PetIPC
import Testing
@testable import DSHNativePet

struct SocketProbeTests {
    @Test func connectsToListenerThenClosesWithoutSendingActivity() throws {
        let directory = URL(fileURLWithPath: "/tmp/pet-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(runtimeDirectory: directory)
        defer { server.stop() }
        try server.start(onMessage: { _ in Issue.record("probe must not send a message") },
                         onDisconnect: { _ in Issue.record("probe must not identify a source") })
        try SocketProbe.probe(path: server.socketPath).get()
        try SocketProbe.probe(path: server.socketPath).get()
    }

    @Test func missingSocketAndOversizedPathFailPromptly() {
        let started = ProcessInfo.processInfo.systemUptime
        if case .success = SocketProbe.probe(path: "/tmp/pet-missing-\(UUID()).sock", timeout: 0.02) {
            Issue.record("missing socket must fail")
        }
        if case .failure(.socketPathTooLong) = SocketProbe.probe(path: String(repeating: "a", count: 200)) {} else {
            Issue.record("oversized path must fail")
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }
}
