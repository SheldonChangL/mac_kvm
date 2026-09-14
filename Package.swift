// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacKVM",
    products: [
        .executable(name: "MacKVM", targets: ["MacKVM"]),
    ],
    targets: [
        .executableTarget(
            name: "MacKVM",
            path: "Apps/macOS/MacKVM"
        ),
    ]
)
