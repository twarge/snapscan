// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Absolute path to the vendored SANE libraries, so link flags don't depend
// on the linker's working directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SnapScan",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSane", path: "Sources/CSane"),
        .executableTarget(
            name: "SnapScan",
            dependencies: ["CSane"],
            path: "Sources/SnapScan",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .unsafeFlags(["-L\(packageDir)/vendor/lib", "-lsane"]),
            ]
        ),
        .executableTarget(
            name: "SaneSmokeTest",
            dependencies: ["CSane"],
            path: "Sources/SaneSmokeTest",
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/vendor/lib", "-lsane"])
            ]
        ),
        .testTarget(
            name: "SnapScanTests",
            dependencies: ["SnapScan"],
            path: "Tests/SnapScanTests",
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/vendor/lib", "-lsane"])
            ]
        ),
    ]
)
