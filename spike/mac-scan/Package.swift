// swift-tools-version:6.0
import PackageDescription
import Foundation

// Embed Info.plist (NSBluetoothAlwaysUsageDescription) into the binary so TCC does not kill it.
let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "mac-scan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mac-scan",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", plist])
            ]
        )
    ]
)
