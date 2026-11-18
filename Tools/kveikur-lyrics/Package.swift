// swift-tools-version: 6.0
import PackageDescription

// Kept out of the app. The alignment itself is the Python worker in aligner/, run through uv.
let package = Package(
    name: "kveikur-lyrics",
    platforms: [.macOS(.v15)],
    targets: [
        // Symlink to the app's core sources, so the tool doesn't depend on the checkout's folder name.
        .target(name: "KveikurCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "kveikur-lyrics",
            dependencies: ["KveikurCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
