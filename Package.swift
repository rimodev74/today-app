// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Today",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Today", targets: ["Today"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Today",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // Concurrence stricte VÉRIFIÉE, en avertissements. Le mode langage reste Swift 5 pour
            // une seule raison : 37 diagnostics subsistent, tous le MÊME — `SortDescriptor(\Model.x)`
            // exige un chemin de clé `Sendable`, or un `@Model` SwiftData ne l'est pas. C'est un
            // trou entre SwiftData et Swift 6, pas une dette de ce code ; le taire d'un
            // `@unchecked Sendable` sur les modèles serait un mensonge (ce sont des classes
            // mutables), exactement le rafistolage que ce projet refuse.
            //
            // Tout le reste est traité : ce réglage est désormais un CLIQUET. Un nouveau diagnostic
            // qui n'est pas un chemin de clé est une vraie régression d'isolation, à corriger et non
            // à ajouter au décompte. Passer en `swiftLanguageMode: .v6` le jour où Apple comble le
            // trou (ou où les `@Query` triés n'en dépendent plus).
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "TodayTests", dependencies: ["Today"])
    ]
)
