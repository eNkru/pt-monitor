// swift-tools-version:5.7
// PTMonitor — macOS menu bar PT monitor.
//
// Builds with Command Line Tools only. There is deliberately NO test target:
// `swift test` is unusable under CLT (`error: XCTest not available`, see
// prd.md → Background). Automated checks live in
// Sources/PTMonitorCore/Diagnose/SelfTest.swift and run via
// `swift run PTMonitor --selftest`.

import PackageDescription

let package = Package(
    name: "PTMonitor",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // All reusable code lives here, so a future XCTest suite can
        // `@testable import PTMonitorCore` without fighting an executable.
        .target(
            name: "PTMonitorCore"
        ),
        // Thin executable: argv dispatch + AppKit bootstrap only.
        .executableTarget(
            name: "PTMonitor",
            dependencies: ["PTMonitorCore"]
        )
    ]
)
