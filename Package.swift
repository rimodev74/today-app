// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ThingsClone",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ThingsClone", targets: ["ThingsClone"])
    ],
    targets: [
        .executableTarget(name: "ThingsClone"),
        .testTarget(name: "ThingsCloneTests", dependencies: ["ThingsClone"])
    ]
)
