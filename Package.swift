// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElevenLabsSwift",
    platforms: [
        .iOS(.v16),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "ElevenLabsSwift",
            targets: ["ElevenLabsSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/devicekit/DeviceKit.git", from: "5.6.0"),
    ],
    targets: [
        .target(
            name: "ElevenLabsSwift",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                "DeviceKit"
            ]
        ),
        .testTarget(
            name: "ElevenLabsSwiftTests",
            dependencies: ["ElevenLabsSwift"]
        ),
    ]
)
