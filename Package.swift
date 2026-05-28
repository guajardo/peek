// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS(.v11)],
    products: [
        .executable(
            name: "Peek",
            targets: ["Peek"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Peek",
            dependencies: [],
            path: "Sources/Peek"
        )
    ]
)