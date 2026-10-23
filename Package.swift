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
    dependencies: [
        // Phase 3: local MLX models behind the Foundation Models
        // framework. `MLXFoundationModels` (from mlx-swift-lm) bridges
        // an open Hugging Face MLX model into a `LanguageModelSession`;
        // the other products are the package's own documented
        // integration set (Hugging Face downloading + tokenizers) —
        // the same dependency list as mlx-swift-lm's README example.
        // Versions pinned conservatively to that example (checked
        // 2026-10-23). The ONLY app file importing these modules is
        // Services/MLXBackend.swift.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",
                 .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface",
                 from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers",
                 from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalLLM",
            dependencies: [
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/LocalLLM"
        ),
        .testTarget(
            name: "LocalLLMTests",
            dependencies: ["LocalLLM"],
            path: "Tests/LocalLLMTests"
        )
    ]
)
