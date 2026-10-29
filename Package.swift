// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicSplit",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MusicSplit",
            path: "Sources/MusicSplit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
