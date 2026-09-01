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
        // Moteur de texte intégré (option « Qwen3 4B » sans Ollama) :
        // llama.cpp officiel en xcframework, inférence in-process.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10679/llama-b10679-xcframework.zip",
            checksum: "0c6ea6754847439421d5a090bb26520e0150843e55b0334eec0c8f4e3b9192cf"
        ),
        .executableTarget(
            name: "Butterfly",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "llama",
            ],
            path: "Sources/Butterfly",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
