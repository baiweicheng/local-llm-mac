// swift-tools-version: 6.0
import PackageDescription

// LocalLLM — a native macOS chat app powered by Apple's on-device model.
//
// This is a Swift Package, not an .xcodeproj: open this folder in Xcode 27
// and press Run. The executable target builds as a regular macOS app.
// swift-tools-version 6.0 means the package compiles in Swift 6 language
// mode by default (strict concurrency checking on).
let package = Package(
    name: "LocalLLM",
    platforms: [
        // The app targets macOS 27 ("Golden Gate") — the first release line
        // whose Foundation Models framework carries the full feature set
        // this project is built on. If Xcode ever complains about this
        // line, changing it to .macOS(.v26) is harmless: the app only ever
        // runs on macOS 27 machines.
        .macOS(.v27)
    ],
    products: [
        .executable(name: "LocalLLM", targets: ["LocalLLM"])
    ],
    targets: [
        .executableTarget(
            name: "LocalLLM",
            path: "Sources/LocalLLM"
        ),
        .testTarget(
            name: "LocalLLMTests",
            dependencies: ["LocalLLM"],
            path: "Tests/LocalLLMTests"
        )
    ]
)
