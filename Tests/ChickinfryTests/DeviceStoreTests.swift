import Foundation
import XCTest
#if os(macOS)
import MachO
#endif
import Testing
@_spi(DeviceStorage) @testable import Chickinfry
#if canImport(Security)
import Security
#endif

private func launchDeviceProbe(root: URL, app: String, mode: String, origin: String = deviceOrigin) throws -> Process {
    guard ProcessInfo.processInfo.environment["CHICKINFRY_DEVICE_TEST_MODE"] == nil else { throw DeviceProbeFailure.check }
    let process = Process()
    let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG",
                                "LC_ALL", "LC_CTYPE", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS", "SWIFT_EXEC",
                                "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
                                "DYLD_FALLBACK_LIBRARY_PATH"]
    var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
    environment["CHICKINFRY_DEVICE_TEST_ROOT"] = root.path
    environment["CHICKINFRY_DEVICE_TEST_APP"] = app
    environment["CHICKINFRY_DEVICE_TEST_MODE"] = mode
    environment["CHICKINFRY_DEVICE_TEST_ORIGIN"] = origin
    process.environment = environment
    let bundle = Bundle(for: DeviceProcessProbe.self)
    let executable = bundle.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    #if os(macOS)
    let input = try FileHandle(forReadingFrom: executable)
    let header = try input.read(upToCount: MemoryLayout<mach_header_64>.size) ?? Data()
    try input.close()
    let isBundle = header.count == MemoryLayout<mach_header_64>.size && header.withUnsafeBytes {
        $0.loadUnaligned(as: mach_header_64.self).filetype == MH_BUNDLE
    }
    if isBundle {
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "xctest"]
        lookup.environment = environment
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lookup.waitUntilExit()
        guard lookup.terminationStatus == 0, path.hasPrefix("/") else { throw DeviceProbeFailure.check }
        // Starting xcrun would strip the custom toolchain's Swift Testing library paths.
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-XCTest", "ChickinfryTests.DeviceProcessProbe/testLifecycle", bundle.bundlePath]
    } else {
        process.executableURL = executable
        process.arguments = ["--testing-library", "xctest", "ChickinfryTests.DeviceProcessProbe/testLifecycle"]
    }
    #else
    process.executableURL = executable
    process.arguments = ["--testing-library", "xctest", "ChickinfryTests.DeviceProcessProbe/testLifecycle"]
    #endif
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private enum DeviceProbeFailure: Error { case check }
private func probeCheck(_ condition: Bool) throws {
    guard condition else { throw DeviceProbeFailure.check }
}

final class DeviceProcessProbe: XCTestCase, @unchecked Sendable {
    func testLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["CHICKINFRY_DEVICE_TEST_MODE"] {
            let path = try #require(environment["CHICKINFRY_DEVICE_TEST_ROOT"])
            let app = try #require(environment["CHICKINFRY_DEVICE_TEST_APP"])
            try #require(path.hasPrefix("/private/tmp/chickinfry-swift-store-"))
            try #require(app.hasPrefix("store-test-"))
            let root = URL(fileURLWithPath: path)
            if mode == "relative-directory" {
                let after = root.appendingPathComponent("after")
                try FileManager.default.createDirectory(at: after, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                try probeCheck(FileManager.default.changeCurrentDirectoryPath(root.path))
                let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                                   persist: .dir("relative-state"), keychainCalls: nil, protected: false)
                try probeCheck(FileManager.default.changeCurrentDirectoryPath(after.path))
                try await store.save(deviceRecord())
                let fixed = try deviceStore(root.appendingPathComponent("relative-state"), app)
                try probeCheck(try await fixed.load() != nil)
                let other = try deviceStore(after.appendingPathComponent("relative-state"), app)
                try probeCheck(try await other.load() == nil)
                return
            }
            if mode == "file-crash" {
                let files = try DeviceFiles(path: root.appendingPathComponent("file-crash").path)
                try files.locked { try files.write("value", data: Data("after".utf8), beforeRename: { _exit(73) }) }
                throw DeviceProbeFailure.check
            }
            #if canImport(Security)
            if mode == "installation-crash" {
                let calls = FakeKeychainCalls(root: root)
                calls.crashAfterDeletes = 1
                let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                                   persist: .dir(root.path), keychainCalls: calls, protected: true)
                _ = try await store.snapshot()
                throw DeviceProbeFailure.check
            }
            if mode == "keychain-crash" {
                var keychain = try fixtureKeychain(root, app)
                let previous = try keychain.load()
                keychain.beforeUpdate = { _exit(73) }
                try keychain.replace(previous)
                throw DeviceProbeFailure.check
            }
            #endif
            let origin = environment["CHICKINFRY_DEVICE_TEST_ORIGIN"] ?? deviceOrigin
            let store = try DeviceSessionStore(origin: origin, app: app, project: "project", environment: "test",
                                               persist: .dir(root.path), keychainCalls: nil, protected: false)
            switch mode {
            case "seed":
                try await store.save(deviceRecord())
                let formatter = ISO8601DateFormatter()
                let generation = try await store.snapshot().generation
                let attemptSaved1 = try await store.saveAttempt(id: UUID().uuidString, email: "process@example.test", screen: "signup",
                                                    acceptedAt: formatter.string(from: Date().addingTimeInterval(-1)),
                                                    expiresAt: formatter.string(from: Date().addingTimeInterval(3600)),
                                                    ifGeneration: generation)
                try probeCheck(attemptSaved1)
            case "read":
                try probeCheck(try await store.load() != nil)
                try probeCheck(try await store.attempt(screen: "signup") != nil)
            case "refresh":
                let current = try #require(await store.load())
                try probeCheck(try await store.beginRefresh(ifMatching: current))
                try probeCheck(try await store.replace(deviceRecord(), ifMatching: current))
            case "claim":
                let current = try #require(await store.load())
                try probeCheck(try await store.beginRefresh(ifMatching: current))
            case "switch-start":
                let prepared = try await store.snapshot(preparingAuthentication: true)
                try probeCheck(prepared.authenticationSwitchID != nil)
            case "switch-recovered":
                try probeCheck(try await store.load() == nil)
            case "unknown":
                do {
                    _ = try await store.load()
                    throw DeviceProbeFailure.check
                } catch let error as ClientError { try probeCheck(error.code == "unauthenticated") }
            case "recover":
                try probeCheck(try await store.install(deviceRecord(), consumingEmail: nil,
                                                ifGeneration: store.snapshot().generation))
            case "logout":
                try probeCheck(try await store.logout(ifGeneration: store.snapshot().generation))
            case "logout-login":
                try probeCheck(try await store.logout(ifGeneration: store.snapshot().generation))
                try await store.save(deviceRecord(origin: origin))
            case "empty":
                try probeCheck(try await store.load() == nil)
                try probeCheck(try await store.attempt(screen: "signup") == nil)
            case "contend-a", "contend-b":
                let generation = try await store.snapshot().generation
                try Data().write(to: root.appendingPathComponent(mode + "-ready"))
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: root.appendingPathComponent("go").path), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(Date() < deadline)
                let won = try await store.install(deviceRecord(), consumingEmail: nil, ifGeneration: generation)
                try Data((won ? "won" : "lost").utf8).write(to: root.appendingPathComponent(mode + "-result"))
            default: throw DeviceProbeFailure.check
            }
            return
        }
        try await withDeviceFixture { root, app in
            func phase(_ mode: String, status: Int32 = 0) throws {
                let process = try launchDeviceProbe(root: root, app: app, mode: mode)
                process.waitUntilExit()
                try probeCheck(process.terminationStatus == status)
            }
            try phase("seed")
            try phase("relative-directory")
            try phase("read")
            try phase("refresh")
            try phase("read")
            try phase("claim")
            try phase("unknown")
            try phase("recover")
            let files = try DeviceFiles(path: root.appendingPathComponent("file-crash").path)
            try files.locked { try files.write("value", data: Data("before".utf8)) }
            try phase("file-crash", status: 73)
            let previousSurvives = try files.read("value") == Data("before".utf8)
            try probeCheck(previousSurvives)
            let first = try launchDeviceProbe(root: root, app: app, mode: "contend-a")
            let second = try launchDeviceProbe(root: root, app: app, mode: "contend-b")
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let ready = ["contend-a-ready", "contend-b-ready"].allSatisfy {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }
                if ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Data().write(to: root.appendingPathComponent("go"))
            first.waitUntilExit(); second.waitUntilExit()
            try probeCheck(first.terminationStatus == 0 && second.terminationStatus == 0)
            let results = try ["contend-a-result", "contend-b-result"].map {
                String(decoding: try Data(contentsOf: root.appendingPathComponent($0)), as: UTF8.self)
            }
            try probeCheck(results.sorted() == ["lost", "won"])
            try phase("logout")
            try phase("empty")
        }
    }
}
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private let deviceOrigin = "https://device.example.test"

