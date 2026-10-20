// swift-tools-version: 6.0
import PackageDescription

// Layering (docs/ARCHITECTURE.md §3). Dependencies only point downwards:
//
//   QLAssembly ──► QLModule* ──► QLCore
//        └───────► QLPlatform ─► QLConfigYAML ─► QLCore
//
// Feature modules never depend on each other or on QLPlatform; the composition root
// (QLAssembly) wires platform services into them. Import rules the compiler can't
// enforce (e.g. "QLCore doesn't import AppKit") are checked by scripts/lint-layers.sh.

let modules = ["QLModuleLauncher", "QLModuleApps", "QLModuleWindow", "QLModuleSystem", "QLModuleClaude"]

let package = Package(
    name: "QuickLaunchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QLCore", targets: ["QLCore"]),
        .library(name: "QLPlatform", targets: ["QLPlatform"]),
        .library(name: "QLAssembly", targets: ["QLAssembly"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "QLCore"),
        .target(name: "QLConfigYAML", dependencies: ["QLCore", .product(name: "Yams", package: "Yams")]),
        .target(name: "QLPlatform", dependencies: ["QLCore", "QLConfigYAML"]),
    ]
    + modules.map { .target(name: $0, dependencies: ["QLCore"]) }
    + [
        .target(name: "QLAssembly", dependencies: ["QLCore", "QLPlatform"] + modules.map { .target(name: $0) }),
        .target(name: "QLTesting", dependencies: ["QLCore", "QLConfigYAML"]),

        .testTarget(name: "QLCoreTests", dependencies: ["QLCore", "QLTesting"]),
        .testTarget(name: "QLConfigYAMLTests", dependencies: ["QLConfigYAML"]),
        .testTarget(name: "QLPlatformTests", dependencies: ["QLPlatform"]),
        .testTarget(name: "QLModulesTests", dependencies: ["QLTesting"] + modules.map { .target(name: $0) }),
        .testTarget(name: "QLAssemblyTests", dependencies: ["QLAssembly", "QLTesting"]),
    ]
)
