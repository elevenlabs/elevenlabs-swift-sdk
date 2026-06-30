// swift-tools-version:5.9
// Swift 5.9+ (Xcode 15.0+)

import PackageDescription

let package = Package(
    name: "ElevenLabs",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .macCatalyst(.v15),
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
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.15.0")
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
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ElevenLabsWidget",
            dependencies: [
                "ElevenLabs"
            ],
            resources: [
                .process("Resources/OrbShader.metal")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
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
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageVersions: [
        .v5
    ]
)
