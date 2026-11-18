// swift-tools-version: 6.0
import PackageDescription

// Kept out of the app: Whisper and its models only come in when this tool is built.
let package = Package(
    name: "kveikur-lyrics",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        // Symlink to the app's core sources, so the tool doesn't depend on the checkout's folder name.
        .target(name: "KveikurCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "kveikur-lyrics",
            dependencies: [
                "KveikurCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
