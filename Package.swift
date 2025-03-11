// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElevenLabsSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "ElevenLabsSDK",
            targets: ["ElevenLabsSDK"]
        ),
        .executable(
                  name: "MacOSExample",
                  targets: ["MacOSExample"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "ElevenLabsSDK",
            dependencies: ["Starscream"],
            path: "Sources/ElevenLabsSDK"
        ),
        .executableTarget(
            name: "MacOSExample",
            dependencies: [
                "ElevenLabsSDK"
            ],
            path: "Sources/MacOSExample"
        ),
    ]
)
