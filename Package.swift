// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Browse",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "Browse",
            path: "Sources/Browse",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "browse-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/BrowseMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
