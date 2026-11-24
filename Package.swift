// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Gozar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GozarCore", targets: ["GozarCore"]),
        .executable(name: "vpn-router", targets: ["vpn-router"]),
        .executable(name: "gozarctl", targets: ["gozarctl"]),
        .executable(name: "Gozar", targets: ["Gozar"]),
    ],
    targets: [
        .target(name: "GozarCore"),
        .executableTarget(name: "vpn-router", dependencies: ["GozarCore"]),
        .executableTarget(name: "gozarctl", dependencies: ["GozarCore"]),
        .executableTarget(name: "Gozar", dependencies: ["GozarCore"]),
        .testTarget(name: "GozarCoreTests", dependencies: ["GozarCore"]),
    ]
)
