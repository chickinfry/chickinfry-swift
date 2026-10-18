// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Chickinfry",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v9), .visionOS(.v1)],
    products: [.library(name: "Chickinfry", targets: ["Chickinfry"]),
               .library(name: "ChickinfryServer", targets: ["ChickinfryServer"])],
    targets: [
        .target(name: "Chickinfry"),
        .target(name: "ChickinfryServer", dependencies: ["CChickinfryExecutor"]),
        .target(name: "CChickinfryExecutor"),
        .testTarget(name: "ChickinfryServerTests", dependencies: ["ChickinfryServer"]),
        .testTarget(name: "ChickinfryTests", dependencies: ["Chickinfry"]),
    ],
    swiftLanguageModes: [.v6]
)
