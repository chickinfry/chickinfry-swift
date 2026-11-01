import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum DeviceLimits {
    static let bundleBytes = 8 * 1024
    static let attempts = 3
    static let commitAttempts = 3
    static let identifierBytes = 36
    static let emailCharacters = 320
    static let screenBytes = 64
    static let attemptLifetime: Int64 = 24 * 60 * 60
    static let errorCodes: Set<String> = ["device_storage_unavailable", "device_storage_corrupt",
                                         "device_storage_full", "device_storage_version_unsupported"]
}

func deviceError(_ code: String = "device_storage_unavailable") -> ClientError {
    ClientError(code: code, status: nil)
}

/// All paths below the opened directory are relative to a verified directory descriptor.
final class DeviceFiles: Sendable {
    static let processLock = NSLock()
    let descriptor: Int32
    let url: URL

    init(path: String, baseDirectory: Bool = false) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw deviceError() }
        let components = path.split(separator: "/")
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw deviceError()
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw deviceError() }
        do {
            for (index, component) in components.enumerated() {
                let name = String(component)
                if mkdirat(current, name, 0o700) != 0 && errno != EEXIST { throw Self.failure() }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure() }
                close(current)
                current = next
                var info = stat()
                guard fstat(current, &info) == 0 else { throw Self.failure() }
                guard info.st_uid == getuid() || info.st_uid == 0 else { throw deviceError() }
                if index == components.count - 1 {
                    guard info.st_uid == getuid() else { throw deviceError() }
                    if baseDirectory {
                        guard info.st_mode & 0o022 == 0 else { throw deviceError() }
                    } else {
                        guard info.st_mode & 0o777 == 0o700 else { throw deviceError() }
                    }
                }
            }
            descriptor = current
            url = URL(fileURLWithPath: path, isDirectory: true)
            #if canImport(Security)
            if !baseDirectory {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var location = url
                try location.setResourceValues(values)
            }
            #endif
        } catch let error as ClientError { close(current); throw error }
        catch { close(current); throw deviceError() }
    }

    deinit { close(descriptor) }

    func locked<Value>(isolation: isolated (any Actor)? = #isolation, _ action: () throws -> Value) throws -> Value {
        DeviceFiles.processLock.lock()
        defer { DeviceFiles.processLock.unlock() }
        let lock = openat(descriptor, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Self.failure() }
        defer { close(lock) }
        try Self.validate(lock)
        var acquired = false
        for _ in 0..<500 {
            if lockf(lock, F_TLOCK, 0) == 0 { acquired = true; break }
            guard errno == EACCES || errno == EAGAIN || errno == EINTR else { throw Self.failure() }
            usleep(10_000)
        }
        guard acquired else { throw deviceError() }
        defer { _ = lockf(lock, F_ULOCK, 0) }
        return try action()
    }

    func read(_ name: String, limit: Int = DeviceLimits.bundleBytes) throws -> Data? {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw Self.failure()
        }
        defer { close(file) }
        try Self.validate(file)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit + 1, 4096))
        while true {
            #if os(Linux)
            let count = Glibc.read(file, &buffer, buffer.count)
            #else
            let count = Darwin.read(file, &buffer, buffer.count)
            #endif
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failure()
            }
            guard data.count + count <= limit else { throw deviceError("device_storage_full") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func write(_ name: String, data: Data, excludeFromBackup: Bool = false,
               beforeRename: (@Sendable () throws -> Void)? = nil,
               syncDirectory: (Int32) -> Int32 = { fsync($0) }) throws {
        guard data.count <= DeviceLimits.bundleBytes else { throw deviceError("device_storage_full") }
        let temporary = ".write-" + UUID().uuidString
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.failure() }
        defer { close(file); _ = unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let count = Glibc.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.failure() }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw Self.failure() }
        try beforeRename?()
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.failure() }
        #if canImport(Security)
        if excludeFromBackup {
            var location = url.appendingPathComponent(name)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            try verifyBackupExclusion(name)
            guard fsync(file) == 0 else { throw Self.failure() }
        }
        #endif
        guard syncDirectory(descriptor) == 0 else { throw Self.failure() }
    }

    #if canImport(Security)
    func verifyBackupExclusion(_ name: String) throws {
        let values = try url.appendingPathComponent(name).resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard values.isExcludedFromBackup == true else { throw deviceError() }
    }
    #endif

    func discardPendingWrites() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where name.hasPrefix(".write-") && UUID(uuidString: String(name.dropFirst(7))) != nil {
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw Self.failure() }
            defer { close(file) }
            try Self.validate(file)
            guard unlinkat(descriptor, name, 0) == 0 else { throw Self.failure() }
        }
    }

    private static func validate(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw failure() }
        guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw deviceError() }
    }

    private static func failure() -> ClientError {
        deviceError(errno == ENOSPC || errno == EDQUOT ? "device_storage_full" : "device_storage_unavailable")
    }
}
