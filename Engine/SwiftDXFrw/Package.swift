// swift-tools-version: 6.2.0
import PackageDescription

let package = Package(
    name: "SwiftDXFrw",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "SwiftDXFrw", targets: ["SwiftDXFrw"]),
    ],
    targets: [
        // C module wrapping system iconv (cross-platform)
        .systemLibrary(
            name: "CIconv",
            path: "Dependencies/CIconv",
            pkgConfig: "iconv",
            providers: [
                .brew(["libiconv"]),
                .apt(["libiconv-dev"]),
            ]
        ),
        // Pure Swift DXF reader/writer target
        .target(
            name: "SwiftDXFrw",
            dependencies: ["CIconv"],
            path: "Sources/SwiftDXFrw",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
    ]
)
