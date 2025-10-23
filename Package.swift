// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoChain",
    platforms: [
      .iOS(.v14),
      .macOS(.v15),
      .watchOS(.v7),
      .tvOS(.v14),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftCardanoChain",
            targets: ["SwiftCardanoChain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", .upToNextMinor(from: "0.2.13")),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-utils.git", .upToNextMinor(from: "0.1.14")),
        .package(url: "https://github.com/Kingpin-Apps/swift-blockfrost-api.git", from: "0.1.5"),
        .package(url: "https://github.com/Kingpin-Apps/swift-koios.git", from: "0.1.2"),
        .package(url: "https://github.com/KINGH242/PotentCodables.git", .upToNextMinor(from: "3.6.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftCardanoChain",
            dependencies: [
                "PotentCodables",
                .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
                .product(name: "SwiftCardanoUtils", package: "swift-cardano-utils"),
                .product(name: "SwiftBlockfrostAPI", package: "swift-blockfrost-api"),
                .product(name: "SwiftKoios", package: "swift-koios"),
            ]
        ),
        .testTarget(
            name: "SwiftCardanoChainTests",
            dependencies: ["SwiftCardanoChain"],
            resources: [
               .copy("data")
           ]
        ),
    ]
)
