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

let transport = try ClientTransport(origin: "https://api.example.com")
let result: ReadOutput = try await transport.invoke(
    "notes.read", input: ReadInput(id: "note-id")
)
```

## License

[Apache-2.0](LICENSE).
