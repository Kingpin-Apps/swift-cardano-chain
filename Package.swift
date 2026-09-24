// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoChain",
    platforms: [
      .iOS(.v18), // bumped from v17: depends on swift-cardano-utils, now iOS 18
      .macOS(.v15),
      .watchOS(.v9),
      .tvOS(.v16),
      .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SwiftCardanoChain",
            targets: ["SwiftCardanoChain"]),
    ],
    traits: [
        .trait(
            name: "CLIBackends",
            description: "cardano-cli & node-socket chain backends. Pulls SwiftCardanoUtils' CLITools (tuist/Command, subprocess) — macOS/Linux only. Off by default; wallets use the Blockfrost/Koios/Ogmios backends instead."
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.7.0"),
        // Consumers that enable CLIBackends must also enable SwiftCardanoUtils' CLITools trait
        // (top-level, e.g. scm). MansAmana enables neither, so utils' CLI/Command code is excluded.
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-utils.git", from: "0.5.6"),
        .package(url: "https://github.com/Kingpin-Apps/swift-blockfrost-api.git", from: "0.2.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-handles-api.git", from: "0.1.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-koios.git", from: "0.2.2"),
        .package(url: "https://github.com/Kingpin-Apps/swift-ogmios.git", from: "0.3.2"),
        .package(url: "https://github.com/Kingpin-Apps/swift-yaci-api.git", from: "0.1.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-network.git", from: "1.1.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-uplc.git", from: "0.6.1"),
        // Direct dep (was transitive via SwiftCardanoUtils, now trait-gated out): OfflineTransfer
        // uses FilePath. Apple package, iOS-safe.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
    ],
    targets: [
        .target(
            name: "SwiftCardanoChain",
            dependencies: [
                .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
                // SwiftCardanoUtils is a macOS/Linux CLI toolkit (subprocess). Only the CardanoCLI
                // & NodeSocket backends need it — pulled only when CLIBackends is enabled. The
                // Ogmios client backend uses SwiftOgmios directly (no utils).
                .product(name: "SwiftCardanoUtils", package: "swift-cardano-utils", condition: .when(traits: ["CLIBackends"])),
                .product(name: "SwiftBlockfrostAPI", package: "swift-blockfrost-api"),
                .product(name: "SwiftHandlesAPI", package: "swift-handles-api"),
                .product(name: "SwiftKoios", package: "swift-koios"),
                .product(name: "SwiftOgmios", package: "swift-ogmios"),
                .product(name: "SwiftYaciAPI", package: "swift-yaci-api"),
                .product(name: "SwiftCardanoNetwork", package: "swift-cardano-network"),
                .product(name: "SwiftCardanoUPLC", package: "swift-cardano-uplc"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [
                .define("CLIBACKENDS", .when(traits: ["CLIBackends"])),
            ]
        ),
        .testTarget(
            name: "SwiftCardanoChainTests",
            dependencies: ["SwiftCardanoChain"],
            resources: [
               .copy("data")
           ],
            swiftSettings: [
                .define("CLIBACKENDS", .when(traits: ["CLIBackends"])),
            ]
        ),
    ]
)
