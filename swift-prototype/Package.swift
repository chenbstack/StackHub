// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StackHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StackHub", targets: ["StackHub"])
    ],
    targets: [
        .executableTarget(name: "StackHub"),
        .testTarget(name: "StackHubTests", dependencies: ["StackHub"])
    ]
)
