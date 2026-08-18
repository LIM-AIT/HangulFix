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
        .target(
            name: "HangulFixMail",
            dependencies: ["HangulFixCore"]
        ),
        .executableTarget(
            name: "HangulFix",
            dependencies: ["HangulFixCore", "HangulFixMail"]
        ),
        .testTarget(
            name: "HangulFixCoreTests",
            dependencies: ["HangulFixCore"]
        ),
        .testTarget(
            name: "HangulFixMailTests",
            dependencies: ["HangulFixMail", "HangulFixCore"]
        )
    ]
)
