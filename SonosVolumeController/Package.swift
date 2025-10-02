// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SonosVolumeController",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SonosVolumeController",
            targets: ["SonosVolumeController"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "SonosVolumeController",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources",
            resources: [
                .copy("../Resources")
            ]
        )
    ]
)