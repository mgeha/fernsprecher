// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fernsprecher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "OxoKit"),
        .executableTarget(name: "Fernsprecher", dependencies: ["OxoKit"]),
        .executableTarget(name: "oxoctl", dependencies: ["OxoKit"]),
        .testTarget(name: "OxoKitTests", dependencies: ["OxoKit"]),
        .testTarget(name: "FernsprecherTests", dependencies: ["Fernsprecher"]),
    ]
)
