// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VibeGestures",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VibeGestures", targets: ["VibeGestures"])
    ],
    targets: [
        .executableTarget(
            name: "VibeGestures",
            path: "Sources/MouseGesture"
        )
    ],
    swiftLanguageModes: [.v6]
)
