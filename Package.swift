// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacKVM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacKVM", targets: ["MacKVM"]),
    ],
    targets: [
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
            name: "MacPlatform",
            dependencies: ["KVMContracts"],
            path: "Packages/MacPlatform/Sources/MacPlatform"
        ),
        .target(
            name: "NativeProtocol",
            dependencies: ["KVMContracts"],
            path: "Packages/NativeProtocol/Sources/NativeProtocol"
        ),
    ]
)
