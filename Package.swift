// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ZSubLayer",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "ZSubLayer", targets: ["ZSubLayer"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/nicolaischneider/StoreKitTheKit.git",
            exact: "1.5.4"
        )
    ],
    targets: [
        .target(
            name: "ZSubLayer",
            dependencies: [
                .product(name: "StoreKitTheKit", package: "StoreKitTheKit")
            ]
        ),
        .testTarget(
            name: "ZSubLayerTests",
            dependencies: ["ZSubLayer"]
        )
    ]
)
