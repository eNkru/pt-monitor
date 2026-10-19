import AppKit
import Foundation
import PTMonitorCore

// PTMonitor entry point.
//
// argv is inspected before anything AppKit is touched:
//   --selftest   run the in-binary checks, exit 0/1, no GUI
//   --probe ...  fetch one server snapshot, print JSON, exit 0/1, no GUI
//   (nothing)    start the menu bar agent (accessory policy, no window)
//
// Deployment target is macOS 12, so the status item must be an AppKit
// NSStatusItem (MenuBarExtra is macOS 13+).

let appName = "PTMonitor"
let appVersion = "0.1.0"

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("\(appName) \(appVersion)")
    print("")
    print("Usage:")
    print("  \(appName)                     Start the menu bar agent")
    print("  \(appName) --selftest          Run the built-in checks and exit 0/1")
    print("  \(appName) --probe <type> ...  Fetch one server snapshot as JSON")
    print("")
    print(ProbeRunner.usage)
}

if arguments.contains("--selftest") {
    let result = await SelfTest.run()
    if result.isSuccess {
        print("selftest: OK (\(result.passed) checks passed)")
        exit(0)
    } else {
        FileHandle.standardError.write(Data("selftest: FAILED — \(result.failure ?? "unknown failure")\n".utf8))
        exit(1)
    }
}

if arguments.contains("--probe") {
    let code = await ProbeRunner.run(arguments: arguments)
    exit(code)
}

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

// Any other long option is a typo or a removed flag: refuse instead of
// silently starting the agent, which looks like nothing happened. Single-dash
// arguments are left alone: macOS routes `-AppleLanguages (zh-Hans)` and other
// `NSArgumentDomain` overrides through argv, and those must still launch the app.
let unknownOptions = arguments.filter { $0.hasPrefix("--") }
if !unknownOptions.isEmpty {
    FileHandle.standardError.write(Data("PTMonitor: unexpected argument(s) \(unknownOptions.joined(separator: " "))\n".utf8))
    printUsage()
    exit(2)
}

// Menu bar agent: accessory policy (no Dock icon), no window at launch.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
