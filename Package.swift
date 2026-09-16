// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UtuvoOrbit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UtuvoOrbit", targets: ["UtuvoOrbit"])],
    targets: [
        .target(name: "OrbitCore", resources: [.process("Resources")]),
        .executableTarget(
            name: "UtuvoOrbit",
            dependencies: ["OrbitCore"]
        ),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
        .testTarget(name: "UtuvoOrbitTests", dependencies: ["OrbitCore", "UtuvoOrbit"])
    ]
)
