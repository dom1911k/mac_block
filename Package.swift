// swift-tools-version:5.9
//
// Intent Mode — a default-locked focus system for macOS.
// Builds with the Xcode Command Line Tools only (`swift build`); see scripts/build.sh.
import PackageDescription
import Foundation

// Release builds (Phase 4) strip the dev tools: `INTENTMODE_RELEASE=1 scripts/build.sh`.
let release = ProcessInfo.processInfo.environment["INTENTMODE_RELEASE"] == "1"
let flags: [SwiftSetting] = release ? [.define("INTENTMODE_RELEASE")] : []

let package = Package(
    name: "IntentMode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "intentmoded", targets: ["intentmoded"]),
        .executable(name: "intentguard", targets: ["intentguard"]),
        .executable(name: "intentmode", targets: ["intentmode"]),
        .executable(name: "IntentScreen", targets: ["IntentScreen"]),
    ],
    targets: [
        // Shared, platform-neutral code: config, domain matching, DNS wire format, IPC, update packages.
        .target(name: "IntentCore", swiftSettings: flags),
        // Root daemon: state machine, DNS resolver, pf, app watcher, updater.
        .executableTarget(
            name: "intentmoded",
            dependencies: ["IntentCore"],
            swiftSettings: flags,
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("OpenDirectory"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Tiny launcher that launchd runs; starts the daemon and rolls back failed updates.
        .executableTarget(name: "intentguard", dependencies: ["IntentCore"], swiftSettings: flags),
        // Command-line tool.
        .executableTarget(
            name: "intentmode",
            dependencies: ["IntentCore"],
            swiftSettings: flags,
            linkerSettings: [.linkedFramework("Security")]
        ),
        // The kiosk intent screen (user-level LaunchAgent).
        .executableTarget(
            name: "IntentScreen",
            dependencies: ["IntentCore"],
            swiftSettings: flags,
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .testTarget(name: "IntentCoreTests", dependencies: ["IntentCore"]),
    ]
)
