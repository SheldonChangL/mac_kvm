// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "BarrierCompatibility",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "BarrierCompatibility", targets: ["BarrierCompatibility"])
  ],
  dependencies: [
    .package(path: "../KVMContracts")
  ],
  targets: [
    .target(
      name: "BarrierCompatibility",
      dependencies: [
        .product(name: "KVMContracts", package: "KVMContracts")
      ]
    ),
    .testTarget(
      name: "BarrierCompatibilityTests",
      dependencies: ["BarrierCompatibility"]
    ),
  ]
)
