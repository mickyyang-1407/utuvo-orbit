// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UtuvoOrbit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UtuvoOrbit", targets: ["UtuvoOrbit"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "OrbitCore", resources: [.process("Resources")]),
        // Optional modules, switched on in Orbit's Settings.
        // ShelfKit: the cat-tail file shelf (formerly UTUVO Drop, Swift 5 mode as shipped).
        .target(name: "ShelfKit", resources: [.copy("Assets")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // ClotheslineKit: the screenshot clothesline (formerly 晾好了 LineDry).
        .target(name: "ClotheslineKit"),
        .executableTarget(
            name: "UtuvoOrbit",
            dependencies: ["OrbitCore", "ShelfKit", "ClotheslineKit",
                           .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
        .testTarget(name: "UtuvoOrbitTests", dependencies: ["OrbitCore", "UtuvoOrbit"]),
        .testTarget(name: "ShelfKitTests", dependencies: ["ShelfKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ClotheslineKitTests", dependencies: ["ClotheslineKit"])
    ]
)
