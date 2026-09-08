// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentTrail",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentTrail", targets: ["AgentTrail"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "TrailCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AgentTrail", dependencies: ["TrailCore"]),
        .testTarget(name: "TrailCoreTests", dependencies: ["TrailCore"]),
        .testTarget(name: "AgentTrailTests", dependencies: ["AgentTrail", "TrailCore"])
    ]
)