private func deviceRecord(origin: String = deviceOrigin) throws -> SessionRecord {
    func credential() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return try SessionRecord(origin: origin, accessToken: credential(), refreshToken: credential(),
                             expiresAt: "2030-01-01T00:00:00Z", refreshExpiresAt: "2030-01-02T00:00:00Z",
                             userID: UUID().uuidString, sessionID: UUID().uuidString)
}

private func withDeviceFixture(_ body: (URL, String) async throws -> Void) async throws {
    let app = "store-test-" + UUID().uuidString.lowercased()
    let root = URL(fileURLWithPath: "/private/tmp/chickinfry-swift-store-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try await body(root, app)
}

private func deviceStore(_ root: URL, _ app: String, project: String = "project", protected: Bool = false) throws -> DeviceSessionStore {
    try DeviceSessionStore(origin: deviceOrigin, app: app, project: project,
                           environment: "test", persist: .dir(root.path),
                           keychainCalls: protected ? deviceKeychainCalls(root: root) : nil, protected: protected)
}

private func deviceFailure(_ code: String, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected device storage failure") }
    catch let error as ClientError { #expect(error.code == code) }
    catch { Issue.record("Unexpected error type") }
}

private actor RacingConfirmationStore: DeviceAuthenticationStore, DeviceRefreshing {
    nonisolated let origin: String
    nonisolated let coordinator: SessionCoordinator
    let backing: DeviceSessionStore
    private(set) var installs = 0
    private var refreshRaces = 0
    private(set) var replacements = 0
    private var beforeReplace: (@Sendable () throws -> Void)?

    init(_ backing: DeviceSessionStore, refreshRaces: Int = 0, beforeReplace: (@Sendable () throws -> Void)? = nil) {
        self.backing = backing
        origin = backing.origin
        coordinator = backing.coordinator
        self.refreshRaces = refreshRaces
        self.beforeReplace = beforeReplace
    }

    func snapshot() async throws -> DeviceSnapshot { try await backing.snapshot() }
    func recover(_ recovery: DeviceRecovery, observing snapshot: DeviceSnapshot) async throws -> DeviceRecoveryResult {
        return try await backing.recover(recovery, observing: snapshot)
    }
    func snapshot(preparingAuthentication: Bool) async throws -> DeviceSnapshot {
        try await backing.snapshot(preparingAuthentication: preparingAuthentication)
    }
    func rejectAuthentication(_ before: DeviceSnapshot) async throws { try await backing.rejectAuthentication(before) }
    func load() async throws -> SessionRecord? { try await backing.load() }
    func save(_ session: SessionRecord) async throws { try await backing.save(session) }
    func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool {
        replacements += 1
        if let beforeReplace {
            self.beforeReplace = nil
            try beforeReplace()
        }
        if refreshRaces > 0 {
            refreshRaces -= 1
            let current = try await backing.snapshot()
            let formatter = ISO8601DateFormatter()
            _ = try await backing.saveAttempt(id: UUID().uuidString, email: "race@example.test", screen: "racing",
                acceptedAt: formatter.string(from: Date().addingTimeInterval(-1)),
                expiresAt: formatter.string(from: Date().addingTimeInterval(3600)), ifGeneration: current.generation)
        }
        return try await backing.replace(session, ifMatching: expected)
    }
    func beginRefresh(ifMatching expected: SessionRecord, requestID: String) async throws -> Bool {
        try await backing.beginRefresh(ifMatching: expected, requestID: requestID)
    }
    func refreshCandidate(ifMatching expected: SessionRecord) async throws -> SessionRecord? {
        try await backing.refreshCandidate(ifMatching: expected)
    }
    func clear(ifMatching expected: SessionRecord) async throws -> Bool { try await backing.clear(ifMatching: expected) }
    func discardAttempt(_ attempt: DeviceAttempt, ifGeneration: UInt64) async throws -> Bool {
        try await backing.discardAttempt(attempt, ifGeneration: ifGeneration)
    }

    func install(_ session: SessionRecord, consumingEmail: String?, ifGeneration: UInt64,
                 authGeneration: UInt64?) async throws -> Bool {
        installs += 1
        let current = try await backing.snapshot()
        let formatter = ISO8601DateFormatter()
        _ = try await backing.saveAttempt(id: UUID().uuidString, email: "race@example.test", screen: "racing",
                                          acceptedAt: formatter.string(from: Date().addingTimeInterval(-1)),
                                          expiresAt: formatter.string(from: Date().addingTimeInterval(3600)),
                                          ifGeneration: current.generation)
        return try await backing.install(session, consumingEmail: consumingEmail, ifGeneration: ifGeneration,
                                          authGeneration: authGeneration)
    }
}

@Test(arguments: ["same", "different", "logout", "switched", "new-session", "bound"])
func deviceConfirmationRetriesPreserveTheAuthBoundary(kind: String) async throws {
    try await withDeviceFixture { root, app in
        let backing = try deviceStore(root, app)
        if kind == "new-session" { try await backing.save(deviceRecord()) }
        let formatter = ISO8601DateFormatter()
        let accepted = formatter.string(from: Date().addingTimeInterval(-1))
        let expires = formatter.string(from: Date().addingTimeInterval(3600))
        var generation = try await backing.snapshot().generation
        let firstSaved = try await backing.saveAttempt(id: UUID().uuidString, email: "first@example.test", screen: "first",
                                                       acceptedAt: accepted, expiresAt: expires, ifGeneration: generation)
        #expect(firstSaved)
        let before = try await backing.snapshot()
        let attempt = try #require(before.attempts.first { $0.screen == "first" })
        generation = before.generation
        let email = kind == "same" ? "first@example.test" : "second@example.test"
        let secondSaved = try await backing.saveAttempt(id: UUID().uuidString, email: email, screen: "second",
                                                        acceptedAt: accepted, expiresAt: expires, ifGeneration: generation)
        #expect(secondSaved)
        var preserved: SessionRecord?
        if kind == "switched" || kind == "new-session" {
            let fresh = try deviceRecord()
            if kind == "new-session" {
                let user = try #require(before.session).userID
                preserved = try SessionRecord(origin: deviceOrigin, accessToken: fresh.accessToken, refreshToken: fresh.refreshToken,
                                               expiresAt: fresh.expiresAt, refreshExpiresAt: fresh.refreshExpiresAt,
                                               userID: user, sessionID: fresh.sessionID)
            } else { preserved = fresh }
            let current = try await backing.snapshot()
            let changed = try await backing.install(#require(preserved), consumingEmail: nil, ifGeneration: current.generation)
            #expect(changed)
        }
        if kind == "logout" {
            let current = try await backing.snapshot()
            #expect(try await backing.logout(ifGeneration: current.generation))
        }
        let racing = RacingConfirmationStore(backing)
        let store: any SessionStore = kind == "bound" ? racing : backing
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        let session = try deviceRecord()
        let result = try await transport.acceptSession(session, after: before, consuming: attempt)
        let serverResultPreserved = result.sessionID == session.sessionID
        #expect(serverResultPreserved)
        if kind == "logout" {
            #expect(try await backing.load() == nil)
        } else if let preserved {
            let currentPreserved = try await backing.load()?.sessionID == preserved.sessionID
            #expect(currentPreserved)
            #expect(try await backing.attempt(screen: "first") == nil)
            #expect(try await backing.attempt(screen: "second") != nil)
            let current = try await backing.snapshot()
            #expect(try await backing.logout(ifGeneration: current.generation))
            #expect(try await backing.attempt(screen: "second") == nil)
        } else {
            if kind == "bound" {
                #expect(await racing.installs == DeviceLimits.commitAttempts)
                #expect(try await backing.load() == nil)
                let memoryMatches = try await loadSession(store, origin: deviceOrigin)?.sessionID == session.sessionID
                #expect(memoryMatches)
            } else {
                #expect(try await backing.attempt(screen: "first") == nil)
                let remaining = try await backing.attempt(screen: "second")
                #expect((remaining == nil) == (kind == "same"))
            }
        }
    }
}

@Test(arguments: ["logout", "logout-login"])
func deviceVolatileSessionObservesExternalAuthenticationChange(mode: String) async throws {
    try await withDeviceFixture { root, app in
        let server = try LoopbackServer([], responder: { request in
            request.headers["authorization"] == nil
                ? .reply(401, Data("{\"error\":\"unauthenticated\"}".utf8))
                : .reply(200, Data("{\"value\":\"ok\"}".utf8))
        })
        do {
            let backing = try DeviceSessionStore(origin: server.origin, app: app, project: "project", environment: "test",
                                                 persist: .dir(root.path), keychainCalls: nil, protected: false)
            let racing = RacingConfirmationStore(backing)
            let before = try await backing.snapshot()
            let transport = try HTTPTransport(origin: server.origin).withSession(racing)
            _ = try await transport.acceptSession(deviceRecord(origin: server.origin), after: before)
            try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: root.path)
            let activeBeforeChange = try await loadSession(racing, origin: server.origin) != nil
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            #expect(activeBeforeChange)
            let process = try launchDeviceProbe(root: root, app: app, mode: mode, origin: server.origin)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let local = await expectFailure("unauthenticated", status: nil) {
                _ = try await transport.invoke("account.read", input: Empty(), as: Payload.self)
            }
            #expect(local != nil)
            #expect(await server.log.requests.isEmpty)
            if mode == "logout-login" {
                let stored = try #require(await backing.load())
                let output = try await transport.invoke("account.read", input: Empty(), as: Payload.self)
                #expect(output.value == "ok")
                let requests = await server.log.requests
                try #require(requests.count == 1)
                let nextUsedStoredSession = requests[0].headers["authorization"] == "Bearer " + stored.accessToken
                #expect(nextUsedStoredSession)
            }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

@Test(arguments: [0, 1, 3], [false, true])
func deviceRefreshPreservesAnotherScreensAttempt(races: Int, newSession: Bool) async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        try await store.save(deviceRecord())
        let expected = try #require(await store.load())
        let racing = RacingConfirmationStore(store, refreshRaces: races)
        let fresh = try deviceRecord()
        let replacement = try SessionRecord(origin: deviceOrigin, accessToken: fresh.accessToken,
            refreshToken: fresh.refreshToken, expiresAt: fresh.expiresAt,
            refreshExpiresAt: fresh.refreshExpiresAt, userID: expected.userID,
            sessionID: newSession ? fresh.sessionID : expected.sessionID)
        let count = DeviceCount()
        let result = try await store.coordinator.refresh(expected: expected, store: racing) {
            await count.increment()
            let snapshot = try await store.snapshot()
            let formatter = ISO8601DateFormatter()
            let saved = try await store.saveAttempt(id: UUID().uuidString, email: "other@example.test", screen: "other",
                acceptedAt: formatter.string(from: Date().addingTimeInterval(-1)),
                expiresAt: formatter.string(from: Date().addingTimeInterval(3600)), ifGeneration: snapshot.generation)
            #expect(saved)
            return replacement
        }
        let installed = result?.credential == replacement.credential
        #expect(installed)
        if races < DeviceLimits.commitAttempts {
            let persisted = try await store.load()?.credential == replacement.credential
            #expect(persisted)
        } else {
            await deviceFailure("unauthenticated") { _ = try await store.load() }
            let retained = try await loadSession(racing, origin: deviceOrigin)?.credential == replacement.credential
            #expect(retained)
        }
        let generation = try await store.snapshot().localAuthGeneration
        #expect(generation == (expected.deviceAuthGeneration ?? 0) + (newSession ? 1 : 0))
        #expect(try await store.attempt(screen: "other") != nil)
        #expect(await count.value == 1)
        #expect(await racing.replacements == min(races + 1, DeviceLimits.commitAttempts))
    }
}

@Test(arguments: [false, true])
func deviceRefreshNeverOverwritesAnAuthenticationChange(newLogin: Bool) async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        try await store.save(deviceRecord())
        let expected = try #require(await store.load())
        let replacement = try deviceRecord()
        let changed = try deviceRecord()
        let result = try await store.coordinator.refresh(expected: expected, store: store) {
            let snapshot = try await store.snapshot()
            #expect(try await store.logout(ifGeneration: snapshot.generation))
            if newLogin { try await store.save(changed) }
            return replacement
        }
        #expect(result == nil)
        let stored = try await store.load()
        let diskPreservesChange = newLogin ? stored?.credential == changed.credential : stored == nil
        #expect(diskPreservesChange)
    }
}

@Test func deviceLateConfirmationKeepsTheServerResultWithoutInstallingIt() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        let formatter = ISO8601DateFormatter()
        let accepted = formatter.string(from: Date().addingTimeInterval(-1))
        let expires = formatter.string(from: Date().addingTimeInterval(3600))
        var snapshot = try await store.snapshot()
        _ = try await store.saveAttempt(id: UUID().uuidString, email: "first@example.test", screen: "first",
                                        acceptedAt: accepted, expiresAt: expires, ifGeneration: snapshot.generation)
        let beforeFirst = try await store.snapshot()
        let first = try #require(beforeFirst.attempts.first { $0.screen == "first" })
        snapshot = beforeFirst
        _ = try await store.saveAttempt(id: UUID().uuidString, email: "second@example.test", screen: "second",
                                        acceptedAt: accepted, expiresAt: expires, ifGeneration: snapshot.generation)
        let beforeSecond = try await store.snapshot()
        let second = try #require(beforeSecond.attempts.first { $0.screen == "second" })
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        let installed = try deviceRecord()
        _ = try await transport.acceptSession(installed, after: beforeFirst, consuming: first)
        let late = try deviceRecord()
        let result = try await transport.acceptSession(late, after: beforeSecond, consuming: second)
        let resultPreserved = result.sessionID == late.sessionID
        let durablePreserved = try await store.load()?.sessionID == installed.sessionID
        let memoryPreserved = try await loadSession(store, origin: deviceOrigin)?.sessionID == installed.sessionID
        #expect(resultPreserved)
        #expect(durablePreserved)
        #expect(memoryPreserved)
        #expect(try await store.attempt(screen: "second") == nil)
    }
}

