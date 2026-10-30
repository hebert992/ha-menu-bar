// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HAMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HAMenuBar",
            path: "Sources/HAMenuBar"
        ),
        .testTarget(
            name: "HAMenuBarTests",
            dependencies: ["HAMenuBar"],
            path: "Tests/HAMenuBarTests"
        ),
    ]
)
