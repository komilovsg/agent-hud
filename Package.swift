// swift-tools-version: 6.0
import Foundation
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// Swift Testing is not in the standard paths, and where it lives depends on the active toolchain:
// - Command Line Tools only: link the framework explicitly (both compilation and rpath);
// - Xcode (even if CLT is installed too): the compiler finds Testing itself, only an rpath to the Xcode framework is needed.
// The CLT framework must not be used under the Xcode compiler: macro versions differ and the tests will not build.
let fm = FileManager.default
let developerDir: String = {
    if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !d.isEmpty { return d }
    if let d = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") { return d }
    return ""
}()
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let xcodeFrameworks = developerDir + "/Platforms/MacOSX.platform/Developer/Library/Frameworks"
let usesXcode = developerDir.contains(".app/Contents/Developer") && fm.fileExists(atPath: xcodeFrameworks + "/Testing.framework")
let usesCLTTesting = !usesXcode && fm.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwift: [SwiftSetting] = v5 + (usesCLTTesting ? [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])] : [])
let testLink: [LinkerSetting] = usesCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]
    : usesXcode ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", xcodeFrameworks])] : []

let package = Package(
    name: "AgentHud",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AgentHud", targets: ["AgentHud"]),
        .executable(name: "agenthud-hook", targets: ["agenthud-hook"]),
        .executable(name: "agenthud-mcp", targets: ["agenthud-mcp"]),
    ],
    targets: [
        .target(name: "AgentHudCore", swiftSettings: v5),
        .executableTarget(name: "agenthud-hook", dependencies: ["AgentHudCore"], swiftSettings: v5),
        // The stdio server agents call to look at the screen. It only forwards each call to the app.
        .executableTarget(name: "agenthud-mcp", dependencies: ["AgentHudCore"], swiftSettings: v5),
        .executableTarget(name: "AgentHud", dependencies: ["AgentHudCore"], swiftSettings: v5),
        // Tests are an executable target: without Xcode `swift test` does not run Swift Testing,
        // so we call the runner ourselves: `swift run AgentHudCoreTests`.
        .executableTarget(
            name: "AgentHudCoreTests",
            dependencies: ["AgentHudCore"],
            path: "Tests/AgentHudCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: testSwift,
            linkerSettings: testLink + [.linkedFramework("Testing")]
        ),
    ]
)
