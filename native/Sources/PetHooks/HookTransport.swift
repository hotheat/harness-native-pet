import Darwin
import Dispatch
import Foundation

public enum HookIOError: Error { case timeout, system, oversized, invalidPath }

/// All input and socket work shares one monotonic deadline, including a host that never closes stdin.
public struct HookDeadline: Sendable {
    private let end: UInt64

    public init(milliseconds: Int = 500) {
        end = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, milliseconds)) * 1_000_000
    }

    func poll(_ fd: Int32, events: Int16) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < end else { throw HookIOError.timeout }
            let milliseconds = Int32(min(UInt64(Int32.max), (end - now + 999_999) / 1_000_000))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw HookIOError.system }
                return
            }
            if result == 0 { throw HookIOError.timeout }
            if errno != EINTR { throw HookIOError.system }
        }
    }
}

public enum HookTransport {
    public static func readInput(fd: Int32, deadline: HookDeadline) throws -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw HookIOError.system }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            try deadline.poll(fd, events: Int16(POLLIN))
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw HookIOError.system
            }
            guard data.count + count <= HookAdapter.maximumInputBytes else { throw HookIOError.oversized }
            data.append(contentsOf: chunk.prefix(count))
        }
    }

    public static func send(_ data: Data, socketPath: String, deadline: HookDeadline) throws {
        var address = sockaddr_un()
        guard !socketPath.isEmpty, !socketPath.utf8.contains(0),
              socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw HookIOError.invalidPath }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookIOError.system }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw HookIOError.system }
        var noPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe))) == 0 else {
            throw HookIOError.system
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw HookIOError.system }
            try deadline.poll(fd, events: Int16(POLLOUT))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw HookIOError.system }
        }
        var frame = data
        frame.append(0x0A)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try deadline.poll(fd, events: Int16(POLLOUT))
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw HookIOError.system }
                offset += count
            }
        }
    }
}
