import Foundation

/// Which model backend a conversation talks to — the value the Phase 3
/// picker sets and `Conversation` persists.
///
/// Phase 1–2 had exactly one backend (the built-in on-device model).
/// Phase 3 adds downloadable local MLX models and OpenAI-compatible local
/// servers (Ollama, LM Studio). A selection is deliberately just an
/// identifier — *which* MLX repo, *which* saved server — so it can be
/// stored as one short string and resolved to a live backend later by
/// `BackendRegistry` / the services layer.
enum ModelSelection: Equatable, Hashable, Sendable {
    /// Apple's built-in on-device model (Foundation Models).
    case onDevice
    /// A downloaded MLX model, identified by its Hugging Face repo id
    /// (e.g. "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit").
    case mlx(repoID: String)
    /// A saved local-server configuration, by its stable id.
    case endpoint(id: UUID)

    // MARK: - Storage codec

    /// The one-line string form stored on `Conversation`. Stable by
    /// design: old or unrecognized values decode back to `.onDevice`
    /// rather than failing, so a chat can never be stranded by a model
    /// that no longer exists.
    var storageKey: String {
        switch self {
        case .onDevice:
            return "onDevice"
        case .mlx(let repoID):
            return "mlx:" + repoID
        case .endpoint(let id):
            return "endpoint:" + id.uuidString.lowercased()
        }
    }

    init(storageKey: String) {
        let key = storageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("mlx:") {
            let repoID = String(key.dropFirst("mlx:".count))
            self = repoID.isEmpty ? .onDevice : .mlx(repoID: repoID)
        } else if key.hasPrefix("endpoint:"),
                  let id = UUID(uuidString: String(key.dropFirst("endpoint:".count))) {
            self = .endpoint(id: id)
        } else {
            // "onDevice", "", and anything unrecognized.
            self = .onDevice
        }
    }

    // MARK: - Budget

    /// Which row of the Phase 2 budget table plans this backend's
    /// context. Local servers report wildly different windows and
    /// there's no reliable way to ask, so they share the conservative
    /// local row (8K) with MLX models; a chat that outgrows it compacts
    /// exactly like an MLX chat does.
    var budgetKind: ContextBudget.Backend {
        switch self {
        case .onDevice: return .onDevice
        case .mlx: return .mlxLocal
        case .endpoint: return .mlxLocal
        }
    }

    var budget: ContextBudget { ContextBudget.budget(for: budgetKind) }

    var isOnDevice: Bool { self == .onDevice }
}

/// One row of the model picker: everything the UI needs to show a
/// backend and let the user choose it, without touching live services.
struct BackendDescriptor: Equatable, Sendable, Identifiable {
    let selection: ModelSelection
    /// Picker label, e.g. "Apple On-Device", "Llama 3.1 8B", "Ollama".
    let displayName: String
    /// Small print under the label, e.g. "Built into macOS",
    /// "Local MLX model · ≈ 4.9 GB", "llama3.1 · localhost:11434".
    let detail: String
    let budget: ContextBudget
    /// False only for the on-device model when Apple Intelligence isn't
    /// ready. MLX rows appear only once downloaded (always ready), and
    /// a local server counts as ready when configured — whether it's
    /// actually running is only known when a message is sent, and the
    /// error then says so in plain English.
    let isReady: Bool

    var id: String { selection.storageKey }
}

/// Builds the picker's rows from plain inputs (what's downloaded, what's
/// configured), so the list logic is unit-testable without any live
/// model, disk, or network state.
enum BackendRegistry {

    /// Rows in picker order: the built-in model first, then downloaded
    /// MLX models in catalog order, then saved local servers in the
    /// order the user arranged them.
    static func descriptors(downloadedMLX: [MLXModelInfo],
                            endpoints: [EndpointConfig],
                            onDeviceReady: Bool) -> [BackendDescriptor] {
        var rows: [BackendDescriptor] = [
            BackendDescriptor(
                selection: .onDevice,
                displayName: "Apple On-Device",
                detail: "Built into macOS · nothing to download",
                budget: .onDevice,
                isReady: onDeviceReady)
        ]
        for info in downloadedMLX {
            rows.append(BackendDescriptor(
                selection: .mlx(repoID: info.repoID),
                displayName: info.displayName,
                detail: "Local MLX model · ≈ \(MLXCatalog.formatBytes(info.approximateBytes))",
                budget: .mlxLocal,
                isReady: true))
        }
        for config in endpoints {
            rows.append(BackendDescriptor(
                selection: .endpoint(id: config.id),
                displayName: config.name,
                detail: config.pickerDetail,
                budget: .mlxLocal,
                isReady: true))
        }
        return rows
    }

    /// The row for one selection, or nil when it refers to something
    /// that isn't there anymore (an MLX model that was deleted, a server
    /// that was removed). Callers treat nil as "fallen back to the
    /// built-in model".
    static func descriptor(for selection: ModelSelection,
                           downloadedMLX: [MLXModelInfo],
                           endpoints: [EndpointConfig],
                           onDeviceReady: Bool) -> BackendDescriptor? {
        descriptors(downloadedMLX: downloadedMLX,
                    endpoints: endpoints,
                    onDeviceReady: onDeviceReady)
            .first { $0.selection == selection }
    }
}
