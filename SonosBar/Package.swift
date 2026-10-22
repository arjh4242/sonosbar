// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonosBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SonosBar", path: "Sources/SonosBar")
    ]
)
