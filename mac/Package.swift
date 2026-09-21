// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIAgent",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "AIAgent",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            path: "Sources/AIAgent",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
