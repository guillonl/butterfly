// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Butterfly",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Butterfly",
            path: "Sources/Butterfly",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
