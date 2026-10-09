// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Mouthy",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Mouthy", targets: ["Mouthy"]),
        .library(name: "MouthyKit", targets: ["MouthyKit"]),
        .library(name: "MouthyCore", targets: ["MouthyCore"]),
        .library(name: "MouthyNotch", targets: ["MouthyNotch"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        // Only the Mouthy app links Sparkle (MouthyUpdates); the libraries other apps use never pull it in.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .target(name: "MouthyCore"),
        .target(name: "MouthyNotch"),
        .target(name: "CSherpaOnnx"),
        .target(name: "MouthyKit", dependencies: ["MouthyCore", "MouthyNotch", "CSherpaOnnx", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "argmax-oss-swift")],
                resources: [.copy("Resources/Mascot")]),
        .target(name: "MouthyUpdates", dependencies: ["MouthyKit", "MouthyCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "Mouthy", dependencies: ["MouthyKit", "MouthyUpdates"]),
        .testTarget(name: "MouthyCoreTests", dependencies: ["MouthyCore"]),
        .testTarget(name: "MouthyIntegrationTests", dependencies: ["MouthyKit", "MouthyCore", "MouthyNotch", "MouthyUpdates"])
    ],
    swiftLanguageModes: [.v5]
)
