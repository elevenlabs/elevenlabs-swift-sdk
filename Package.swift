// swift-tools-version:6.2
// (Xcode16.4+)

import PackageDescription

let package = Package(
    name: "ElevenLabs",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v14),
        .visionOS(.v1),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "ElevenLabs",
            targets: ["ElevenLabs"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.6.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.3"),
    ],
    targets: [
        .target(
            name: "ElevenLabs",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
        ),
        .testTarget(
            name: "ElevenLabsTests",
            dependencies: [
                "ElevenLabs",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
        ),
    ],
    swiftLanguageModes: [
        .v5,
        .v6,
    ],
)
