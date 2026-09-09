// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tokenbar", targets: ["tokenbar"]),
        .executable(name: "genfixtures", targets: ["genfixtures"]),
    ],
    dependencies: [
        // Única dependência externa do projeto (spec §6). Fixada via
        // Package.resolved; o alvo TokenBarCore a consome — providers e UI
        // só enxergam os protocolos de persistência do Core.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // `Resources/pricing.json` (F3 Task 2) viaja embutido no módulo —
        // `Bundle.module` só existe quando o target declara resources.
        .target(
            name: "TokenBarCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/pricing.json")]
        ),
        .target(name: "TokenBarProviders", dependencies: ["TokenBarCore"]),
        // `Resources/` (F4 Task 2): SVGs autorais dos logos — cópia PURA
        // (`.copy`, nunca `.process`: sem asset catalog/actool, CLT-safe),
        // carregados via NSImage (macOS 14 lê SVG). `Bundle.module` só passa
        // a existir neste target quando ele declara resources.
        .target(
            name: "TokenBarUI",
            dependencies: ["TokenBarCore", "TokenBarProviders"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "tokenbar",
            dependencies: ["TokenBarCore", "TokenBarProviders", "TokenBarUI"]
        ),
        .executableTarget(name: "genfixtures"),
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: [
                "TokenBarCore",
                // Verificação do schema §6 nos testes (tableExists/columnas).
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "TokenBarProvidersTests", dependencies: ["TokenBarProviders", "TokenBarCore"]),
        .testTarget(name: "TokenBarUITests", dependencies: ["TokenBarUI", "TokenBarCore"]),
    ]
)