@Test func deviceUnknownAccountSwitchNeverRestoresThePreviousSession() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        try await store.save(deviceRecord())
        let started = try launchDeviceProbe(root: root, app: app, mode: "switch-start")
        started.waitUntilExit()
        #expect(started.terminationStatus == 0)
        let recovered = try launchDeviceProbe(root: root, app: app, mode: "switch-recovered")
        recovered.waitUntilExit()
        #expect(recovered.terminationStatus == 0)
    }
}

#if canImport(Security)
@Test(arguments: ["first", "failure", "committed", "memory", "preflight-failure"])
func deviceAccountSwitchProtectsEachSideEffectBoundary(outcome: String) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        let previous = try deviceRecord()
        if outcome != "first" { try await store.save(previous) }
        if outcome == "preflight-failure" { calls.updateFailure = errSecInteractionNotAllowed }
        if outcome == "preflight-failure" {
            await deviceFailure("failed_precondition") { _ = try await store.snapshot(preparingAuthentication: true) }
            calls.updateFailure = nil
            let previousPreserved = try await store.load()?.sessionID == previous.sessionID
            #expect(previousPreserved)
            return
        }
        let before = try await store.snapshot(preparingAuthentication: true)
        #expect((before.authenticationSwitchID == nil) == (outcome == "first"))
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        if outcome == "failure" {
            try await transport.rejectAuthentication(before)
            let previousPreserved = try await store.load()?.sessionID == previous.sessionID
            #expect(previousPreserved)
        } else {
            let response = try deviceRecord()
            if outcome == "memory" { calls.updateFailure = errSecInteractionNotAllowed }
            _ = try await transport.acceptSession(response, after: before)
            let memoryMatches = try await loadSession(store, origin: deviceOrigin)?.sessionID == response.sessionID
            #expect(memoryMatches)
            calls.updateFailure = nil
            if outcome != "memory" {
                let durableMatches = try await store.load()?.sessionID == response.sessionID
                #expect(durableMatches)
            }
        }
    }
}
#endif

@Test(arguments: [false, true])
func deviceEmailConfirmationNeedsNoSignupReference(afterLogout: Bool) async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        let formatter = ISO8601DateFormatter()
        let accepted = formatter.string(from: Date().addingTimeInterval(-1))
        let expires = formatter.string(from: Date().addingTimeInterval(3600))
        let initial = try await store.snapshot()
        _ = try await store.saveAttempt(id: UUID().uuidString, email: "confirmed@example.test", screen: "signup",
                                        acceptedAt: accepted, expiresAt: expires, ifGeneration: initial.generation)
        let before = try await store.snapshot()
        if afterLogout { _ = try await store.logout(ifGeneration: before.generation) }
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        let response = try deviceRecord()
        let output = try await transport.acceptSession(response, after: before, confirmedEmail: "confirmed@example.test")
        let resultPreserved = output.sessionID == response.sessionID
        #expect(resultPreserved)
        #expect((try await store.load() == nil) == afterLogout)
        #expect(try await store.attempt(screen: "signup") == nil)
    }
}

@Test(arguments: [("device_storage_unavailable", "failed_precondition"), ("device_storage_corrupt", "data_loss"),
                  ("device_storage_full", "resource_exhausted"), ("device_storage_version_unsupported", "unimplemented")])
func deviceStorageErrorsKeepTheirCategory(code: String, expected: String) async {
    do {
        let _: Bool = try await sessionStoreCall { throw ClientError(code: code, status: nil) }
        Issue.record("Expected a device storage failure")
    } catch let error as ClientError {
        #expect(error.code == expected)
        #expect(error.status == nil)
    } catch { Issue.record("Unexpected error type") }
}

@Test func deviceDisabledDoesNotOpenTheFilesystem() async throws {
    let store = try DeviceSessionStore(origin: deviceOrigin, app: "disabled", project: "project",
                                       environment: "test", persist: .disabled,
                                       keychainCalls: nil, protected: false)
    let session = try deviceRecord()
    try await store.save(session)
    let sessionMatches1 = try await store.load()?.sessionID == session.sessionID
    #expect(sessionMatches1)
}

