// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Throwcast",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CVirtualDisplay", path: "app/plugins/throwcast_engine/macos/Classes/Bridge", publicHeadersPath: "."),
        .target(name: "ThrowcastCore", dependencies: ["CVirtualDisplay"], path: "app/plugins/throwcast_engine/macos/Classes/Core"),
        .executableTarget(name: "Throwcast", dependencies: ["ThrowcastCore"]),
        .testTarget(name: "ThrowcastCoreTests", dependencies: ["ThrowcastCore"]),
    ],
    swiftLanguageModes: [.v5]
)
