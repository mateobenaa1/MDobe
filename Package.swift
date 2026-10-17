// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MDobe",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "MDobe", path: "Sources", sources: ["MDobe", "Shared"])
    ],
    swiftLanguageModes: [.v5]
)
