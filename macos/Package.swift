// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Verba",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Verba", targets: ["Verba"]),
        .executable(name: "VerbaIcon", targets: ["VerbaIcon"]),
    ],
    targets: [
        .executableTarget(
            name: "Verba",
            path: "Sources/Verba",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VerbaIcon",
            path: "Sources/VerbaIcon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
