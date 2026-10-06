// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ur", path: "Sources/Ur")
    ]
)
