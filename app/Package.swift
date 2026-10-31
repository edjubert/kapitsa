// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KapitsaApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KapitsaApp", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KapitsaAppTests", dependencies: ["KapitsaApp"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
