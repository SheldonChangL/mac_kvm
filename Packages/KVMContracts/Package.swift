// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "KVMContracts",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "KVMContracts", targets: ["KVMContracts"])
  ],
  targets: [
    .target(name: "KVMContracts"),
    .testTarget(
      name: "KVMContractsTests",
      dependencies: ["KVMContracts"]
    ),
  ]
)
