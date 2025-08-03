// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TelreqApp",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "TelreqApp",
            targets: ["TelreqApp"]
        ),
    ],
    dependencies: [
        // Azure Storage Blobs SDK
        .package(
            url: "https://github.com/Azure/azure-sdk-for-ios.git",
            from: "1.0.0"
        ),
        // Additional dependencies for production
        .package(
            url: "https://github.com/stephencelis/SQLite.swift.git",
            from: "0.14.1"
        )
    ],
    targets: [
        .target(
            name: "TelreqApp",
            dependencies: [
                .product(name: "AzureStorageBlob", package: "azure-sdk-for-ios"),
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "TelreqAppTests",
            dependencies: ["TelreqApp"],
            path: "Tests"
        ),
    ]
)