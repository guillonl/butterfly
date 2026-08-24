// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Butterfly",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Butterfly",
            path: "Sources/Butterfly",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ButterflyTests",
            dependencies: ["Butterfly"]
        ),
    ]
)
