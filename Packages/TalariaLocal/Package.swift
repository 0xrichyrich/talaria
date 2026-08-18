// swift-tools-version: 5.10
import PackageDescription

// TalariaLocal — OPTIONAL on-device inference for Talaria, kept as a separate
// SPM package so the main Talaria package (and the app target by default)
// stays free of third-party dependencies. Linking this package pulls in
// MLX (Metal kernels) and the Hugging Face hub/tokenizer stack; the app only
// adds it when the user opts into local models.
//
// What it provides:
//   - LocalModelProvider: TalariaKit.InferenceProvider backed by an MLX
//     language model running entirely on-device.
//   - ModelCatalog: the curated small-model roster (Qwen3 1.7B/4B,
//     Llama 3.2 3B — 4-bit mlx-community conversions) with download sizes
//     and iPhone RAM guidance.
//   - ModelDownloadManager: streaming Hugging Face Hub downloads with
//     progress, disk bookkeeping, and deletion.
//
// Build notes:
//   - mlx-swift-examples is the upstream-recommended way to consume the MLX
//     LM stack (products MLXLMCommon / MLXLLM); its own README pins by
//     branch. Pin a tag here once the app repo locks a tested version.
//   - MLX requires a Metal device: iOS 16.4+ / macOS 13.3+ on Apple silicon
//     (we require iOS 17 / macOS 14 to match the main package). It does NOT
//     run in the iOS simulator on Intel Macs and is GPU-less under plain
//     `swift build` on CI — build this package with Xcode / xcodebuild for a
//     device or Apple-silicon destination.
let package = Package(
    name: "TalariaLocal",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TalariaLocal", targets: ["TalariaLocal"]),
    ],
    dependencies: [
        // The main package — for the InferenceProvider seam only.
        .package(path: "../Talaria"),
        // MLX language-model stack (MLXLMCommon, MLXLLM + transitive mlx-swift).
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main"),
        // Hub downloads (HubApi snapshot); also a transitive dependency of
        // mlx-swift-examples, declared directly because we import Hub.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.13"),
    ],
    targets: [
        .target(
            name: "TalariaLocal",
            dependencies: [
                .product(name: "TalariaKit", package: "Talaria"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]
        ),
    ]
)
