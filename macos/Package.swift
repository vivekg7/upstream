// swift-tools-version: 6.0
// The macOS app: docs/plans/001_native_clients_on_system_git.md. A package
// rather than an .xcodeproj so it builds, tests and reviews as plain text.
// Apple silicon only: scripts/build-mac.sh builds for arm64 alone.
import PackageDescription

let package = Package(
    name: "Upstream",
    platforms: [.macOS("26.0")],
    targets: [
        // Everything testable without a window: running git, parsing its output.
        .target(name: "UpstreamKit"),
        // The app: windows, menus, views.
        .executableTarget(name: "Upstream", dependencies: ["UpstreamKit"]),
        .testTarget(name: "UpstreamKitTests", dependencies: ["UpstreamKit"]),
    ]
)
