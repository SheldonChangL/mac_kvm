// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MacKVM",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "KVMContracts",
      path: "Packages/KVMContracts/Sources/KVMContracts"
    ),
    .target(
      name: "KVMCore",
      dependencies: ["KVMContracts"],
      path: "Packages/KVMCore/Sources/KVMCore"
    ),
    .target(
      name: "BarrierCompatibility",
      dependencies: ["KVMContracts"],
      path: "Packages/BarrierCompatibility/Sources/BarrierCompatibility"
    ),
    .target(
      name: "NativeProtocol",
      dependencies: ["KVMContracts"],
      path: "Packages/NativeProtocol/Sources/NativeProtocol"
    ),
    .testTarget(
      name: "KVMCoreTests",
      dependencies: ["KVMContracts", "KVMCore"],
      path: "Packages/KVMCore/Tests/KVMCoreTests"
    ),
    .testTarget(
      name: "MacKVMUnitTests",
      dependencies: ["KVMContracts", "KVMCore"],
      path: "Tests/Unit"
    ),
    .testTarget(
      name: "MacKVMIntegrationTests",
      dependencies: [
        "KVMContracts",
        "KVMCore",
        "BarrierCompatibility",
        "NativeProtocol",
      ],
      path: "Tests/Integration"
    ),
  ]
)

// Platform-gated targets (docs/adr/M4-001-cross-platform-toolchain.md; M4-020). macOS builds
// never see the Linux targets or their dependencies; Linux builds never see the macOS ones.
#if os(macOS)
  package.products += [
    .executable(name: "MacKVM", targets: ["MacKVM"])
  ]
  package.targets += [
    .executableTarget(
      name: "MacKVM",
      dependencies: [
        "KVMCore",
        "BarrierCompatibility",
        "MacPlatform",
        "NativeProtocol",
      ],
      path: "Apps/macOS/MacKVM"
    ),
    .target(
      name: "MacPlatform",
      dependencies: ["KVMContracts"],
      path: "Packages/MacPlatform/Sources/MacPlatform"
    ),
    .testTarget(
      name: "MacKVMSystemTests",
      dependencies: [
        "KVMContracts",
        "KVMCore",
        "BarrierCompatibility",
        "MacPlatform",
        "NativeProtocol",
      ],
      path: "Tests/SystemTests"
    ),
  ]
#endif

#if os(Linux)
  // Exact pins from MacKVM_Implementation_Package_v2/toolchain.m4.lock.json. The transitive
  // packages are pinned directly as well, so the resolved graph cannot drift from the lock.
  package.dependencies += [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
    .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
  ]
  package.targets += [
    .systemLibrary(
      name: "CX11",
      path: "Packages/LinuxPlatform/Sources/CX11",
      pkgConfig: "x11",
      providers: [.apt(["libx11-dev"])]
    ),
    .systemLibrary(
      name: "CXTest",
      path: "Packages/LinuxPlatform/Sources/CXTest",
      pkgConfig: "xtst",
      providers: [.apt(["libxtst-dev"])]
    ),
    .systemLibrary(
      name: "CXRandR",
      path: "Packages/LinuxPlatform/Sources/CXRandR",
      pkgConfig: "xrandr",
      providers: [.apt(["libxrandr-dev"])]
    ),
    .systemLibrary(
      name: "CXFixes",
      path: "Packages/LinuxPlatform/Sources/CXFixes",
      pkgConfig: "xfixes",
      providers: [.apt(["libxfixes-dev"])]
    ),
    .target(
      name: "LinuxPlatform",
      dependencies: [
        "KVMContracts",
        "CX11",
        "CXTest",
        "CXRandR",
        "CXFixes",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        // LinuxTLSTransport imports NIOTLS for the handshake-completed event; declared here by
        // M4-020-FOLLOWUP-001, the manifest's owner after M1-055-FOLLOWUP-001.
        .product(name: "NIOTLS", package: "swift-nio"),
        .product(name: "Crypto", package: "swift-crypto"),
        // Named so the exact pins above are used directly (SwiftPM warns about unused
        // dependencies); swift-nio and swift-crypto use these packages anyway.
        .product(name: "SwiftASN1", package: "swift-asn1"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      path: "Packages/LinuxPlatform/Sources/LinuxPlatform"
    ),
    .testTarget(
      name: "LinuxPlatformTests",
      dependencies: ["KVMContracts", "LinuxPlatform"],
      path: "Packages/LinuxPlatform/Tests/LinuxPlatformTests"
    ),
    // M4-020-FOLLOWUP-001: the Linux client app (composition root, CLI, systemd user unit).
    .executableTarget(
      name: "MacKVMClient",
      dependencies: [
        "KVMContracts",
        "KVMCore",
        "BarrierCompatibility",
        "LinuxPlatform",
        "CX11",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      path: "Apps/Linux/MacKVMClient"
    ),
  ]
  package.products += [
    .executable(name: "mackvm-client", targets: ["MacKVMClient"])
  ]
  // The Linux runtime test (Tests/Integration/LinuxClientRuntimeTests.swift) drives the app's
  // composition root, so on Linux the integration target depends on it too.
  for target in package.targets where target.name == "MacKVMIntegrationTests" {
    target.dependencies += ["MacKVMClient", "LinuxPlatform"]
  }
#endif
