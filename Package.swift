// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCRTV",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MediaCRTV",
            path: "Sources/MediaCRTV",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
