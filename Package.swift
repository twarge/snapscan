// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapScan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnapScan",
            path: "Sources/SnapScan",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "SnapScanTests",
            dependencies: ["SnapScan"],
            path: "Tests/SnapScanTests"
        ),
    ]
)
