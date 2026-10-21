// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SplitterCRTV",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "SplitterCRTV",
            path: "Sources/SplitterCRTV",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
