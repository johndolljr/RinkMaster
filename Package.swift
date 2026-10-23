// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RinkMaster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RinkMasterCore", targets: ["RinkMasterCore"]),
        .executable(name: "RinkMaster", targets: ["RinkMaster"]),
        .executable(name: "rinkmaster-mcp", targets: ["RinkMasterMCP"]),
    ],
    targets: [
        .target(name: "RinkMasterCore"),
        .executableTarget(name: "RinkMaster", dependencies: ["RinkMasterCore"],
                          exclude: ["Info.plist"],
                          resources: [.process("Resources")]),
        .executableTarget(name: "RinkMasterMCP", dependencies: ["RinkMasterCore"]),
        .testTarget(name: "RinkMasterCoreTests", dependencies: ["RinkMasterCore"]),
    ]
)
