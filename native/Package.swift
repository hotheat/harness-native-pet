// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHNativePet",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
        .library(name: "PetIPC", targets: ["PetIPC"]),
        .executable(name: "DSHNativePet", targets: ["DSHNativePet"]),
        .executable(name: "PetIPCSmoke", targets: ["PetIPCSmoke"]),
        .executable(name: "PetHookCLI", targets: ["PetHookCLI"]),
    ],
    targets: [
        .target(name: "PetCore"),
        .target(name: "PetIPC", dependencies: ["PetCore"]),
        .target(name: "PetHooks", dependencies: ["PetCore", "PetIPC"]),
        .executableTarget(name: "PetHookCLI", dependencies: ["PetHooks"]),
        .executableTarget(name: "DSHNativePet", dependencies: ["PetCore", "PetIPC"], resources: [.copy("Resources/Character"), .copy("Resources/DSHPet")]),
        .executableTarget(name: "PetIPCSmoke", dependencies: ["PetCore", "PetIPC"]),
        .testTarget(name: "PetCoreTests", dependencies: ["PetCore"]),
        .testTarget(name: "PetHooksTests", dependencies: ["PetHooks", "PetCore"]),
        .testTarget(name: "PetIPCTests", dependencies: ["PetCore", "PetIPC"]),
        .testTarget(name: "PetAppTests", dependencies: ["DSHNativePet"]),
    ]
)
