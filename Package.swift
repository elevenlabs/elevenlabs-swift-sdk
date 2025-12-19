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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "ElevenLabs",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            // TODO: Re-enable StrictConcurrency once LiveKit depends on a JWTKit
            // release where Sendable annotations are available (4.13.x patch or 5.x).
            // Tracking: https://github.com/livekit/client-sdk-swift/issues/846
            exclude: [
                "Internal/Protocol/schemas/agent.asyncapi.yaml"
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "ElevenLabsTests",
            dependencies: [
                "ElevenLabs",
                .product(name: "LiveKit", package: "client-sdk-swift")
            ]
        )
    ]
)
