// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SwiftSDKDriver",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "swift-sdk-driver", targets: ["SwiftSDKDriver"])],
    dependencies: [
        .package(name: "Chickinfry", path: "../.."),
        .package(path: "../../sdk/plain"),
        .package(path: "../../sdk/auth"),
        .package(path: "../../sdk/requiredAuth"),
        .package(path: "../../sdk/emptySession"),
    ],
    targets: [
        .executableTarget(name: "SwiftSDKDriver", dependencies: [
            .product(name: "Chickinfry", package: "Chickinfry"),
            .product(name: "ChickinfryClientPlain", package: "plain"),
            .product(name: "ChickinfryClientAuth", package: "auth"),
            .product(name: "ChickinfryClientRequiredAuth", package: "requiredAuth"),
            .product(name: "ChickinfryClientEmptySession", package: "emptySession"),
        ]),
        .testTarget(name: "SwiftSDKDriverTests", dependencies: ["SwiftSDKDriver"]),
    ],
    swiftLanguageModes: [.v6]
)
