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
        .target(
            name: "SurroundCore",
            swiftSettings: [
                // Xcode builds packages unoptimised in Debug. The stitcher is
                // numerical code that runs 100x slower that way (a sphere took
                // six minutes instead of three seconds), so this target is
                // always optimised. Debugging the package itself means
                // removing this line temporarily. Allowed because the package
                // is a local dependency, never fetched by version.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(name: "SurroundCoreTests", dependencies: ["SurroundCore"]),
    ]
)
