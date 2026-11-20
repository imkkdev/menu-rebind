// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenuRebind",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MenuRebind", targets: ["MenuRebind"])],
    targets: [
        .target(name: "MenuRebindCore"),
        .executableTarget(name: "MenuRebind", dependencies: ["MenuRebindCore"]),
        .testTarget(name: "MenuRebindCoreTests", dependencies: ["MenuRebindCore"])
    ]
)
