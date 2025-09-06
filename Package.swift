// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoChain",
    platforms: [
      .iOS(.v14),
      .macOS(.v14),
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
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", .upToNextMinor(from: "0.1.32")),
        .package(url: "https://github.com/Kingpin-Apps/swift-blockfrost-api.git", from: "0.1.3"),
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
                .product(name: "SwiftBlockfrostAPI", package: "swift-blockfrost-api"),
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
