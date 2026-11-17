// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kveikur",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Kveikur", targets: ["Kveikur"]),
    ],
    targets: [
        .target(
            name: "KveikurCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Kveikur",
            dependencies: ["KveikurCore"]
        ),
        .testTarget(
            name: "KveikurCoreTests",
            dependencies: ["KveikurCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