@Test func deviceReopenGenerationAndLogout() async throws {
    try await withDeviceFixture { root, app in
        let first = try deviceStore(root, app)
        let session = try deviceRecord()
        try await first.save(session)
        let second = try deviceStore(root, app)
        #expect(first.coordinator === second.coordinator)
        let restored = try #require(await second.load())
        let sessionMatches2 = restored.sessionID == session.sessionID
        #expect(sessionMatches2)
        let captured = try await second.snapshot()
        #expect(try await first.logout(ifGeneration: captured.generation))
        #expect(try await second.install(session, consumingEmail: nil, ifGeneration: captured.generation) == false)
        #expect(try await deviceStore(root, app).load() == nil)
        let other = try deviceStore(root, app, project: "other")
        try await other.save(session)
        #expect(try await first.load() == nil)
        let sessionMatches3 = try await other.load()?.sessionID == session.sessionID
        #expect(sessionMatches3)
    }
}

@Test func deviceAttemptsStayWithTheirScreenAndAreConsumedAtomically() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        let formatter = ISO8601DateFormatter()
        let accepted = formatter.string(from: Date().addingTimeInterval(-3600))
        let expires = formatter.string(from: Date().addingTimeInterval(23 * 3600))
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        var generation = try await store.snapshot().generation
        let attemptSaved2 = try await store.saveAttempt(id: firstID, email: "first@example.test", screen: "first",
                                            acceptedAt: accepted, expiresAt: expires, ifGeneration: generation)
        #expect(attemptSaved2)
        generation = try await store.snapshot().generation
        let attemptSaved3 = try await store.saveAttempt(id: secondID, email: "second@example.test", screen: "second",
                                            acceptedAt: accepted, expiresAt: expires, ifGeneration: generation)
        #expect(attemptSaved3)
        let reopened = try deviceStore(root, app)
        let now = Date().addingTimeInterval(1)
        let firstMatches = try await reopened.attempt(screen: "first", now: now)?.id == firstID
        let secondMatches = try await reopened.attempt(screen: "second", now: now)?.id == secondID
        #expect(firstMatches)
        #expect(secondMatches)
        #expect(try await reopened.attempt(screen: "unknown", now: now) == nil)
        generation = try await reopened.snapshot().generation
        #expect(try await reopened.install(deviceRecord(), consumingEmail: "first@example.test", ifGeneration: generation))
        let last = try deviceStore(root, app)
        #expect(try await last.attempt(screen: "first", now: now) == nil)
        let otherPreserved = try await last.attempt(screen: "second", now: now)?.id == secondID
        #expect(otherPreserved)
        let expired = try #require(ISO8601DateFormatter().date(from: expires))
        #expect(try await last.attempt(screen: "second", now: expired) == nil)
    }
}

@Test func deviceRefreshClaimSurvivesReopeningAndCannotBeClaimedTwice() async throws {
    try await withDeviceFixture { root, app in
        let first = try deviceStore(root, app)
        try await first.save(deviceRecord())
        let expected = try #require(await first.load())
        #expect(try await first.beginRefresh(ifMatching: expected))
        let second = try deviceStore(root, app)
        #expect(try await second.beginRefresh(ifMatching: expected) == false)
        await deviceFailure("unauthenticated") { _ = try await second.load() }
        let replacement = try deviceRecord()
        #expect(try await first.replace(replacement, ifMatching: expected))
        let sessionMatches4 = try await second.load()?.sessionID == replacement.sessionID
        #expect(sessionMatches4)
    }
}

@Test func deviceLocationFailureDoesNotBecomeMemoryStorage() async throws {
    await deviceFailure("failed_precondition") {
        _ = try DeviceSessionStore(origin: deviceOrigin, app: "unavailable", project: "project",
                                          environment: "test", persist: .dir(""),
                                          keychainCalls: nil, protected: false)
    }
}

@Test func deviceAttemptsRespectCapacityAndDoNotExtendTheirLifetime() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app)
        let formatter = ISO8601DateFormatter()
        let accepted = formatter.string(from: Date().addingTimeInterval(-3600))
        let expires = formatter.string(from: Date().addingTimeInterval(48 * 3600))
        for screen in ["one", "two", "three"] {
            let generation = try await store.snapshot().generation
            let attemptSaved4 = try await store.saveAttempt(id: UUID().uuidString, email: screen + "@example.test", screen: screen,
                                                acceptedAt: accepted, expiresAt: expires, ifGeneration: generation)
            #expect(attemptSaved4)
        }
        let generation = try await store.snapshot().generation
        await deviceFailure("resource_exhausted") {
            _ = try await store.saveAttempt(id: UUID().uuidString, email: "four@example.test", screen: "four",
                                            acceptedAt: accepted, expiresAt: expires, ifGeneration: generation)
        }
        #expect(try await store.snapshot().generation == generation)
        let limit = try #require(formatter.date(from: accepted)).addingTimeInterval(24 * 3600)
        #expect(try await store.attempt(screen: "one", now: limit) == nil)
        #expect(try await deviceStore(root, app).attempt(screen: "one", now: limit.addingTimeInterval(-1)) == nil)
    }
}

