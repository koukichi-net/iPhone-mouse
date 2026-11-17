// swift-tools-version:6.0
import PackageDescription
import Foundation

// The Info.plist (NSBluetoothAlwaysUsageDescription) is embedded into the binary's __TEXT,__info_plist
// section so that TCC lets a bare command-line tool use CoreBluetooth.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "mac-connect",
    platforms: [.macOS(.v14)],
    dependencies: [
        // KeyMap / KeyUsage for `translate` and for decoding keys in `monitor --seize`.
        .package(path: "../../Packages/HIDCore"),
    ],
    targets: [
        .executableTarget(
            name: "mac-connect",
            dependencies: [.product(name: "HIDCore", package: "HIDCore")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
