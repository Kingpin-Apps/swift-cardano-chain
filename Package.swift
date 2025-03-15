// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoChain",
    platforms: [
      .iOS(.v14),
      .macOS(.v13),
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
//        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.1.13"),
//        .package(url: "https://github.com/Kingpin-Apps/swift-blockfrost-api.git", branch: "main"),
        .package(path: "/Users/hadderley/Projects/AGL/Kingpin-Apps/swift-cardano-core"),
        .package(path: "/Users/hadderley/Projects/AGL/Kingpin-Apps/swift-blockfrost-api"),
        .package(url: "https://github.com/zunda-pixel/PotentCodables.git", branch: "update-library"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftCardanoChain",
            dependencies: [
                "PotentCodables",
                .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
                .product(name: "SwiftBlockfrostAPI", package: "swift-blockfrost-api"),
            ]
        ),
        .testTarget(
            name: "SwiftCardanoChainTests",
            dependencies: ["SwiftCardanoChain"]
        ),
    ]
)
