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
        .library(name: "D65ProbeSupport", targets: ["D65ProbeSupport"]),
        .library(name: "D65Display", targets: ["D65Display"]),
        .library(name: "D65Calibration", targets: ["D65Calibration"]),
        .library(name: "D65Host", targets: ["D65Host"]),
        .library(name: "D65MacRuntime", targets: ["D65MacRuntime"]),
        .library(name: "D65WindowsRuntime", targets: ["D65WindowsRuntime"]),
        .executable(name: "d65", targets: ["d65"]),
    ],
    targets: [
        .target(name: "D65Core", resources: [.copy("Resources/CIE")]),
        .target(name: "D65Measurement", dependencies: ["D65Core"]),
        .target(name: "D65ProbeSupport", dependencies: ["D65Measurement"]),
        .target(name: "D65Link", dependencies: ["D65Core", "D65Measurement"]),
        .target(
            name: "D65Display",
            dependencies: ["D65Core"],
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]
        ),
        .target(name: "D65Calibration", dependencies: ["D65Core", "D65Measurement", "D65Display"]),
        // The probe host, the same on every desktop platform; each runtime supplies its transport,
        // patch window and display.
        .target(name: "D65Host", dependencies: ["D65Calibration", "D65Link", "D65Measurement"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "D65MacRuntime", dependencies: ["D65Host", "D65Calibration", "D65Link", "D65Display"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "D65WindowsRuntime",
            dependencies: ["D65Host", "D65Calibration", "D65Link", "D65Display"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: ["User32", "Gdi32", "Ws2_32", "Dnsapi", "Dxva2", "Shcore"].map {
                .linkedLibrary($0, .when(platforms: [.windows]))
            }
        ),
        .executableTarget(
            name: "d65",
            dependencies: [
                "D65Core", "D65Display", "D65Link", "D65Measurement", "D65Host",
                .target(name: "D65MacRuntime", condition: .when(platforms: [.macOS])),
                .target(name: "D65WindowsRuntime", condition: .when(platforms: [.windows])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "D65ProbeSupportTests", dependencies: ["D65ProbeSupport"]),
        .testTarget(name: "D65HostTests", dependencies: ["D65Host"]),
        .testTarget(name: "D65CalibrationTests", dependencies: ["D65Calibration", "D65Link"]),
        .testTarget(name: "D65CoreTests", dependencies: ["D65Core"]),
        .testTarget(name: "D65LinkTests", dependencies: ["D65Link", "D65Measurement"]),
    ]
)
