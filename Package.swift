// swift-tools-version: 5.9
import PackageDescription
import Foundation
let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("HelperSupport").path
let package = Package(
    name: "Lime", platforms: [.macOS(.v13)],
    products: [.executable(name: "Lime", targets: ["Lime"]), .executable(name: "MacleanHelper", targets: ["MacleanHelper"])],
    targets: [
        .target(name: "MacleanShared"),
        .target(name: "MacleanHelperCore", dependencies: ["MacleanShared"]),
        .executableTarget(name: "MacleanHelper", dependencies: ["MacleanShared", "MacleanHelperCore"], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", support + "/Info.plist",
                          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__launchd_plist", "-Xlinker", support + "/Launchd.plist"])
        ]),
        .executableTarget(name: "Lime", dependencies: ["MacleanShared"]),
        .executableTarget(name: "HelperConnectionProbe", dependencies: ["MacleanShared", "MacleanHelperCore"], path: "Tools/HelperConnectionProbe"),
        .testTarget(name: "LimeTests", dependencies: ["Lime", "MacleanShared", "MacleanHelperCore"])
    ])
