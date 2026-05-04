// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TonMarkNative",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "TonMarkNative", targets: ["TonMarkNative"]),
        .executable(name: "TonMarkCoreChecks", targets: ["TonMarkCoreChecks"])
    ],
    targets: [
        .target(
            name: "TonMarkCore",
            path: "Sources/TonMarkCore"
        ),
        .executableTarget(
            name: "TonMarkNative",
            dependencies: ["TonMarkCore"],
            path: "Sources/TonMarkNative"
        ),
        .executableTarget(
            name: "TonMarkCoreChecks",
            dependencies: ["TonMarkCore"],
            path: "Checks/TonMarkCoreChecks"
        ),
        .testTarget(
            name: "TonMarkCoreTests",
            dependencies: ["TonMarkCore"],
            path: "Tests/TonMarkCoreTests"
        )
    ]
)
