// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "voicekey-cli",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "voicekey-cli",
            path: "Sources/voicekey-cli"
        )
    ]
)
