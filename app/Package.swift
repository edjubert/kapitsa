// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KapitsaApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KapitsaApp", path: ".", exclude: ["Tests", "Widget", "Info.plist",
            "Makefile", "make-icon.swift", "Kapitsa.entitlements"],
            sources: ["Sources/KapitsaApp", "Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KapitsaAppTests", dependencies: ["KapitsaApp"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
