// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Caspr",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique pure, sans dépendance système, donc testable.
        .target(
            name: "CasprCore",
            path: "Sources/CasprCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Caspr",
            dependencies: ["CasprCore"],
            path: "Sources/Caspr",
            // Le catalogue des langues et les icônes sont copiés dans le
            // bundle par `install.sh`. Les déclarer en ressources SwiftPM les
            // rangerait dans un bundle séparé qu'il faudrait copier en plus,
            // pour le même résultat.
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CasprCoreTests",
            dependencies: ["CasprCore"],
            path: "Tests/CasprCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
