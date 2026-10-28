// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ummh",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ummh", targets: ["ummh"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "762baf6733ca0f0dbeb1ce335363fc75066bd2c9", traits: [])
    ],
    targets: [
        .executableTarget(name: "ummh", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "ummhTests", dependencies: ["ummh"])
    ],
    swiftLanguageModes: [.v5]
)
