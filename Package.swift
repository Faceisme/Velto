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
            path: "Sources/Velto",
            linkerSettings: [
                // 切换器要用 SkyLight 私有框架里的 CGS / SLPS / _AXUIElementGetWindow
                // 等符号。@_silgen_name 让 Swift 在编译期生成对未解析符号的引用,
                // 这里把私有框架链上,ld 才找得到。路径在所有 macOS 都是固定的:
                //   /System/Library/PrivateFrameworks/SkyLight.framework
                // 注意:私有框架不在默认 framework 搜索路径里,要 -F 明确指出。
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight")
            ]
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
