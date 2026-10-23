import Foundation

/// One downloadable local model in the Phase 3 catalog: an MLX-format
/// model published by the mlx-community on Hugging Face, small enough to
/// matter on a Mac with 18 GB of memory.
struct MLXModelInfo: Equatable, Sendable, Identifiable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen2.5-14B-Instruct-4bit".
    let repoID: String
    /// Friendly name for the picker and the Models panel.
    let displayName: String
    /// One plain-English line: what this model is for.
    let blurb: String
    /// Approximate download size in bytes. The Models panel shows the
    /// exact on-disk size once a model is downloaded; this estimate is
    /// what the size label and the memory-fit badge are planned from.
    let approximateBytes: Int64

    var id: String { repoID }

    /// The folder name this model's files live under in the app's model
    /// store. Repo ids contain a "/", which can't appear in a folder
    /// name, so "mlx-community/X" becomes "mlx-community--X".
    var directoryName: String {
        repoID.replacingOccurrences(of: "/", with: "--")
    }
}

/// How comfortably a model fits in this Mac's memory, shown as a badge
/// in the Models panel. Judged on the weight size alone; the model also
/// needs working room on top, which is what the thresholds leave over.
enum MemoryFit: String, Equatable, Sendable {
    /// Weights take at most ~45% of memory — plenty of room to spare.
    case comfortable
    /// Weights take up to ~60% of memory — runs, but don't keep twenty
    /// other apps open alongside.
    case fits
    /// More than ~60% of memory just for weights — not worth trying.
    case tooBig

    var badgeText: String {
        switch self {
        case .comfortable: return "Fits your Mac comfortably"
        case .fits: return "Fits your Mac"
        case .tooBig: return "Too big for your Mac"
        }
    }
}

/// The curated MLX catalog plus the pure helpers around it: memory-fit
/// classification, human-readable sizes, and planning a download from a
/// Hugging Face repo's file list.
enum MLXCatalog {

    /// This Mac's total memory, in GB as the hardware reports it
    /// (18 GB on the target machine). Used as the Models panel default.
    static var thisMacMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
    }

    /// Three tiers, sized for 18 GB: a small fast model, the 8B-class
    /// default, and a 14B model at 4-bit quantization (~9 GB of weights)
    /// — the largest tier that fits this Mac with room to work. A 30B
    /// model would need ~17 GB at 4-bit and is deliberately not listed.
    static let models: [MLXModelInfo] = [
        MLXModelInfo(
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            blurb: "Small and fast. Good for quick questions, rewriting, and summaries.",
            approximateBytes: 1_900_000_000),
        MLXModelInfo(
            repoID: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            displayName: "Llama 3.1 8B",
            blurb: "The balanced default: noticeably smarter than the built-in model, still quick on this Mac.",
            approximateBytes: 4_900_000_000),
        MLXModelInfo(
            repoID: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen 2.5 14B",
            blurb: "The biggest model that fits this Mac comfortably — the strongest local option for harder questions and code.",
            approximateBytes: 8_400_000_000),
    ]

    static func info(forRepoID repoID: String) -> MLXModelInfo? {
        models.first { $0.repoID == repoID }
    }

    // MARK: - Memory fit

    /// Classifies a model of `bytes` against `totalMemoryGB` of RAM.
    /// Fractions are of total memory; the leftover above the weights is
    /// what macOS, this app, and the model's working memory share.
    static func fit(bytes: Int64, totalMemoryGB: Double) -> MemoryFit {
        guard totalMemoryGB > 0 else { return .tooBig }
        let fraction = Double(bytes) / (totalMemoryGB * 1_000_000_000)
        if fraction <= 0.45 { return .comfortable }
        if fraction <= 0.60 { return .fits }
        return .tooBig
    }

    // MARK: - Sizes

    /// "1.9 GB" / "850 MB" — one decimal, decimal (SI) units, matching
    /// how Hugging Face lists repo sizes.
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 0.1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }
}

/// Deciding which files of a Hugging Face repo actually need
/// downloading (pure, so it's testable without the network).
enum MLXDownloadPlanner {

    /// One file in a repo, from the Hugging Face API's file list.
    struct RemoteFile: Equatable, Sendable {
        let path: String
        /// Size in bytes; 0 when the API didn't say.
        let size: Int64
    }

    /// Files that ship in a repo but aren't part of the model itself.
    private static let skippedPaths: Set<String> = [
        "README.md", ".gitattributes",
    ]

    /// The files to download: everything except repo housekeeping,
    /// sorted by path so downloads (and any failure point) are
    /// deterministic.
    static func filesToDownload(from siblings: [RemoteFile]) -> [RemoteFile] {
        siblings
            .filter { !skippedPaths.contains($0.path) }
            .sorted { $0.path < $1.path }
    }

    static func totalBytes(of files: [RemoteFile]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// The download URL for one repo file.
    static func downloadURL(repoID: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoID)/resolve/main/\(path)"
        return components.url
    }

    /// The API URL listing a repo's files (with sizes, via ?blobs=true).
    static func fileListURL(repoID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repoID)"
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        return components.url
    }

    /// Parses the Hugging Face API's model response into the file list.
    /// Returns nil when the response isn't the expected shape (unknown
    /// repo, an error page, …) so the caller can say so plainly.
    static func parseFileList(jsonData: Data) -> [RemoteFile]? {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData),
              let dictionary = object as? [String: Any],
              let siblings = dictionary["siblings"] as? [[String: Any]] else {
            return nil
        }
        return siblings.compactMap { sibling in
            guard let path = sibling["rfilename"] as? String else { return nil }
            let size = (sibling["size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(path: path, size: size)
        }
    }
}
