// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Telegraph",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "telegraph", targets: ["Telegraph"])],
    dependencies: [],
    targets: [
        .target(name: "TelegraphCore", exclude: ["Resources"]),
        .executableTarget(name: "Telegraph", dependencies: ["TelegraphCore"]),
        .testTarget(name: "TelegraphCoreTests", dependencies: ["TelegraphCore"], resources: [.process("Fixtures")])
    ]
)
