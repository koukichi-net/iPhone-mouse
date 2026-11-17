// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HIDCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HIDCore", targets: ["HIDCore"]),
    ],
    targets: [
        .target(name: "HIDCore"),
        .testTarget(name: "HIDCoreTests", dependencies: ["HIDCore"]),
    ],
    swiftLanguageModes: [.v6]
)
