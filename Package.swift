// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Boris",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BorisCore"),
        .target(name: "BorisData", dependencies: ["BorisCore"]),
        .target(name: "BorisCharacter", dependencies: ["BorisCore"]),
        .executableTarget(name: "Boris", dependencies: ["BorisCore", "BorisData", "BorisCharacter"]),
        .executableTarget(name: "boris-hook", dependencies: ["BorisCore"]),
        .executableTarget(name: "boris-sheet", dependencies: ["BorisCore", "BorisCharacter"]),
        .executableTarget(name: "boris-dump", dependencies: ["BorisCore", "BorisData"]),
        .testTarget(name: "BorisCoreTests", dependencies: ["BorisCore"]),
        .testTarget(name: "BorisDataTests", dependencies: ["BorisCore", "BorisData"]),
        .testTarget(name: "BorisCharacterTests", dependencies: ["BorisCore", "BorisCharacter"]),
    ]
)
