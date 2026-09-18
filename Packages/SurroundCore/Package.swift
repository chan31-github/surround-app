// swift-tools-version:6.4
// Tools version 6 and later build the package in Swift 6 language mode, so
// its concurrency (the parallel compositing bands) is checked. The platform
// floor stays low on purpose: a library needs no minimum (spec decision 14).
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
