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
    targets: [
        .executableTarget(
            name: "SonosVolumeController",
            dependencies: [],
            path: "Sources"
        )
    ]
)