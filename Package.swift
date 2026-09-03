// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tokenbar", targets: ["tokenbar"]),
        .executable(name: "genfixtures", targets: ["genfixtures"]),
    ],
    targets: [
        .target(name: "TokenBarCore"),
        .target(name: "TokenBarProviders", dependencies: ["TokenBarCore"]),
        .target(name: "TokenBarUI", dependencies: ["TokenBarCore", "TokenBarProviders"]),
        .executableTarget(
            name: "tokenbar",
            dependencies: ["TokenBarCore", "TokenBarProviders", "TokenBarUI"]
        ),
        .executableTarget(name: "genfixtures"),
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
        .testTarget(name: "TokenBarProvidersTests", dependencies: ["TokenBarProviders", "TokenBarCore"]),
        .testTarget(name: "TokenBarUITests", dependencies: ["TokenBarUI", "TokenBarCore"]),
    ]
)
