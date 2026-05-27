// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoChain",
    platforms: [
      .iOS(.v17),
      .macOS(.v15),
      .watchOS(.v9),
      .tvOS(.v16),
      .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftCardanoChain",
            targets: ["SwiftCardanoChain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.4.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-utils.git", from: "0.5.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-blockfrost-api.git", from: "0.2.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-handles-api.git", from: "0.1.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-koios.git", from: "0.2.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-ogmios.git", from: "0.3.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-network.git", from: "1.1.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-uplc.git", from: "0.2.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftCardanoChain",
            dependencies: [
                .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
                .product(name: "SwiftCardanoUtils", package: "swift-cardano-utils"),
                .product(name: "SwiftBlockfrostAPI", package: "swift-blockfrost-api"),
                .product(name: "SwiftHandlesAPI", package: "swift-handles-api"),
                .product(name: "SwiftKoios", package: "swift-koios"),
                .product(name: "SwiftOgmios", package: "swift-ogmios"),
                .product(name: "SwiftCardanoNetwork", package: "swift-cardano-network"),
                .product(name: "SwiftCardanoUPLC", package: "swift-cardano-uplc")
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
