// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Today",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Today", targets: ["Today"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Today",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "TodayTests", dependencies: ["Today"])
    ]
)
