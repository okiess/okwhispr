// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleWhispr",
    // MLX (the local Cohere Transcribe 2B engine) requires macOS 15+.
    platforms: [.macOS(.v15)],
    dependencies: [
        // On-device speech recognition engine: Cohere Transcribe 2B via MLX.
        .package(url: "https://github.com/soniqo/speech-swift", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SimpleWhispr",
            dependencies: [
                .product(name: "CohereTranscribeASR", package: "speech-swift"),
            ],
            // Keep lenient Swift 5 concurrency semantics so the AppKit / Carbon /
            // AVAudio code compiles without heavy strict-concurrency churn.
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
        ),
    ],
)
