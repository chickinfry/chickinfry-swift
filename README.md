# Chickinfry for Swift

This package is under development and is not marked as supported until verification is complete.

## Installation

Add the package to your app's `Package.swift` dependencies:

```swift
.package(url: "https://github.com/chickinfry/chickinfry-swift", from: "0.1.0")
```

Add its library product to your app target's dependencies:

```swift
.product(name: "Chickinfry", package: "chickinfry-swift")
```

## First call

For an application that declares `notes.read` with an `id` input and `title` output:

```swift
import Chickinfry

struct ReadInput: Encodable, Sendable { let id: String }
struct ReadOutput: Decodable, Sendable { let title: String }

let transport = try HTTPTransport(origin: "https://api.example.com")
let result: ReadOutput = try await transport.invoke(
    "notes.read", input: ReadInput(id: "note-id")
)
```

## Device persistence

The runtime's device adapter stores a session and up to three pending sign-up
attempts in one versioned authentication bundle, limited to 8 KiB. Generated
authentication clients supply the application, project, environment, origin, and
sign-up screen context. Explicit bearer transports never save request credentials.
The adapter's integration interface is SPI; generated default wiring is managed
separately from this runtime package.

iOS requires a device-only, non-synchronizing Keychain item and excludes its
application support directory from backup. It never falls back to a plaintext
file. All macOS applications and executables, and Linux, use an atomically
replaced 0600 file in a 0700 directory, without an OS keychain dependency. macOS
uses application support; Linux uses `$XDG_STATE_HOME/chickinfry/<app>` or
`~/.local/state/chickinfry/<app>`. These files do not protect against administrators
or disk copies. Unset, empty, or relative XDG paths use the home default. Working
directories, Git projects, and shared temporary directories are not default storage locations.

Persistence is enabled when the setting is omitted. `Persist.disabled` keeps
state in memory for the run, and `Persist.dir` selects an application state
directory. Relative directories are resolved once at client construction; later
working directory changes do not move storage. Empty directories are rejected.
An unusable location fails client construction. After a successful
server authentication, a write failure retains the new session in memory for this
run and preserves authentication success. Storage operations themselves still
report their actual failures. A storage failure uses the existing operation error channel with
`device_storage_unavailable`, `device_storage_corrupt`, `device_storage_full`, or
`device_storage_version_unsupported`. Damaged and newer records are preserved and
blocked. Failed deletion blocks further use in the current process; failure to
write a durable block cannot guarantee protection after restarting.

iOS compilation alone does not establish support on a real device. Actual
Keychain behavior is unverified; local tests use a protocol fake. Backup,
reinstallation, and platform-specific security behavior require device acceptance
testing. This adapter does not implement an offline cache or write queue.

## License

[Apache-2.0](LICENSE).
