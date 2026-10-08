// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), the build intermittently compiles a test
// target without the Swift Testing macro plugin and fails with "plugin for module 'TestingMacros'
// not found". Naming the plugin explicitly makes the build deterministic. Xcode's toolchain finds
// the plugin on its own, so this only applies when Xcode is absent.
let commandLineToolsTestingPlugin =
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSettings: [SwiftSetting] =
    !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        && FileManager.default.fileExists(atPath: commandLineToolsTestingPlugin)
    ? [.unsafeFlags(["-load-plugin-library", commandLineToolsTestingPlugin])]
    : []

let package = Package(
    name: "Porchlight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PorchlightCore", targets: ["PorchlightCore"]),
        .executable(name: "porchlight", targets: ["porchlight"]),
        .executable(name: "PorchlightApp", targets: ["PorchlightApp"]),
    ],
    targets: [
        // Everything that is not UI. Foundation only, so other frontends can reuse it.
        .target(name: "PorchlightCore"),
        // JSON-speaking command-line tool over the core: the contract for other frontends.
        .executableTarget(name: "porchlight", dependencies: ["PorchlightCore"]),
        // macOS menu-bar app.
        .executableTarget(name: "PorchlightApp", dependencies: ["PorchlightCore"]),
        .testTarget(
            name: "PorchlightCoreTests",
            dependencies: ["PorchlightCore"],
            exclude: ["Fixtures"],
            swiftSettings: testSettings
        ),
    ]
)
