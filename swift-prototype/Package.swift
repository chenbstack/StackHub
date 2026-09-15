// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StackHub",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StackHub", targets: ["StackHub"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "StackHub",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Localization")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "StackHubTests", dependencies: ["StackHub"])
    ]
)
