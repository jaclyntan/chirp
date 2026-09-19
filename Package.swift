// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Chirp",
    platforms: [.macOS(.v26)],
    dependencies: [
        // FluidAudio stays even with only the Apple engine selectable —
        // it powers VadEngine (silence gating on every dictation),
        // TurnDetector (hands-free end-of-turn), and Notetaker's meeting
        // transcription/live preview, all independent of which ASR
        // engine a user has picked. See docs/removed-engines.md for what
        // used to also route through it (Parakeet) and through
        // WhisperKit/whisper.cpp, and how to bring either back.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        .binaryTarget(
            name: "HarperFramework",
            path: "Vendor/harper.xcframework"
        ),
        .executableTarget(
            name: "Chirp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "HarperFramework",
            ],
            path: "Sources/Chirp",
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Pet"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
