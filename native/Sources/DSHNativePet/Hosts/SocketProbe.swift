import Foundation
import Darwin
import PetIPC

enum SocketProbe {
    static func probe(path: String = PetRuntimeLocation.socketPath, timeout: TimeInterval = 1) -> Result<Void, PetIPCError> {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
            return .failure(.socketPathTooLong)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.system("socket", errno)) }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            return .failure(.system("fcntl", errno))
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return .success(()) }
        guard errno == EINPROGRESS else { return .failure(.system("connect", errno)) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if ready == 0 { return .failure(.system("connect", ETIMEDOUT)) }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(.system("poll", errno))
            }
            var code: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: code))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else {
                return .failure(.system("getsockopt", errno))
            }
            return code == 0 ? .success(()) : .failure(.system("connect", code))
        }
    }
}