@Test func deviceFileReplacementAndPermissions() async throws {
    try await withDeviceFixture { root, _ in
        let files = try DeviceFiles(path: root.appendingPathComponent("files").path)
        let original = Data("original non-secret value".utf8)
        try files.locked { try files.write("value", data: original) }
        let attributes = try FileManager.default.attributesOfItem(atPath: files.url.appendingPathComponent("value").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        do {
            try files.locked {
                try files.write("value", data: Data("replacement".utf8), beforeRename: { throw deviceError() })
            }
            Issue.record("Expected interruption")
        }
        catch is ClientError {}
        let unchanged = try files.read("value") == original
        #expect(unchanged)
        let replacement = Data("replacement".utf8)
        var synchronized = false
        try files.locked {
            try files.write("value", data: replacement, syncDirectory: { directory in
                #expect(directory == files.descriptor)
                #expect((try? files.read("value")) == replacement)
                synchronized = true
                return fsync(directory)
            })
        }
        #expect(synchronized)
        let unconfirmed = Data("unconfirmed replacement".utf8)
        await deviceFailure("failed_precondition") {
            try files.locked {
                try files.write("value", data: unconfirmed, syncDirectory: { directory in
                    #expect(directory == files.descriptor)
                    #expect((try? files.read("value")) == unconfirmed)
                    errno = EIO
                    return -1
                })
            }
        }
        let oversized = Data(repeating: 0, count: DeviceLimits.bundleBytes + 1)
        await deviceFailure("resource_exhausted") { try files.write("value", data: oversized) }
    }
}

@Test func deviceDirectoryChecksTheSelectedBaseWithoutChangingItsPermissions() async throws {
    try await withDeviceFixture { root, app in
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let store = try deviceStore(root, app)
        try await store.save(deviceRecord())
        let properties = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((properties[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        let state = try #require(FileManager.default.subpathsOfDirectory(atPath: root.path)
            .first { $0.hasSuffix("/state") })
        let leaf = root.appendingPathComponent(state).deletingLastPathComponent()
        for permissions in [0o755, 0o777] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: leaf.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leaf.path) }
            do {
                _ = try deviceStore(root, app)
                Issue.record("Expected rejection of an unsafe internal directory")
            } catch let error as ClientError {
                #expect(error.code == "failed_precondition")
                #expect(error.description == "Could not use device storage for the session. Check that the storage location is writable, or set persist to another directory or turn it off.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        await deviceFailure("failed_precondition") { _ = try deviceStore(root, app) }
    }
}

@Test func deviceTransportRefreshCommitsTheWholeSession() async throws {
    try await withDeviceFixture { root, app in
        let old = try deviceRecord()
        let fresh = try deviceRecord()
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": fresh.accessToken, "refresh_token": fresh.refreshToken,
            "expires_at": fresh.expiresAt, "refresh_expires_at": fresh.refreshExpiresAt,
            "user_id": fresh.userID, "session_id": fresh.sessionID,
        ])
        let server = try LoopbackServer([], responder: { request in
            if request.path == "/auth.refresh" { return .reply(200, response) }
            if request.headers["authorization"] == "Bearer " + old.accessToken {
                return .reply(401, Data("{\"error\":\"invalid_token\"}".utf8))
            }
            return .reply(200, Data("{\"value\":\"ok\"}".utf8))
        })
        do {
            let store = try DeviceSessionStore(origin: server.origin, app: app, project: "project", environment: "test",
                                               persist: .dir(root.path), keychainCalls: nil, protected: false)
            let bound = try SessionRecord(origin: server.origin, accessToken: old.accessToken, refreshToken: old.refreshToken,
                                          expiresAt: old.expiresAt, refreshExpiresAt: old.refreshExpiresAt,
                                          userID: old.userID, sessionID: old.sessionID)
            try await store.save(bound)
            let transport = try HTTPTransport(origin: server.origin).withSession(store)
            let output = try await transport.invoke("account.read", input: Empty(), as: Payload.self)
            #expect(output.value == "ok")
            let reopened = try DeviceSessionStore(origin: server.origin, app: app, project: "project", environment: "test",
                                                  persist: .dir(root.path), keychainCalls: nil, protected: false)
            let sessionMatches5 = try await reopened.load()?.sessionID == fresh.sessionID
            #expect(sessionMatches5)
            let paths = await server.log.requests.map(\.path)
            #expect(paths == ["/account.read", "/auth.refresh", "/account.read"])
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

@Test func deviceRejectsUnsafeLocationsAndSymbolicLinks() async throws {
    for path in ["/private/tmp"] {
        await deviceFailure("failed_precondition") {
            let store = try DeviceSessionStore(origin: deviceOrigin, app: "unsafe", project: "project",
                                           environment: "test", persist: .dir(path),
                                           keychainCalls: nil, protected: false)
            _ = try await store.load()
        }
    }
    try await withDeviceFixture { root, app in
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        await deviceFailure("failed_precondition") {
            let store = try deviceStore(linked, app)
            _ = try await store.load()
        }
    }
}

#if canImport(Security)
private func installationMarker(_ root: URL, _ app: String) -> URL {
    root.appendingPathComponent(app).appendingPathComponent("installation")
}

@Test func deviceReinstallRecoveryClearsOnlyTheOwnedApp() async throws {
    try await withDeviceFixture { root, app in
        let first = try deviceStore(root, app, protected: true)
        try await first.save(deviceRecord())
        let second = try deviceStore(root, app, project: "second", protected: true)
        try await second.save(deviceRecord())
        let otherApp = app + "-other"
        let sibling = try deviceStore(root, otherApp, protected: true)
        try await sibling.save(deviceRecord())
        try FileManager.default.removeItem(at: installationMarker(root, app))
        let process = try launchDeviceProbe(root: root, app: app, mode: "installation-crash")
        process.waitUntilExit()
        #expect(process.terminationStatus == 73)
        let markerData = try Data(contentsOf: installationMarker(root, app))
        let marker = try #require(JSONSerialization.jsonObject(with: markerData) as? [String: Any])
        #expect(marker["phase"] as? String == "pending")
        let fresh = try deviceStore(root, app, protected: true)
        #expect(try await fresh.load() == nil)
        #expect(try await deviceStore(root, app, project: "second", protected: true).load() == nil)
        #expect(try await sibling.load() != nil)
        #expect(try await fresh.attempt(screen: "signup") == nil)
        let values = try installationMarker(root, app).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

@Test func deviceFirstAdoptionDoesNotRestoreAnUnboundInstallation() async throws {
    try await withDeviceFixture { root, app in
        let old = try deviceStore(root, app, protected: true)
        try await old.save(deviceRecord())
        let keychain = try fixtureKeychain(root, app)
        guard var object = try JSONSerialization.jsonObject(with: keychain.load()) as? [String: Any] else {
            throw deviceError("device_storage_corrupt")
        }
        object.removeValue(forKey: "installation")
        try keychain.replace(JSONSerialization.data(withJSONObject: object))
        try FileManager.default.removeItem(at: installationMarker(root, app))
        #expect(try await deviceStore(root, app, protected: true).load() == nil)
    }
}

@Test func devicePendingReinstallFailureCannotUseTheSuccessFallback() async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let old = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                         persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await old.save(deviceRecord())
        let before = try await old.snapshot()
        try FileManager.default.removeItem(at: installationMarker(root, app))
        calls.deleteFailure = errSecInteractionNotAllowed
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(old)
        await deviceFailure("failed_precondition") {
            _ = try await transport.acceptSession(deviceRecord(), after: before)
        }
        await deviceFailure("failed_precondition") { _ = try await loadSession(old, origin: deviceOrigin) }
        calls.deleteFailure = nil
        #expect(try await deviceStore(root, app, protected: true).load() == nil)
    }
}

@Test(arguments: ["corrupt", "version"])
func deviceInstallMarkerFailurePreservesOwnedCredentials(kind: String) async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: true)
        try await store.save(deviceRecord())
        let keychain = try fixtureKeychain(root, app)
        let original = try keychain.load()
        let markerURL = installationMarker(root, app)
        var damaged = Data("{".utf8)
        if kind == "version" {
            guard var marker = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any] else {
                throw deviceError("device_storage_corrupt")
            }
            marker["version"] = 2
            damaged = try JSONSerialization.data(withJSONObject: marker)
        }
        try damaged.write(to: markerURL)
        let code = kind == "version" ? "unimplemented" : "data_loss"
        await deviceFailure(code) { _ = try await store.load() }
        let credentialsPreserved = try keychain.load() == original
        let markerPreserved = try Data(contentsOf: markerURL) == damaged
        #expect(credentialsPreserved)
        #expect(markerPreserved)
    }
}

private actor DeviceCount {
    var value = 0
    func increment() { value += 1 }
}

@Test(arguments: [false, true])
func deviceServerSuccessKeepsOnlyThisRunMemoryAfterWriteFailure(postCommitReadFailure: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let before = try await store.snapshot()
        let generation = before.generation
        let signedIn = try deviceRecord()
        if postCommitReadFailure {
            calls.failReadsAfterUpdate = true
        } else {
            calls.updateFailure = errSecInteractionNotAllowed
            await deviceFailure("failed_precondition") {
                _ = try await store.install(signedIn, consumingEmail: nil, ifGeneration: generation)
            }
        }
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        let accepted = try await transport.acceptSession(signedIn, after: before)
        let sessionMatches6 = accepted.sessionID == signedIn.sessionID
        #expect(sessionMatches6)
        let sessionMatches7 = try await loadSession(store, origin: deviceOrigin)?.sessionID == signedIn.sessionID
        #expect(sessionMatches7)
        calls.failure = errSecInteractionNotAllowed
        let memorySurvivesIOFailure = try await loadSession(store, origin: deviceOrigin)?.sessionID == signedIn.sessionID
        #expect(memorySurvivesIOFailure)
        calls.failure = nil
        calls.failReadsAfterUpdate = false
        let memorySurvivesOwnCommit = try await loadSession(store, origin: deviceOrigin)?.sessionID == signedIn.sessionID
        #expect(memorySurvivesOwnCommit)
        let sessionMatches8 = try await store.load()?.sessionID == signedIn.sessionID
        #expect(sessionMatches8 == postCommitReadFailure)
        calls.updateFailure = nil
        let current = try await store.snapshot()
        #expect(try await store.logout(ifGeneration: current.generation))
        #expect(try await loadSession(store, origin: deviceOrigin) == nil)
    }
}

@Test(arguments: [false, true])
func deviceRefreshFailureHonorsThePreSendBoundary(afterServerSuccess: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let expected = try #require(await store.load())
        let replacement = try deviceRecord()
        let count = DeviceCount()
        if !afterServerSuccess { calls.updateFailure = errSecInteractionNotAllowed }
        do {
            let result = try await store.coordinator.refresh(expected: expected, store: store) {
                await count.increment()
                calls.updateFailure = errSecInteractionNotAllowed
                return replacement
            }
            #expect(afterServerSuccess)
            let sessionMatches9 = result?.sessionID == replacement.sessionID
            #expect(sessionMatches9)
            #expect(await count.value == 1)
            await deviceFailure("unauthenticated") { _ = try await store.load() }
        } catch let error as ClientError {
            #expect(!afterServerSuccess)
            #expect(error.code == "failed_precondition")
            #expect(await count.value == 0)
        }
    }
}

private func fixtureKeychain(_ root: URL, _ app: String) throws -> DeviceKeychain {
    let names = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let identityURL = try #require(names.compactMap { $0 as? URL }.first { $0.lastPathComponent == "identity" })
    let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: Any])
    let installation = try #require(metadata["installation"] as? String)
    return DeviceKeychain(service: "com.chickinfry.device." + app,
                           account: [installation, "project", "test", deviceOrigin].joined(separator: "/"),
                           calls: deviceKeychainCalls(root: root))
}

