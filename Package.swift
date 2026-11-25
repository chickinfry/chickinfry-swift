// swift-tools-version: 6.4
import PackageDescription

#if os(Linux)
let defaultTraits: Set<String> = ["ClientTransport"]
let clientPackages: [Package.Dependency] = [
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.37.1"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.2"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.7"),
]
let clientProducts: [Target.Dependency] = [
    .product(name: "AsyncHTTPClient", package: "async-http-client", condition: .when(traits: ["ClientTransport"])),
    .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["ClientTransport"])),
    .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(traits: ["ClientTransport"])),
    .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["ClientTransport"])),
]
#else
let defaultTraits: Set<String> = []
let clientPackages: [Package.Dependency] = []
let clientProducts: [Target.Dependency] = []
#endif

let package = Package(
    name: "Chickinfry",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v9), .visionOS(.v1)],
    products: [.library(name: "Chickinfry", targets: ["Chickinfry"]),
               .library(name: "ChickinfryServer", targets: ["ChickinfryServer"])],
    traits: [.default(enabledTraits: defaultTraits), .trait(name: "ClientTransport")],
    dependencies: clientPackages,
    targets: [
        .target(name: "Chickinfry", dependencies: clientProducts),
        .target(name: "ChickinfryServer", dependencies: ["CChickinfryExecutor"]),
        .target(name: "CChickinfryExecutor"),
        .testTarget(name: "ChickinfryServerTests", dependencies: ["ChickinfryServer"]),
        .testTarget(name: "ChickinfryTests", dependencies: ["Chickinfry"]),
    ],
    swiftLanguageModes: [.v6]
)
