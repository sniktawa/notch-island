// swift-tools-version:5.9
import PackageDescription

// The AppKit helper is macOS-only. IslandCore stays Foundation so `swift test` can run anywhere.
var products: [Product] = []
var targets: [Target] = [
    .target(name: "IslandCore"),
    .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
]

#if os(macOS)
products.append(.executable(name: "NotchIsland", targets: ["NotchIsland"]))
targets.append(.executableTarget(name: "NotchIsland", dependencies: ["IslandCore"]))
#endif

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
