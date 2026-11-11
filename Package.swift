// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tillbell",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Tillbell", targets: ["Tillbell"])
    ],
    targets: [
        .target(name: "Tillbell"),
        .testTarget(name: "TillbellTests", dependencies: ["Tillbell"])
    ]
)
