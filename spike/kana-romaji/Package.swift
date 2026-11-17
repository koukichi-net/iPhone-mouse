// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KanaRomaji",
    products: [
        .library(name: "KanaRomaji", targets: ["KanaRomaji"]),
    ],
    targets: [
        .target(name: "KanaRomaji"),
        .testTarget(name: "KanaRomajiTests", dependencies: ["KanaRomaji"]),
    ],
    swiftLanguageModes: [.v6]
)
