// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Downloader",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Downloader",
            path: "Sources/Downloader",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
