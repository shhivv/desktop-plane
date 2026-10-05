// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "desktop-plane",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "planed", targets: ["planed"]),
        .executable(name: "DesktopPlane", targets: ["DesktopPlane"]),
        .executable(name: "GuestAgent", targets: ["GuestAgent"]),
    ],
    targets: [
        // Shared, dependency-free pieces: wire formats, egress policy, packet builders.
        .target(name: "PlaneCore"),
        // Everything that runs on the host: VMs, sessions, API, proxy, virtual LAN.
        .target(name: "PlaneHost", dependencies: ["PlaneCore"]),
        .executableTarget(name: "planed", dependencies: ["PlaneHost"]),
        .executableTarget(name: "DesktopPlane", dependencies: ["PlaneHost"]),
        // Runs inside each macOS guest.
        .executableTarget(name: "GuestAgent", dependencies: ["PlaneCore"]),
        .testTarget(name: "PlaneCoreTests", dependencies: ["PlaneCore"]),
    ],
    swiftLanguageModes: [.v5]
)
