// swift-tools-version:6.0
import PackageDescription

// Platforms are limited to what CI actually builds: Linux (core module, implicit),
// macOS 14 (core + UI via `swift test`) and iOS 17 (core + UI via `xcodebuild`).
let package = Package(
    name: "ProactiveAgentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ProactiveAgent", targets: ["ProactiveAgent"]),
        .library(name: "ProactiveAgentUI", targets: ["ProactiveAgentUI"]),
    ],
    targets: [
        .target(name: "ProactiveAgent"),
        // Every file in this target is wrapped in `#if canImport(SwiftUI)`, so on Linux it
        // compiles to an empty module and the core stays verifiable there.
        .target(name: "ProactiveAgentUI", dependencies: ["ProactiveAgent"]),
        .testTarget(name: "ProactiveAgentTests", dependencies: ["ProactiveAgent"]),
        // No `@testable` here: this target sees exactly what ProactiveAgentUI (another module)
        // sees, so a public-API regression the UI depends on fails on Linux too.
        .testTarget(name: "ProactiveAgentPublicAPITests", dependencies: ["ProactiveAgent"]),
    ]
)
