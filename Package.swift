// swift-tools-version:5.9
// Swift 5.9+ (Xcode 15.0+)

import PackageDescription

let package = Package(
    name: "ElevenLabs",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v14),
        .visionOS(.v1),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "ElevenLabs",
            targets: ["ElevenLabs"]
        ),
        .library(
            name: "ElevenLabsWidget",
            targets: ["ElevenLabsWidget"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "ElevenLabs",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            exclude: [
                "Internal/Protocol/schemas/agent.asyncapi.yaml"
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        .target(
            name: "ElevenLabsWidget",
            dependencies: [
                "ElevenLabs"
            ],
            resources: [
                .process("Resources/OrbShader.metal")
            ]
        ),
        .testTarget(
            name: "ElevenLabsWidgetTests",
            dependencies: [
                "ElevenLabsWidget"
            ]
        ),
        .testTarget(
            name: "ElevenLabsTests",
            dependencies: [
                "ElevenLabs",
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            resources: [
                .copy("Resources/silence.mp3"),
                .copy("Resources/spoken-audio.mp3")
            ]
        )
    ],
    swiftLanguageVersions: [
        .v5
    ]
)
