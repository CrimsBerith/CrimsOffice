// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClawOffice",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClawOffice", targets: ["ClawOffice"])
    ],
    targets: [
        .executableTarget(
            name: "ClawOffice",
            path: "Sources/ClawOffice",
            resources: [
                .copy("Resources/avatars")
            ]
        ),
        .testTarget(
            name: "ClawOfficeTests",
            dependencies: ["ClawOffice"]
        )
    ]
)
