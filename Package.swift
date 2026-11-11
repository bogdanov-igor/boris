// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Boris",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The only outside code in the app: it fetches and installs updates. Exact on purpose, an update of it is a decision.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "BorisCore"),
        .target(name: "BorisData", dependencies: ["BorisCore"]),
        .target(name: "BorisCharacter", dependencies: ["BorisCore"]),
        .executableTarget(name: "Boris", dependencies: ["BorisCore", "BorisData", "BorisCharacter", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "boris-hook", dependencies: ["BorisCore"]),
        .executableTarget(name: "boris-sheet", dependencies: ["BorisCore", "BorisCharacter"]),
        .executableTarget(name: "boris-dump", dependencies: ["BorisCore", "BorisData"]),
        .testTarget(name: "BorisCoreTests", dependencies: ["BorisCore"]),
        .testTarget(name: "BorisDataTests", dependencies: ["BorisCore", "BorisData"]),
        .testTarget(name: "BorisCharacterTests", dependencies: ["BorisCore", "BorisCharacter"]),
        // A bundle of its own: these measure time, and beside hundreds of other tests they measured those tests instead. Bundles run one after another.
        .testTarget(name: "BorisTimingTests", dependencies: ["BorisCore", "BorisData"]),
        // A bundle of its own: AppSettings sets the language for its whole process, and numbers in other tests depend on it.
        .testTarget(name: "BorisAppTests", dependencies: ["Boris", "BorisCore", "BorisData", "BorisCharacter"]),
    ]
)