@Test(arguments: ["corrupt", "version", "owner", "missing"], [false, true])
func deviceDamagedStateIsPreservedAndBlocked(kind: String, protected: Bool) async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: protected)
        try await store.save(deviceRecord())
        let before = try await store.snapshot()
        let keychain = protected ? try fixtureKeychain(root, app) : nil
        let names = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let stateURL = names.compactMap { $0 as? URL }.first { $0.lastPathComponent == "state" }
        func readStored() throws -> Data {
            if let keychain { return try keychain.load() }
            return try Data(contentsOf: #require(stateURL))
        }
        func replaceStored(_ value: Data) throws {
            if let keychain { try keychain.replace(value) }
            else { try value.write(to: #require(stateURL)) }
        }
        let original = try readStored()
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var damaged = Data("{".utf8)
        if kind == "version" { object["version"] = 2; damaged = try JSONSerialization.data(withJSONObject: object) }
        if kind == "owner" {
            var scope = try #require(object["scope"] as? [String: Any])
            scope["project"] = "other"
            object["scope"] = scope
            damaged = try JSONSerialization.data(withJSONObject: object)
        }
        if kind == "missing" {
            if let keychain { try FakeKeychainCalls(root: root).remove(service: keychain.service, account: keychain.account) }
            else { try FileManager.default.removeItem(at: #require(stateURL)) }
        } else { try replaceStored(damaged) }
        let code = kind == "version" ? "unimplemented" : "data_loss"
        await deviceFailure(code) { _ = try await store.load() }
        await deviceFailure(code) { try await store.save(deviceRecord()) }
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        await deviceFailure(code) { _ = try await transport.acceptSession(deviceRecord(), after: before) }
        if kind != "missing" {
            let unchanged = try readStored() == damaged
            #expect(unchanged)
        }
    }
}

@Test func deviceKeychainUsesTheAppGroupWhenTheDefaultIsShared() async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        calls.defaultGroup = "TEAMID0000.shared"
        let shared = DeviceKeychain(service: "com.chickinfry.device." + app, account: "shared-unrelated",
                                    accessGroup: calls.defaultGroup, calls: calls)
        let sentinel = Data("unrelated".utf8)
        try shared.create(sentinel)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let owned = try fixtureKeychain(root, app)
        let sameAccount = DeviceKeychain(service: owned.service, account: owned.account,
                                         accessGroup: calls.defaultGroup, calls: calls)
        try sameAccount.create(sentinel)
        let before = try await store.snapshot()
        let replacement = try deviceRecord()
        #expect(try await store.install(replacement, consumingEmail: nil, ifGeneration: before.generation))
        let installed = try await store.load()?.credential == replacement.credential
        #expect(installed)
        try FileManager.default.removeItem(at: installationMarker(root, app))
        let reinstalled = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                                 persist: .dir(root.path), keychainCalls: calls, protected: true)
        #expect(try await reinstalled.load() == nil)
        let sharedPreserved = try shared.load() == sentinel
        let sameAccountPreserved = try sameAccount.load() == sentinel
        #expect(sharedPreserved && sameAccountPreserved)
        #expect(try owned.loadIfPresent() == nil)
        #expect(calls.probeAdds == 2 && calls.probeDeletes == 2)
    }
}

@Test(arguments: ["bundle", "prefix", "attributes", "permission", "discovery", "cleanup"])
func deviceKeychainGroupConfirmationFailsBeforeAuthenticationStorage(kind: String) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        switch kind {
        case "bundle": calls.bundleIdentifier = nil
        case "prefix": calls.defaultGroup = "group.shared"
        case "attributes": calls.missingProbeAttributes = true
        case "permission":
            calls.defaultGroup = "TEAMID0000.shared"
            calls.deniedGroup = "TEAMID0000.com.example.host"
        case "discovery": calls.failure = errSecInteractionNotAllowed
        case "cleanup": calls.deleteFailure = errSecInteractionNotAllowed
        default: Issue.record("Unknown group confirmation failure")
        }
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        await deviceFailure("failed_precondition") { _ = try await store.snapshot() }
        #expect(calls.authenticationGroups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installationMarker(root, app).path))
        if kind != "bundle" { #expect(calls.probeDeletes > 0) }
    }
}

@Test func deviceKeychainDenialCannotFallBackToAFile() async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        calls.failure = errSecInteractionNotAllowed
        let keychain = DeviceKeychain(service: "com.chickinfry.device." + app,
                                       account: UUID().uuidString, calls: calls)
        await deviceFailure("failed_precondition") { try keychain.create(Data("non-secret".utf8)) }
    }
}

private func rejoinRecord(matching session: SessionRecord) throws -> SessionRecord {
    let fresh = try deviceRecord()
    return try SessionRecord(origin: session.origin, accessToken: fresh.accessToken, refreshToken: fresh.refreshToken,
                             expiresAt: fresh.expiresAt, refreshExpiresAt: fresh.refreshExpiresAt,
                             userID: session.userID, sessionID: session.sessionID)
}

private func rejoinPeer(_ root: URL, _ app: String, _ change: (inout DeviceState) throws -> Void) throws {
    let keychain = try fixtureKeychain(root, app)
    var state = try JSONDecoder().decode(DeviceState.self, from: keychain.load())
    try change(&state)
    try state.advance()
    try keychain.replace(state.encoded())
}

private func rejoinAttempt(screen: String, sequence: UInt64 = 1) -> DeviceAttempt {
    let formatter = ISO8601DateFormatter()
    return DeviceAttempt(id: UUID().uuidString, email: screen + "@example.test", screen: screen,
                         acceptedAt: formatter.string(from: Date().addingTimeInterval(-1)),
                         expiresAt: formatter.string(from: Date().addingTimeInterval(3600)), sequence: sequence)
}

private func rejoinRefreshMarker(_ root: URL, _ app: String, id: String?) throws {
    let keychain = try fixtureKeychain(root, app)
    var state = try #require(JSONSerialization.jsonObject(with: keychain.load()) as? [String: Any])
    state["refreshRequestID"] = id
    try keychain.replace(JSONSerialization.data(withJSONObject: state))
}

@Test(arguments: ["own", "peer", "legacy"])
func deviceRejoinRefreshMarkerIdentity(kind: String) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let original = try #require(await store.load())
        let replacement = try rejoinRecord(matching: original)
        _ = try await store.coordinator.refresh(expected: original, store: store) {
            calls.updateFailure = errSecInteractionNotAllowed
            return replacement
        }
        let keychain = try fixtureKeychain(root, app)
        let claim = try #require(JSONSerialization.jsonObject(with: keychain.load()) as? [String: Any])
        let ownID = claim["refreshRequestID"] as? String
        #expect(ownID.flatMap(UUID.init(uuidString:)) != nil)
        calls.updateFailure = nil
        let peerID = kind == "peer" ? UUID().uuidString : nil
        if kind != "own" { try rejoinRefreshMarker(root, app, id: peerID) }
        if kind == "own" {
            let recovered = try await loadSession(store, origin: deviceOrigin)
            #expect({ recovered?.credential == replacement.credential }())
        } else {
            do { #expect(try await loadSession(store, origin: deviceOrigin) == nil) }
            catch let error as ClientError { #expect(error.code == "unauthenticated") }
        }
        let result = try #require(JSONSerialization.jsonObject(with: keychain.load()) as? [String: Any])
        #expect({ (result["refreshUncertain"] as? Bool) == (kind != "own") }())
        #expect({ (result["refreshRequestID"] as? String) == peerID }())
    }
}

@Test func deviceRejoinMarkerRoundTripAndPreChangeDecode() async throws {
    let fixture = Data("""
        {"version":1,"scope":{"origin":"https://device.example.test","app":"fixture","project":"project","environment":"test"},"installation":"11111111-1111-4111-8111-111111111111","generation":0,"authGeneration":0,"authenticationSwitches":[],"attempts":[],"refreshUncertain":false,"observedAt":0}
        """.utf8)
    let old = try JSONDecoder().decode(DeviceState.self, from: fixture)
    #expect({ old.session == nil && old.attempts.isEmpty && old.authGeneration == 0 }())
    _ = try old.encoded()
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: true)
        try await store.save(deviceRecord())
        let session = try #require(await store.load())
        #expect(try await store.beginRefresh(ifMatching: session))
        let keychain = try fixtureKeychain(root, app)
        let bytes = try keychain.load()
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let id = original["refreshRequestID"] as? String
        #expect(id.flatMap(UUID.init(uuidString:)) != nil)
        let decoded = try JSONDecoder().decode(DeviceState.self, from: bytes)
        let encoded = try #require(JSONSerialization.jsonObject(with: decoded.encoded()) as? [String: Any])
        #expect((encoded["refreshRequestID"] as? String) == id)
        let reopened = try deviceStore(root, app, protected: true)
        await deviceFailure("unauthenticated") { _ = try await reopened.load() }
    }
}

@Test func deviceRejoinRefreshCommitCannotClearAReplacedPeerMarker() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: true)
        try await store.save(deviceRecord())
        let original = try #require(await store.load())
        let replacement = try rejoinRecord(matching: original)
        let peerID = UUID().uuidString
        let racing = RacingConfirmationStore(store, beforeReplace: { try rejoinRefreshMarker(root, app, id: peerID) })
        do { #expect(try await store.coordinator.refresh(expected: original, store: racing) { replacement } == nil) }
        catch let error as ClientError { #expect(error.code == "failed_precondition") }
        let raw = try #require(JSONSerialization.jsonObject(with: fixtureKeychain(root, app).load()) as? [String: Any])
        #expect({ raw["refreshUncertain"] as? Bool == true }())
        #expect({ raw["refreshRequestID"] as? String == peerID }())
    }
}

