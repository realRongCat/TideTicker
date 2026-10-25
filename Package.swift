// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TideTicker",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TideTicker", targets: ["MarkBarApp"]),
        .executable(name: "TideTickerProbe", targets: ["MarkBarProbe"]),
    ],
    targets: [
        .target(name: "MarkBarCore"),
        .executableTarget(name: "MarkBarApp", dependencies: ["MarkBarCore"],
                          resources: [
                            .copy("Resources/CoinIcons"),
                            .copy("Resources/ExchangeIcons"),
                            .copy("Resources/Kindle"),
                          ]),
        .executableTarget(name: "MarkBarProbe", dependencies: ["MarkBarCore"]),
        .testTarget(name: "MarkBarCoreTests", dependencies: ["MarkBarCore"]),
    ]
)
