// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ReleaseLauncher",
    platforms: [.macOS(.v12)],
    targets: [.executableTarget(name: "ReleaseLauncher", path: "Sources")]
)
