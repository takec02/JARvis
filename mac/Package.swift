// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIAgent",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "AIAgent",
            path: "Sources/AIAgent",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
