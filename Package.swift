// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VibeEdit",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VibeEdit", targets: ["VibeEdit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.2.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.40.0"),
        .package(url: "https://github.com/clerk/clerk-convex-swift", from: "0.1.0"),
        .package(url: "https://github.com/clerk/clerk-ios", from: "1.0.0"),
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        .package(url: "https://github.com/elevenlabs/elevenlabs-swift-sdk.git", from: "3.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "VibeEdit",
            dependencies: [
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "ClerkConvex", package: "clerk-convex-swift"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ConvexMobile", package: "convex-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "ElevenLabs", package: "elevenlabs-swift-sdk"),
            ],
            path: "Sources/VibeEdit",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
            ],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/vibeedit.mcpb"),
                .copy("Resources/Images"),
            ]
        ),
        .testTarget(
            name: "VibeEditTests",
            dependencies: ["VibeEdit"],
            path: "Tests/VibeEditTests"
        ),
    ]
)
