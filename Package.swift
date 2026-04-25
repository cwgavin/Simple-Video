// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FFmpegGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FFmpegGUI",
            path: "Sources/FFmpegGUI"
        )
    ]
)
