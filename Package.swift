// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ekctl",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "ekctlCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/ekctlCore"
        ),
        .executableTarget(
            name: "ekctl",
            dependencies: [
                "ekctlCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/ekctl"
        ),
        .testTarget(
            name: "ekctlTests",
            dependencies: ["ekctlCore"]
        )
    ]
)