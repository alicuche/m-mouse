// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mMouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mMouse",
            path: "Sources/mMouse",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
