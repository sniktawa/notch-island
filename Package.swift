// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NotchIsland", targets: ["NotchIsland"]),
    ],
    targets: [
        // Pure logic (Foundation only): the line protocol, geometry, hover rules, formatting. Unit-tested.
        .target(name: "IslandCore"),
        // The AppKit / SwiftUI / Core Animation helper process.
        .executableTarget(name: "NotchIsland", dependencies: ["IslandCore"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
