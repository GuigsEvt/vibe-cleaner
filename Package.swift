// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeCleaner",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "VibeCleaner", targets: ["VibeCleaner"]),
        .executable(name: "vibeclean", targets: ["vibeclean"]),
    ],
    targets: [
        .target(name: "VibeCleanerCore"),
        .executableTarget(name: "VibeCleaner", dependencies: ["VibeCleanerCore"]),
        .executableTarget(name: "vibeclean", dependencies: ["VibeCleanerCore"]),
        .testTarget(name: "VibeCleanerCoreTests", dependencies: ["VibeCleanerCore"]),
    ]
)
