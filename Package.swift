// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleVideo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SimpleVideo",
            path: "Sources/SimpleVideo"
        )
    ]
)