@Test(arguments: [false, true])
func deviceRejoinRejectsInvalidRefreshMarkersWithoutChangingStorage(active: Bool) async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: true)
        try await store.save(deviceRecord())
        let keychain = try fixtureKeychain(root, app)
        var state = try #require(JSONSerialization.jsonObject(with: keychain.load()) as? [String: Any])
        state["refreshUncertain"] = active
        state["refreshRequestID"] = active ? "not-a-uuid" : UUID().uuidString
        let damaged = try JSONSerialization.data(withJSONObject: state)
        try keychain.replace(damaged)
        await deviceFailure("data_loss") { _ = try await store.load() }
        let preserved = try keychain.load() == damaged
        #expect(preserved)
    }
}

@Test(arguments: [false, true])
func deviceRejoinPersistsOwnRefreshAndPreservesPeerAttemptDeletion(delete: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let original = rejoinAttempt(screen: "original")
        try rejoinPeer(root, app) { $0.attempts = [original] }
        let expected = try #require(await store.load())
        let replacement = try rejoinRecord(matching: expected)
        let count = DeviceCount()
        _ = try await store.coordinator.refresh(expected: expected, store: store) {
            await count.increment()
            calls.updateFailure = errSecInteractionNotAllowed
            return replacement
        }
        calls.updateFailure = nil
        let peer = rejoinAttempt(screen: "peer", sequence: 20)
        try rejoinPeer(root, app) {
            if delete { $0.attempts = [] }
            $0.attempts.append(peer)
        }
        let result = try await loadSession(store, origin: deviceOrigin)
        #expect({ result?.credential == replacement.credential }())
        let persisted = try await store.load()
        #expect({ persisted?.credential == replacement.credential }())
        let snapshot = try await store.snapshot()
        #expect(Set(snapshot.attempts.map(\.id)) == Set(delete ? [peer.id] : [original.id, peer.id]))
        #expect(await count.value == 1)
    }
}

@Test(arguments: ["pending", "unknown", "rotated", "postcommit-rotated", "marker-rotated"])
func deviceRejoinNeverUsesMemoryOverPeerAuthentication(kind: String) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let original = try #require(await store.load())
        if kind == "marker-rotated" {
            try rejoinPeer(root, app) {
                $0.refreshUncertain = true
                $0.refreshRequestID = UUID().uuidString
            }
        }
        let before = try await store.snapshot()
        let memory = try rejoinRecord(matching: original)
        calls.failAfterUpdating = kind == "postcommit-rotated"
        if !calls.failAfterUpdating { calls.updateFailure = errSecInteractionNotAllowed }
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        _ = try await transport.acceptSession(memory, after: before)
        calls.failAfterUpdating = false
        calls.updateFailure = nil
        let peer = try rejoinRecord(matching: original)
        let peerMarker = UUID().uuidString
        try rejoinPeer(root, app) {
            if kind == "marker-rotated" { $0.refreshRequestID = peerMarker }
            else if kind == "pending" || kind == "marker-rotated" { $0.refreshUncertain = true }
            else if kind == "unknown" {
                $0.authenticationSwitches.append(.init(id: UUID().uuidString, generation: $0.authGeneration))
            } else { $0.session = StoredSession(peer) }
        }
        if kind == "pending" || kind == "marker-rotated" {
            await deviceFailure("unauthenticated") { _ = try await loadSession(store, origin: deviceOrigin) }
        } else {
            let result = try await loadSession(store, origin: deviceOrigin)
            if kind == "unknown" { #expect(result == nil) }
            else { #expect({ result?.credential == peer.credential }()) }
        }
        let raw = try JSONDecoder().decode(DeviceState.self, from: fixtureKeychain(root, app).load())
        if kind == "pending" || kind == "marker-rotated" { #expect({ raw.refreshUncertain }()) }
        if kind == "marker-rotated" {
            #expect({ raw.refreshRequestID == peerMarker }())
            #expect({ raw.session?.accessToken == original.accessToken }())
        } else if kind.contains("rotated") { #expect({ raw.session?.accessToken == peer.accessToken }()) }
    }
}

@Test(arguments: [false, true])
func deviceRejoinOwnRefreshPreservesPeerPendingAndItsBlock(authChanged: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let original = try #require(await store.load())
        let replacement = try rejoinRecord(matching: original)
        _ = try await store.coordinator.refresh(expected: original, store: store) {
            calls.updateFailure = errSecInteractionNotAllowed
            return replacement
        }
        calls.updateFailure = nil
        let pending = UUID().uuidString
        try rejoinPeer(root, app) { $0.authenticationSwitches.append(.init(id: pending, generation: $0.authGeneration)) }
        let result = try await loadSession(store, origin: deviceOrigin)
        #expect(result == nil)
        let raw = try JSONDecoder().decode(DeviceState.self, from: fixtureKeychain(root, app).load())
        #expect({ raw.session?.accessToken == original.accessToken }())
        #expect({ raw.refreshUncertain }())
        #expect(raw.authenticationSwitches.map(\.id) == [pending])
        let stillBlocked = try await loadSession(store, origin: deviceOrigin)
        #expect(stillBlocked == nil)
        let stored = try fixtureKeychain(root, app).load()
        #expect(try await store.load() == nil)
        #expect(try await store.snapshot().session == nil)
        #expect(try fixtureKeychain(root, app).load() == stored)
        calls.failure = errSecInteractionNotAllowed
        #expect(try await loadSession(store, origin: deviceOrigin) == nil)
        calls.failure = nil
        try rejoinPeer(root, app) {
            $0.authenticationSwitches = []
            if authChanged {
                try $0.advanceAuthentication()
                $0.session = nil
                $0.refreshUncertain = false
                $0.refreshRequestID = nil
            }
        }
        let afterPeerCompleted = try await loadSession(store, origin: deviceOrigin)
        if authChanged { #expect(afterPeerCompleted == nil) }
        else { #expect({ afterPeerCompleted?.credential == replacement.credential }()) }
    }
}

@Test func deviceRejoinDoesNotSettleAnAppliedCandidateWithItsAuthenticationMark() async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let before = try await store.snapshot(preparingAuthentication: true)
        let signedIn = try deviceRecord()
        calls.updateFailure = errSecInteractionNotAllowed
        _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(signedIn, after: before)
        calls.updateFailure = nil
        try rejoinPeer(root, app) {
            $0.session = StoredSession(signedIn)
            $0.authGeneration = before.authGeneration + 1
        }
        let stored = try fixtureKeychain(root, app).load()
        #expect(try await loadSession(store, origin: deviceOrigin) == nil)
        #expect(try fixtureKeychain(root, app).load() == stored)
        try rejoinPeer(root, app) { $0.authenticationSwitches = [] }
        let settled = try await loadSession(store, origin: deviceOrigin)
        #expect({ settled?.credential == signedIn.credential }())
        #expect(try await store.snapshot().authGeneration == before.authGeneration + 1)
    }
}

@Test(arguments: [false, true])
func deviceRejoinRecognizesAppliedAuthenticationAndKeepsPeerAttempts(peerChanged: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let before = try await store.snapshot()
        let signedIn = try deviceRecord()
        calls.failAfterUpdating = true
        _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(signedIn, after: before)
        calls.failAfterUpdating = false
        let peer = rejoinAttempt(screen: "peer")
        if peerChanged { try rejoinPeer(root, app) { $0.attempts.append(peer) } }
        let restored = try await loadSession(store, origin: deviceOrigin)
        #expect({ restored?.credential == signedIn.credential }())
        if peerChanged { #expect(try await store.attempt(screen: "peer")?.id == peer.id) }
        let latest = try await store.snapshot()
        let late = try deviceRecord()
        _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(late, after: before)
        let current = try await loadSession(store, origin: deviceOrigin)
        #expect({ current?.credential == signedIn.credential }())
        #expect(try await store.snapshot().authGeneration == latest.authGeneration)
    }
}

@Test(arguments: [false, true])
func deviceRejoinAuthenticationPersistsConsumptionWithoutResurrectingPeerDeletes(peerRotated: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let consumed = rejoinAttempt(screen: "consumed")
        let deleted = rejoinAttempt(screen: "deleted")
        _ = try await store.snapshot()
        try rejoinPeer(root, app) { $0.attempts = [consumed, deleted] }
        let before = try await store.snapshot()
        let session = try deviceRecord()
        calls.updateFailure = errSecInteractionNotAllowed
        _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(session, after: before, consuming: consumed)
        calls.updateFailure = nil
        let peer = rejoinAttempt(screen: "peer", sequence: 20)
        let peerSession = try rejoinRecord(matching: #require(before.session))
        try rejoinPeer(root, app) {
            $0.attempts = [consumed, peer]
            if peerRotated { $0.session = StoredSession(peerSession) }
        }
        let expected = peerRotated ? peerSession : session
        if peerRotated {
            calls.updateFailure = errSecInteractionNotAllowed
            #expect(try await loadSession(store, origin: deviceOrigin) == nil)
            calls.updateFailure = nil
        }
        let result = try await loadSession(store, origin: deviceOrigin)
        #expect({ result?.credential == expected.credential }())
        let restored = try await store.load()
        #expect({ restored?.credential == expected.credential }())
        #expect(try await store.snapshot().attempts.map(\.id) == [peer.id])
        if !peerRotated {
            let late = try deviceRecord()
            _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(late, after: before)
            let afterLateReply = try await store.load()
            #expect({ afterLateReply?.credential == session.credential }())
        }
    }
}

@Test(arguments: [false, true])
func deviceRejoinRecognizesItsLatestVolatileRefreshAfterAnUncertainRecoveryWrite(newSession: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let before = try await store.snapshot()
        let signedIn = try deviceRecord()
        calls.updateFailure = errSecInteractionNotAllowed
        _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(signedIn, after: before)
        let memory = try #require(await loadSession(store, origin: deviceOrigin))
        let beforeRefresh = try await store.snapshot()
        let refreshed = try newSession ? deviceRecord() : rejoinRecord(matching: memory)
        let count = DeviceCount()
        _ = try await store.coordinator.refresh(expected: memory, store: store) {
            await count.increment()
            return refreshed
        }
        let afterRefresh = try await store.snapshot()
        #expect(afterRefresh.authGeneration == beforeRefresh.authGeneration + (newSession ? 1 : 0))
        if newSession {
            _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(deviceRecord(), after: beforeRefresh)
            let afterLateMemoryReply = try await loadSession(store, origin: deviceOrigin)
            #expect({ afterLateMemoryReply?.credential == refreshed.credential }())
        }
        calls.updateFailure = nil
        calls.failAfterUpdating = true
        let uncertain = try await loadSession(store, origin: deviceOrigin)
        #expect({ uncertain?.credential == refreshed.credential }())
        calls.failAfterUpdating = false
        let settled = try await loadSession(store, origin: deviceOrigin)
        #expect({ settled?.credential == refreshed.credential }())
        if newSession {
            _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(deviceRecord(), after: beforeRefresh)
            let afterLateReply = try await loadSession(store, origin: deviceOrigin)
            #expect({ afterLateReply?.credential == refreshed.credential }())
        }
        #expect(await count.value == 1)
        print("Keychain protocol fake calls: \(calls.callCount); real Keychain calls: 0 (protocol fake only)")
    }
}

