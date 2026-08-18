// swift-tools-version: 5.10
import PackageDescription

// TalariaKit  — gateway protocol client, models, demo data. No UI.
// TalariaTheme — the three theme packs (soft / control / ink) + avatar language.
// TalariaUI   — every screen, built on the two above.
//
// All three compile for macOS as well as iOS so the bulk of the app can be
// compile-checked and unit-tested with `swift build` / `swift test` on a Mac
// without Xcode. iOS-only surfaces (ActivityKit, UIKit haptics) are gated
// behind #if os(iOS) or canImport checks.
let package = Package(
    name: "Talaria",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TalariaKit", targets: ["TalariaKit"]),
        .library(name: "TalariaTheme", targets: ["TalariaTheme"]),
        .library(name: "TalariaUI", targets: ["TalariaUI"]),
        .executable(name: "talaria-verify", targets: ["TalariaVerify"]),
    ],
    targets: [
        .target(name: "TalariaKit"),
        .target(name: "TalariaTheme", dependencies: ["TalariaKit"]),
        .target(name: "TalariaUI", dependencies: ["TalariaKit", "TalariaTheme"]),
        .executableTarget(name: "TalariaVerify", dependencies: ["TalariaKit"]),
        .testTarget(name: "TalariaKitTests", dependencies: ["TalariaKit"]),
    ]
)
