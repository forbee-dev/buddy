// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Buddy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BuddyCore"),
        .executableTarget(name: "BuddyApp", dependencies: ["BuddyCore"]),
        .executableTarget(name: "buddy-hook", dependencies: ["BuddyCore"]),
        .testTarget(name: "BuddyCoreTests", dependencies: ["BuddyCore", "buddy-hook"]),
    ]
)
