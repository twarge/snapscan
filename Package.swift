// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Absolute path to the vendored SANE libraries, so link flags don't depend
// on the linker's working directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SnapScan",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSane", path: "Sources/CSane"),
        .executableTarget(
            name: "SnapScan",
            dependencies: ["CSane"],
            path: "Sources/SnapScan",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
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
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/vendor/lib", "-lsane"])
            ]
        ),
    ]
)
