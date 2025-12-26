// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-zstd",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "Zstd",
            targets: ["Zstd"]
        ),
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: [
                "zstd/lib/BUCK",
                "zstd/lib/Makefile",
                "zstd/lib/README.md",
                "zstd/lib/libzstd.mk",
                "zstd/lib/libzstd.pc.in",
                "zstd/lib/module.modulemap",
                "zstd/lib/dll",
                "zstd/lib/deprecated",
                "zstd/lib/legacy",
            ],
            sources: ["zstd/lib"],
            publicHeadersPath: "include",
            cSettings: [
                .define("ZSTD_MULTITHREAD", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux])),
                .define("ZSTD_STATIC_LINKING_ONLY", to: "1"),
                .define("ZDICT_STATIC_LINKING_ONLY", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .unsafeFlags(["-pthread"], .when(platforms: [.linux])),
                .unsafeFlags(["-Wno-macro-redefined"], .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux])),
            ],
            linkerSettings: [
                .linkedLibrary("pthread", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "Zstd",
            dependencies: ["CZstd"]
        ),
        .testTarget(
            name: "ZstdTests",
            dependencies: ["Zstd"]
        ),
    ]
)
