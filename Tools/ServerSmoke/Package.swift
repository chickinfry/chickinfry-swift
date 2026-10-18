// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ServerSmoke",
    products: [.executable(name: "ServerProbe", targets: ["ServerProbe"])],
    dependencies: [.package(name: "Chickinfry", path: "../..")],
    targets: [.executableTarget(name: "ServerProbe", dependencies: [
        .product(name: "ChickinfryServer", package: "Chickinfry")
    ])],
    swiftLanguageModes: [.v6]
)