@Test(arguments: [false, true])
func deviceRejoinPreservesEarlierAppliedGenerationAfterVolatileRefresh(peerChanged: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let before = try await store.snapshot()
        #expect(before.authGeneration == 1)
        let signedIn = try deviceRecord()
        calls.failAfterUpdating = true
        _ = try await HTTPTransport(origin: deviceOrigin).withSession(store).acceptSession(signedIn, after: before)
        calls.failAfterUpdating = false
        let applied = try JSONDecoder().decode(DeviceState.self, from: fixtureKeychain(root, app).load())
        #expect({ applied.session == StoredSession(signedIn) }())
        #expect(applied.authGeneration == 2)
        calls.failure = errSecInteractionNotAllowed
        let memory = try #require(await loadSession(store, origin: deviceOrigin))
        let refreshed = try deviceRecord()
        let count = DeviceCount()
        let duringFailure = try await store.coordinator.refresh(expected: memory, store: store) {
            await count.increment()
            return refreshed
        }
        #expect({ duringFailure?.credential == refreshed.credential }())
        #expect(await store.coordinator.authenticationGenerationFloor() == 3)
        calls.failure = nil
        let peer = try deviceRecord()
        if peerChanged { try rejoinPeer(root, app) { $0.session = StoredSession(peer) } }
        let recovered = try await loadSession(store, origin: deviceOrigin)
        #expect({ peerChanged ? recovered == nil : recovered?.credential == refreshed.credential }())
        let next = try await loadSession(store, origin: deviceOrigin)
        let expected = peerChanged ? peer : refreshed
        #expect({ next?.credential == expected.credential }())
        let final = try JSONDecoder().decode(DeviceState.self, from: fixtureKeychain(root, app).load())
        #expect({ final.session == StoredSession(expected) }())
        #expect(final.authGeneration == (peerChanged ? 2 : 3))
        #expect(await count.value == 1)
        print("Keychain protocol fake calls: \(calls.callCount); real Keychain calls: 0 (protocol fake only)")
    }
}

@Test(arguments: [false, true])
func deviceRejoinExplicitAuthenticationClearsObservedPeerMarks(cleanupFails: Bool) async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let signup = rejoinAttempt(screen: "signup")
        let other = rejoinAttempt(screen: "other", sequence: 2)
        try rejoinPeer(root, app) { $0.attempts = [signup, other] }
        let peerBefore = try await store.snapshot(preparingAuthentication: true)
        let original = try #require(await store.load())
        let refreshed = try rejoinRecord(matching: original)
        let count = DeviceCount()
        _ = try await store.coordinator.refresh(expected: original, store: store) {
            await count.increment()
            calls.updateFailure = errSecInteractionNotAllowed
            return refreshed
        }
        calls.updateFailure = nil
        #expect(try await loadSession(store, origin: deviceOrigin) == nil)
        let stored = try fixtureKeychain(root, app).load()
        let beforeCleanup = try await store.snapshot()
        #expect(beforeCleanup.state.authenticationSwitches.map(\.id) == [peerBefore.authenticationSwitchID])
        if cleanupFails {
            calls.updateFailure = errSecInteractionNotAllowed
            do {
                _ = try await store.snapshot(preparingAuthentication: true)
                Issue.record("Expected authentication preparation to fail")
            } catch let error as ClientError {
                #expect(error.code == "failed_precondition")
                #expect(error.devicePreparation)
            }
            calls.updateFailure = nil
            #expect(try fixtureKeychain(root, app).load() == stored)
            #expect(try await loadSession(store, origin: deviceOrigin) == nil)
        }
        let before = try await store.snapshot(preparingAuthentication: true)
        #expect(before.session == nil)
        #expect({ before.state.session == nil }())
        #expect({ before.state.authenticationSwitches.isEmpty }())
        #expect({ !before.state.refreshUncertain }())
        #expect({ before.state.refreshRequestID == nil }())
        #expect(before.authGeneration == beforeCleanup.authGeneration + 1)
        #expect(await store.coordinator.authenticationGenerationFloor() == 0)
        #expect(before.attempts.map(\.id) == [signup.id, other.id])
        #expect(try await store.attempt(screen: signup.screen)?.id == signup.id)
        #expect(try await store.attempt(screen: other.screen)?.id == other.id)
        let signedIn = try deviceRecord()
        let transport = try HTTPTransport(origin: deviceOrigin).withSession(store)
        _ = try await transport.acceptSession(signedIn, after: before)
        _ = try await transport.acceptSession(deviceRecord(), after: peerBefore)
        let result = try await loadSession(store, origin: deviceOrigin)
        #expect({ result?.credential == signedIn.credential }())
        let current = try await store.snapshot()
        #expect(current.authGeneration == before.authGeneration + 1)
        #expect(current.state.authenticationSwitches.isEmpty)
        #expect(current.attempts.map(\.id) == [signup.id, other.id])
        #expect(try await store.refreshCandidate(ifMatching: original) == nil)
        #expect(await count.value == 1)
    }
}

@Test func deviceRejoinPlainLoadKeepsRestartCleanup() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: true)
        try await store.save(deviceRecord())
        let generation = try await store.snapshot().authGeneration
        try rejoinPeer(root, app) { $0.authenticationSwitches.append(.init(id: UUID().uuidString, generation: $0.authGeneration)) }
        #expect(try await store.load() == nil)
        let state = try JSONDecoder().decode(DeviceState.self, from: fixtureKeychain(root, app).load())
        #expect({ state.session == nil && state.authenticationSwitches.isEmpty && state.authGeneration == generation + 1 }())
    }
}

@Test func deviceRejoinLogoutFailureRemainsBlocked() async throws {
    try await withDeviceFixture { root, app in
        let calls = FakeKeychainCalls(root: root)
        let store = try DeviceSessionStore(origin: deviceOrigin, app: app, project: "project", environment: "test",
                                           persist: .dir(root.path), keychainCalls: calls, protected: true)
        try await store.save(deviceRecord())
        let before = try await store.snapshot()
        calls.updateFailure = errSecInteractionNotAllowed
        await deviceFailure("failed_precondition") { _ = try await store.logout(ifGeneration: before.generation) }
        calls.updateFailure = nil
        try rejoinPeer(root, app) { $0.attempts.append(rejoinAttempt(screen: "peer")) }
        await deviceFailure("failed_precondition") { _ = try await loadSession(store, origin: deviceOrigin) }
    }
}

@Test func deviceKeychainProcessInterruptionUsesOnlyTheProtocolFake() async throws {
    try await withDeviceFixture { root, app in
        let store = try deviceStore(root, app, protected: true)
        try await store.save(deviceRecord())
        let process = try launchDeviceProbe(root: root, app: app, mode: "keychain-crash")
        process.waitUntilExit()
        #expect(process.terminationStatus == 73)
        #expect(try await store.load() != nil)
    }
}
#endif
