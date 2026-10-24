import Foundation
import Darwin

public enum PetIPCError: Error, CustomStringConvertible {
    case system(String, Int32)
    case unsafeRuntimeDirectory(String)
    case alreadyRunning
    case socketPathTooLong
    case alreadyStarted

    public var description: String {
        switch self {
        case .system(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
        case .unsafeRuntimeDirectory(let path): "Runtime directory is not owned/private: \(path)"
        case .alreadyRunning: "DSH Native Pet is already running"
        case .socketPathTooLong: "Unix socket path exceeds macOS limit"
        case .alreadyStarted: "Socket server already started"
        }
    }
}

public enum PetRuntimeLocation {
    public static var socketPath: String { RuntimeDirectory(url: nil).socketPath }
}

final class RuntimeDirectory {
    let url: URL
    var socketPath: String { url.appendingPathComponent("pet.sock").path }
    private var lockFD: Int32 = -1
    private var ownsSocket = false

    init(url: URL?) {
        if let url {
            self.url = url
        } else if let configured = ProcessInfo.processInfo.environment["DSH_NATIVE_PET_RUNTIME_DIR"] {
            self.url = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            self.url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/dsh-native-pet", isDirectory: true)
        }
    }

    func prepare() throws {
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw PetIPCError.socketPathTooLong
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(url.path, &directoryInfo) == 0 else { throw PetIPCError.system("lstat runtime directory", errno) }
        guard directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else {
            throw PetIPCError.unsafeRuntimeDirectory(url.path)
        }
        lockFD = open(url.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw PetIPCError.system("open instance lock", errno) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            lockFD = -1
            throw PetIPCError.alreadyRunning
        }
        var socketInfo = stat()
        if lstat(socketPath, &socketInfo) == 0 {
            guard socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == getuid() else {
                release()
                throw PetIPCError.unsafeRuntimeDirectory(socketPath)
            }
            guard unlink(socketPath) == 0 else {
                let code = errno
                release()
                throw PetIPCError.system("unlink stale socket", code)
            }
        } else if errno != ENOENT {
            let code = errno
            release()
            throw PetIPCError.system("lstat socket", code)
        }
        ownsSocket = true
    }

    func restrictSocket() {
        if ownsSocket { chmod(socketPath, 0o600) }
    }

    func release() {
        if ownsSocket {
            unlink(socketPath)
            ownsSocket = false
        }
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    deinit { release() }
}
