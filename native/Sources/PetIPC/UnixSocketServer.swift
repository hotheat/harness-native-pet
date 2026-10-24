import Foundation
import Darwin
import Dispatch
import PetCore

// Listener, callbacks, clients, and runtime resources are confined to queue.
public final class UnixSocketServer: @unchecked Sendable {
    // All mutable client state is confined to the server serial queue.
    private final class Client: @unchecked Sendable {
        let fd: Int32
        var reader: DispatchSourceRead?
        let id = UUID()
        var sourceID: String?
        var activityOnly = false
        var sequence = 0
        var buffer = Data()
        var deadline = DispatchTime.now() + .seconds(15)
        var finalized = false

        init(_ fd: Int32) { self.fd = fd }
    }

    private let runtime: RuntimeDirectory
    private let queue = DispatchQueue(label: "dsh-native-pet.ipc")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listener: DispatchSourceRead?
    private var listenerFD: Int32 = -1
    private var generation: UUID?
    private var clients: [UUID: Client] = [:]
    private var sourceOwners: [String: UUID] = [:]
    private var timer: DispatchSourceTimer?
    private var onMessage: (@Sendable (BridgeMessage) -> Void)?
    private var onDisconnect: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    public var socketPath: String { runtime.socketPath }

    public init(runtimeDirectory: URL? = nil) {
        runtime = RuntimeDirectory(url: runtimeDirectory)
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start(onMessage: @escaping @Sendable (BridgeMessage) -> Void,
                      onDisconnect: @escaping @Sendable (String) -> Void,
                      onError: @escaping @Sendable (String) -> Void = { _ in },
                      onReady: @escaping @Sendable () -> Void = {}) throws {
        try synchronized {
            guard self.listener == nil else { throw PetIPCError.alreadyStarted }
            try runtime.prepare()
            do {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw PetIPCError.system("socket", errno) }
                do {
                    try makeNonblocking(fd)
                    var address = sockaddr_un()
                    address.sun_family = sa_family_t(AF_UNIX)
                    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: runtime.socketPath.utf8) }
                    let bound = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    guard bound == 0 else { throw PetIPCError.system("bind", errno) }
                    guard Darwin.listen(fd, 128) == 0 else { throw PetIPCError.system("listen", errno) }
                } catch {
                    Darwin.close(fd)
                    throw error
                }
                let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                let generation = UUID()
                self.listener = listener
                self.listenerFD = fd
                self.generation = generation
                self.onMessage = onMessage
                self.onDisconnect = onDisconnect
                self.onError = onError
                listener.setEventHandler { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.acceptClients()
                }
                listener.setCancelHandler { Darwin.close(fd) }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
                timer.setEventHandler { [weak self] in self?.expireClients() }
                self.timer = timer
                timer.resume()
                runtime.restrictSocket()
                listener.resume()
                onReady()
            } catch {
                runtime.release()
                throw error
            }
        }
    }

    public func stop() { synchronized { stopLocked() } }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    private func stopLocked() {
        guard listener != nil else { return }
        generation = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        listener?.setEventHandler {}
        listenerFD = -1
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { finalize(client) }
        runtime.release()
        onMessage = nil
        onDisconnect = nil
        onError = nil
    }

    private func makeNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw PetIPCError.system("fcntl", errno)
        }
    }

    private func acceptClients() {
        while listenerFD >= 0 {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { onError?("IPC accept failed: \(errno)") }
                return
            }
            do { try makeNonblocking(fd) } catch { Darwin.close(fd); continue }
            let client = Client(fd)
            clients[client.id] = client
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            client.reader = reader
            reader.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.receive(client)
            }
            reader.setCancelHandler { Darwin.close(fd) }
            reader.resume()
            // A hook can exit before accept; POSIX retains all bytes until read.
            receive(client)
        }
    }

    private func receive(_ client: Client) {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while !client.finalized {
            let count = Darwin.recv(client.fd, &bytes, bytes.count, 0)
            if count > 0 {
                client.buffer.append(contentsOf: bytes.prefix(count))
                do {
                    while let newline = client.buffer.firstIndex(of: 0x0A) {
                        let message = try BridgeMessage.decode(Data(client.buffer.prefix(upTo: newline)))
                        client.buffer.removeSubrange(...newline)
                        try consume(message, from: client)
                        if client.finalized { return }
                    }
                    guard client.buffer.count <= BridgeMessage.maximumLineBytes else {
                        throw BridgeMessageError.invalid("unterminated message too large")
                    }
                } catch { finalize(client); return }
                continue
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
            }
            if !client.buffer.isEmpty {
                do { try consume(BridgeMessage.decode(client.buffer), from: client) }
                catch { /* Incomplete/invalid final frames are discarded. */ }
            }
            finalize(client)
        }
    }

    private func consume(_ message: BridgeMessage, from client: Client) throws {
        if case .activity = message {
            guard client.sourceID == nil else { throw BridgeMessageError.invalid("mixed connection modes") }
            client.activityOnly = true
            onMessage?(message)
            return
        }
        guard !client.activityOnly else { throw BridgeMessageError.invalid("mixed connection modes") }
        if let sourceID = client.sourceID {
            guard sourceID == message.sourceID else { throw BridgeMessageError.invalid("connection identity changed") }
        } else {
            guard case .snapshot = message else { throw BridgeMessageError.invalid("first message must be snapshot") }
            if let oldID = sourceOwners[message.sourceID], let old = clients[oldID] {
                finalize(old)
            }
            client.sourceID = message.sourceID
            sourceOwners[message.sourceID] = client.id
        }
        guard message.sequence > client.sequence else { return }
        client.sequence = message.sequence
        client.deadline = .now() + .seconds(15)
        onMessage?(message)
    }

    private func expireClients() {
        let now = DispatchTime.now()
        for client in Array(clients.values) where client.deadline <= now { finalize(client) }
    }

    private func finalize(_ client: Client) {
        guard !client.finalized else { return }
        client.finalized = true
        clients.removeValue(forKey: client.id)
        client.reader?.setEventHandler {}
        client.reader?.cancel()
        client.reader = nil
        client.buffer.removeAll(keepingCapacity: false)
        if let sourceID = client.sourceID, sourceOwners[sourceID] == client.id {
            sourceOwners.removeValue(forKey: sourceID)
            onDisconnect?(sourceID)
        }
    }

    deinit {
        timer?.cancel()
        listener?.cancel()
        clients.values.forEach { $0.reader?.cancel() }
        runtime.release()
    }
}
