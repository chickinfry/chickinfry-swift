import Foundation
import Testing
@testable import SwiftSDKDriver
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class TestBundleMarker: NSObject {}

final class DriverProcess {
    let input: FileHandle
    let protected: FileHandle
    private let output: FileHandle
    private let pid: pid_t
    private var reaped = false
    private var framer = Framer(limit: 16 * 1024 * 1024)
    private var pending: [Data] = []

    init(environment: [String: String] = [:]) throws {
        var directory = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
        var binary: URL?
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("swift-sdk-driver")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }
            directory.deleteLastPathComponent()
        }
        let executable = try #require(binary)
        let control = Pipe(), responses = Pipe(), credentials = Pipe()
        #if canImport(Darwin)
        for handle in [control.fileHandleForWriting, credentials.fileHandleForWriting] {
            guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw ProtocolFailure.violation }
        }
        #endif
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProtocolFailure.violation }
        defer { #expect(posix_spawn_file_actions_destroy(&actions) == 0) }
        guard posix_spawn_file_actions_adddup2(&actions, control.fileHandleForReading.fileDescriptor, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, responses.fileHandleForWriting.fileDescriptor, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, credentials.fileHandleForReading.fileDescriptor, 3) == 0
        else { throw ProtocolFailure.violation }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProtocolFailure.violation }
        defer { #expect(posix_spawnattr_destroy(&attributes) == 0) }
        // Close unrelated pipe ends even if another test has not yet set CLOEXEC.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw ProtocolFailure.violation
        }
        let arguments = [executable.path, "--plain-sdk", "/plain", "--auth-sdk", "/auth"].map { strdup($0) }
        let variables = environment.map { strdup($0.key + "=" + $0.value) }
        defer { for pointer in arguments + variables { free(pointer) } }
        var argv = arguments + [nil], envp = variables + [nil]
        var child: pid_t = 0
        guard posix_spawn(&child, executable.path, &actions, &attributes, &argv, &envp) == 0 else {
            throw ProtocolFailure.violation
        }
        pid = child
        input = control.fileHandleForWriting
        protected = credentials.fileHandleForWriting
        output = responses.fileHandleForReading
        try control.fileHandleForReading.close()
        try responses.fileHandleForWriting.close()
        try credentials.fileHandleForReading.close()
    }

    deinit {
        try? input.close()
        try? protected.close()
        try? output.close()
        if !reaped { kill(pid, SIGKILL); waitpid(pid, nil, 0) }
    }

    func send(_ message: JSON) throws {
        try input.write(contentsOf: JSONEncoder().encode(message) + Data([10]))
    }

    func sendCredentials(_ values: [String: String]) throws {
        for (ref, value) in values.sorted(by: { $0.key < $1.key }) {
            try protected.write(contentsOf: JSONEncoder().encode(JSON.object([
                "ref": .string(ref), "value": .string(value),
            ])) + Data([10]))
        }
    }

    func readMessage() throws -> JSON? {
        let end = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while pending.isEmpty {
            guard DispatchTime.now().uptimeNanoseconds < end else { throw ProtocolFailure.deadline }
            var ready = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&ready, 1, 100)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw ProtocolFailure.violation }
            if result == 0 { continue }
            // FileHandle can wait for more pipe bytes after poll has reported a short response.
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(output.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ProtocolFailure.violation }
            guard count > 0 else {
                try framer.end()
                return nil
            }
            pending += try framer.append(Data(buffer.prefix(count)))
        }
        var parser = try JSONParser(pending.removeFirst())
        return try parser.parse()
    }

    func finish() throws -> (status: Int32, messages: [JSON]) {
        try? protected.close()
        try? input.close()
        var messages: [JSON] = []
        while let message = try readMessage() { messages.append(message) }
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid else { throw ProtocolFailure.violation }
        reaped = true
        return (status, messages)
    }
}
