// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SurroundCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SurroundCore", targets: ["SurroundCore"]),
    ],
    targets: [
        .target(name: "SurroundCore"),
        .testTarget(name: "SurroundCoreTests", dependencies: ["SurroundCore"]),
    ]
)
