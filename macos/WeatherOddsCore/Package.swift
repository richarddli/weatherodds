// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "WeatherOddsCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WeatherOddsCore", targets: ["WeatherOddsCore"]),
        .executable(name: "weatherodds-conformance", targets: ["weatherodds-conformance"]),
        .executable(name: "weatherodds-diagnostics", targets: ["weatherodds-diagnostics"]),
    ],
    targets: [
        // Pure ensemble math + API client. No AppKit/SwiftUI, so it builds and
        // runs under the Command Line Tools toolchain as well as inside Xcode.
        .target(name: "WeatherOddsCore"),
        // Drift check against conformance/reference.json, which the Python CLI
        // generates. This validates the complete cross-language payload.
        .executableTarget(name: "weatherodds-conformance", dependencies: ["WeatherOddsCore"]),
        // Live, explicit-error smoke test for the same geocode and forecast
        // pipeline used by the widget extension.
        .executableTarget(name: "weatherodds-diagnostics", dependencies: ["WeatherOddsCore"]),
        .testTarget(name: "WeatherOddsCoreTests", dependencies: ["WeatherOddsCore"]),
    ]
)
