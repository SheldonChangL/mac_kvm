// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TLSSpike",
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
  ],
  targets: [
    .executableTarget(
      name: "TLSSpike",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "Crypto", package: "swift-crypto"),
      ])
  ])
