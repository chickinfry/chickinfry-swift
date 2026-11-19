// swift-tools-version: 6.4
import PackageDescription

#if os(Linux)
let defaultTraits: Set<String> = ["ClientTransport"]
#else
let defaultTraits: Set<String> = []
#endif

let package = Package(
    name: "Chickinfry",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v9), .visionOS(.v1)],
    products: [.library(name: "Chickinfry", targets: ["Chickinfry"]),
               .library(name: "ChickinfryServer", targets: ["ChickinfryServer"])],
    traits: [.default(enabledTraits: defaultTraits), .trait(name: "ClientTransport")],
    dependencies: [.package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.37.0")],
    targets: [
        .target(name: "Chickinfry", dependencies: [
            .product(name: "AsyncHTTPClient", package: "async-http-client",
                     condition: .when(platforms: [.linux], traits: ["ClientTransport"]))
        ]),
        .target(name: "ChickinfryServer", dependencies: ["CChickinfryExecutor"]),
        .target(name: "CChickinfryExecutor"),
        .testTarget(name: "ChickinfryServerTests", dependencies: ["ChickinfryServer"]),
        .testTarget(name: "ChickinfryTests", dependencies: ["Chickinfry"]),
    ],
    swiftLanguageModes: [.v6]
)
