// swift-tools-version: 6.2
// Library-only manifest at the repository root so other apps can depend on Mouthy by URL and revision.
// mac/Package.swift is the one used to build and test Mouthy itself; keep library products, dependency pins and
// resources here identical to it. Sparkle is the one exception: only the Mouthy app links it (MouthyUpdates).
import PackageDescription
let package = Package(
    name: "Mouthy",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MouthyKit", targets: ["MouthyKit"]),
        .library(name: "MouthyCore", targets: ["MouthyCore"]),
        .library(name: "MouthyNotch", targets: ["MouthyNotch"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "MouthyCore", path: "mac/Sources/MouthyCore"),
        .target(name: "MouthyNotch", path: "mac/Sources/MouthyNotch"),
        .target(name: "CSherpaOnnx", path: "mac/Sources/CSherpaOnnx"),
        .target(name: "MouthyKit", dependencies: ["MouthyCore", "MouthyNotch", "CSherpaOnnx", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "argmax-oss-swift")],
                path: "mac/Sources/MouthyKit", resources: [.copy("Resources/Mascot")])
    ],
    swiftLanguageModes: [.v5]
)
