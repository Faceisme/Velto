// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Velto",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "betterfinder", targets: ["betterfinder"]),
        .executable(name: "Velto", targets: ["Velto"]),
        .executable(name: "BetterFinderExtension", targets: ["BetterFinderExtension"])
    ],
    targets: [
        .target(
            name: "betterfinder",
            path: "Sources/betterfinder"
        ),
        .target(
            name: "VeltoAnnotationCore",
            path: "Sources/VeltoAnnotationCore"
        ),
        .executableTarget(
            name: "Velto",
            dependencies: ["betterfinder", "VeltoAnnotationCore"],
            path: "Sources/Velto"
        ),
        .executableTarget(
            name: "BetterFinderExtension",
            dependencies: ["betterfinder"],
            path: "Sources/BetterFinderExtension",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
                .linkedFramework("FinderSync")
            ]
        ),
        .testTarget(
            name: "VeltoTests",
            // 依赖 Velto 可执行目标,测试才能 @testable import 并链接到其符号;
            // 只声明 betterfinder/VeltoAnnotationCore 时 import 能编译但链接必失败。
            dependencies: ["Velto", "betterfinder", "VeltoAnnotationCore"],
            path: "Tests/VeltoTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
