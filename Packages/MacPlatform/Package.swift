// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MacPlatform",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MacPlatform", targets: ["MacPlatform"])
  ],
  dependencies: [
    .package(path: "../KVMContracts")
  ],
  targets: [
    .target(
      name: "MacPlatform",
      dependencies: [
        .product(name: "KVMContracts", package: "KVMContracts")
      ]
    ),
    .testTarget(
      name: "MacPlatformTests",
      dependencies: ["MacPlatform"]
    ),
  ]
)
