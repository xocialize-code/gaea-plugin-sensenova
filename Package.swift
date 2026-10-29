// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-sensenova: SenseTime's SenseNova-U1.5 8B MoT (Apache-2.0) as a Gaea research plugin. One worker
// executable built on GaeaPluginKit over sensenova-u1-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// sensenova-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-sensenova",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.3.0"),
        .package(url: "https://github.com/xocialize/sensenova-u1-swift.git", exact: "0.5.3"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
    ],
    targets: [
        .target(
            name: "SenseNovaPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXSenseNovaU1", package: "sensenova-u1-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-sensenova-worker",
            dependencies: [
                "SenseNovaPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "sensenova-inproc",
            dependencies: [
                "SenseNovaPlugin",
                .product(name: "MLXSenseNovaU1", package: "sensenova-u1-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
