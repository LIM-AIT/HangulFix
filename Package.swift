// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HangulFix",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HangulFix", targets: ["HangulFix"])
    ],
    targets: [
        .target(
            name: "HangulFixCore"
        ),
        .executableTarget(
            name: "HangulFix",
            dependencies: ["HangulFixCore"]
        ),
        .testTarget(
            name: "HangulFixCoreTests",
            dependencies: ["HangulFixCore"]
        )
    ]
)
