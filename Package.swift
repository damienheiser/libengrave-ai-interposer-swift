// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EngraveInterposer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EngraveInterposer", targets: ["EngraveInterposer"]),
    ],
    targets: [
        .target(
            name: "EngraveInterposer",
            path: "Sources/EngraveInterposer",
            linkerSettings: [.linkedFramework("Network")]
        ),
    ]
)
