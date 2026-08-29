// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Butterfly",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Option « Qualité maximale » de la dictée : Whisper large-v3-turbo
        // en CoreML, 100 % local (le modèle se télécharge sur demande).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Butterfly",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Butterfly",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
