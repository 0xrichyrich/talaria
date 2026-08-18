import Foundation

// The curated on-device model roster. Everything here is a 4-bit
// mlx-community conversion small enough to run inside iPhone app memory
// ceilings (~3.5–4 GB usable even with the Increased Memory Limit
// entitlement on 8 GB devices — see docs/LOCAL-INFERENCE.md).
//
// Sizes are approximate hub download sizes; peak memory adds KV cache and
// runtime overhead on top of the weights.

/// One downloadable local model.
public struct LocalModelSpec: Identifiable, Hashable, Sendable, Codable {
    /// Hugging Face hub id ("mlx-community/Qwen3-1.7B-4bit").
    public var hubID: String
    /// Short display name ("Qwen3 1.7B").
    public var displayName: String
    /// Parameter count label ("1.7B").
    public var parameterLabel: String
    /// Quantization label ("4-bit").
    public var quantization: String
    /// Approximate hub download size in megabytes.
    public var approxDownloadMB: Int
    /// Approximate peak resident memory while generating, in megabytes
    /// (weights + KV cache at a few-thousand-token context).
    public var approxPeakMemoryMB: Int
    /// Minimum physical device RAM in gigabytes for a comfortable run.
    public var minimumDeviceMemoryGB: Int
    /// One-line iPhone guidance shown next to the download button.
    public var ramGuidance: String

    public var id: String { hubID }

    public init(hubID: String, displayName: String, parameterLabel: String,
                quantization: String, approxDownloadMB: Int, approxPeakMemoryMB: Int,
                minimumDeviceMemoryGB: Int, ramGuidance: String) {
        self.hubID = hubID
        self.displayName = displayName
        self.parameterLabel = parameterLabel
        self.quantization = quantization
        self.approxDownloadMB = approxDownloadMB
        self.approxPeakMemoryMB = approxPeakMemoryMB
        self.minimumDeviceMemoryGB = minimumDeviceMemoryGB
        self.ramGuidance = ramGuidance
    }

    /// "≈1.0 GB" style download-size label.
    public var downloadSizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return "≈" + formatter.string(fromByteCount: Int64(approxDownloadMB) * 1_000_000)
    }

    /// True when this device's physical RAM meets the spec's minimum.
    /// (Physical memory, not the app's allowance — a coarse gate for the UI.)
    public var fitsThisDevice: Bool {
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return physicalGB >= Double(minimumDeviceMemoryGB) - 0.5
    }
}

/// The curated roster.
public enum ModelCatalog {
    /// Default pick: smallest, runs everywhere, surprisingly capable.
    public static let qwen3_1_7B = LocalModelSpec(
        hubID: "mlx-community/Qwen3-1.7B-4bit",
        displayName: "Qwen3 1.7B",
        parameterLabel: "1.7B",
        quantization: "4-bit",
        approxDownloadMB: 1000,
        approxPeakMemoryMB: 1600,
        minimumDeviceMemoryGB: 4,
        ramGuidance: "Runs on any iPhone with 4 GB RAM or more (iPhone 12 and later). The safe default."
    )

    public static let llama3_2_3B = LocalModelSpec(
        // The chat-tuned conversion; the base Llama-3.2-3B-4bit exists on the
        // hub but is not instruction-tuned, so the catalog ships Instruct.
        hubID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B",
        parameterLabel: "3B",
        quantization: "4-bit",
        approxDownloadMB: 1800,
        approxPeakMemoryMB: 2600,
        minimumDeviceMemoryGB: 6,
        ramGuidance: "Needs 6 GB RAM or more (iPhone 13 Pro, iPhone 15, and later). May be evicted under memory pressure on 6 GB devices."
    )

    public static let qwen3_4B = LocalModelSpec(
        hubID: "mlx-community/Qwen3-4B-4bit",
        displayName: "Qwen3 4B",
        parameterLabel: "4B",
        quantization: "4-bit",
        approxDownloadMB: 2300,
        approxPeakMemoryMB: 3400,
        minimumDeviceMemoryGB: 8,
        ramGuidance: "Needs 8 GB RAM (iPhone 15 Pro, iPhone 16, and later) and the Increased Memory Limit entitlement. The most capable pocket model."
    )

    /// All catalog entries, smallest first.
    public static let all: [LocalModelSpec] = [qwen3_1_7B, llama3_2_3B, qwen3_4B]

    /// The recommended starting model.
    public static let recommended = qwen3_1_7B

    public static func spec(for hubID: String) -> LocalModelSpec? {
        all.first { $0.hubID == hubID }
    }
}
