// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonosVolumeController",
    platforms: [
        .macOS(.v13)
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