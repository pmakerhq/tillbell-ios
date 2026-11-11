// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tillbell",
    // The library ships for iOS. macOS is listed so `swift test` can run the StoreKit logic
    // and the contract tests on a Mac; the bridge component itself is built for iOS only.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Tillbell", targets: ["Tillbell"])
    ],
    dependencies: [
        .package(url: "https://github.com/hotwired/hotwire-native-ios", from: "1.3.1")
    ],
    targets: [
        .target(
            name: "Tillbell",
            dependencies: [
                .product(name: "HotwireNative", package: "hotwire-native-ios", condition: .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "TillbellTests",
            dependencies: ["Tillbell"],
            resources: [.copy("Resources/contract")]
        )
    ]
)
