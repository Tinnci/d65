// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "D65",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "D65Core", targets: ["D65Core"]),
        .library(name: "D65Measurement", targets: ["D65Measurement"]),
        .library(name: "D65Link", targets: ["D65Link"]),
        .library(name: "D65Display", targets: ["D65Display"]),
        .executable(name: "d65", targets: ["d65"]),
    ],
    targets: [
        .target(name: "D65Core"),
        .target(name: "D65Measurement", dependencies: ["D65Core"]),
        .target(name: "D65Link", dependencies: ["D65Core", "D65Measurement"]),
        .target(name: "D65Display", dependencies: ["D65Core"]),
        .executableTarget(name: "d65", dependencies: ["D65Core", "D65Display", "D65Link"]),
        .testTarget(name: "D65CoreTests", dependencies: ["D65Core"]),
        .testTarget(name: "D65LinkTests", dependencies: ["D65Link", "D65Measurement"]),
    ]
)
