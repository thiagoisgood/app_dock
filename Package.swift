// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppDockAuditEngine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AppDockAuditEngine",
            targets: ["AppDockAuditEngine"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppDockAuditEngine",
            path: "Sources",
            swiftSettings: [
                .define("APP_FLAVOR_DIRECT")
            ]
        )
    ]
)
