// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Chickinfry",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v9), .visionOS(.v1)],
    products: [.library(name: "Chickinfry", targets: ["Chickinfry"])],
    targets: [
        .target(name: "Chickinfry"),
        .testTarget(name: "ChickinfryTests", dependencies: ["Chickinfry"]),
    ],
    swiftLanguageModes: [.v6]
)
