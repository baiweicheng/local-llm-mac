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
    /// Phase 4: let the app choose per message. The prompt is
    /// classified on-device (`IntentClassifier`) and `RoutingPolicy`
    /// maps it to a concrete backend; the engine then resolves and
    /// runs that backend, so a stored `.auto` never reaches a backend
    /// unresolved. The default for new chats.
    case auto
    /// Apple's built-in on-device model (Foundation Models).
    case onDevice
    /// A downloaded MLX model, identified by its Hugging Face repo id
    /// (e.g. "mlx-community/gemma-4-12B-it-4bit").
    case mlx(repoID: String)
    /// A saved local-server configuration, by its stable id.
    case endpoint(id: UUID)
    /// Phase 8: Apple's Private Cloud Compute — Apple's own cloud
    /// model (32K context, no key; the OS decides eligibility).
    case privateCloudCompute
    /// Phase 8: a model on OpenRouter, by its OpenRouter model id
    /// (e.g. "anthropic/claude-opus-5.5") — one of the curated
    /// `OpenRouterCatalog` entries, or any custom id the user typed
    /// in Settings.
    case openRouter(modelID: String)

    // MARK: - Storage codec

    /// The one-line string form stored on `Conversation`. Stable by
    /// design: old or unrecognized values decode back to `.onDevice`
    /// rather than failing, so a chat can never be stranded by a model
    /// that no longer exists.
    var storageKey: String {
        switch self {
        case .auto:
            return "auto"
        case .onDevice:
            return "onDevice"
        case .mlx(let repoID):
            return "mlx:" + repoID
        case .endpoint(let id):
            return "endpoint:" + id.uuidString.lowercased()
        case .privateCloudCompute:
            return "privateCloudCompute"
        case .openRouter(let modelID):
            return "openRouter:" + modelID
        }
    }

    init(storageKey: String) {
        let key = storageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "auto" {
            self = .auto
        } else if key == "privateCloudCompute" {
            self = .privateCloudCompute
        } else if key.hasPrefix("mlx:") {
            let repoID = String(key.dropFirst("mlx:".count))
            self = repoID.isEmpty ? .onDevice : .mlx(repoID: repoID)
        } else if key.hasPrefix("openRouter:") {
            // Only the first prefix is stripped: a model id may
            // itself contain ":" (OpenRouter's ":free" variants do).
            let modelID = String(key.dropFirst("openRouter:".count))
            self = modelID.isEmpty ? .onDevice : .openRouter(modelID: modelID)
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
        // Auto resolves to a concrete backend before anything is
        // planned; until it does, the tightest budget is the honest
        // planning assumption (it's also what the header's token
        // meter shows for an Auto chat).
        case .auto: return .onDevice
        case .onDevice: return .onDevice
        case .mlx: return .mlxLocal
        case .endpoint: return .mlxLocal
        case .privateCloudCompute: return .privateCloudCompute
        case .openRouter: return .openRouterCloud
        }
    }

    var budget: ContextBudget { ContextBudget.budget(for: budgetKind) }

    var isOnDevice: Bool { self == .onDevice }

    var isAuto: Bool { self == .auto }

    /// Phase 8: whether this selection runs off this Mac, in a cloud
    /// (Apple's Private Cloud Compute, or OpenRouter). The UI labels
    /// these chats "Cloud"; the engine runs the privacy check before
    /// anything is sent to one; the Local Only lock refuses both.
    /// (A *server* selection is a network destination too, but it may
    /// well be this very Mac — its locality is a property of the
    /// saved configuration, checked separately.)
    var isCloud: Bool {
        switch self {
        case .privateCloudCompute, .openRouter: return true
        case .auto, .onDevice, .mlx, .endpoint: return false
        }
    }
}

/// One row of the model picker: everything the UI needs to show a
/// backend and let the user choose it, without touching live services.
struct BackendDescriptor: Equatable, Sendable, Identifiable {
    let selection: ModelSelection
    /// Picker label, e.g. "Apple On-Device", "Gemma 4 12B", "Ollama".
    let displayName: String
    /// Small print under the label, e.g. "Built into macOS",
    /// "Local MLX model · ≈ 4.9 GB", "llama3.1 · localhost:11434".
    let detail: String
    let budget: ContextBudget
    /// False only for the on-device model when Apple Intelligence isn't
    /// ready. MLX rows appear only once downloaded (always ready), Auto
    /// is always ready (it falls back to whatever local route exists),
    /// and a local server counts as ready when configured — whether
    /// it's actually running is only known when a message is sent, and
    /// the error then says so in plain English.
    let isReady: Bool

    var id: String { selection.storageKey }
}

/// Phase 8: what the picker needs to know about the cloud tier —
/// plain values, gathered by the app shell, so the row logic stays
/// testable: whether Private Cloud Compute is offered by the OS
/// right now, whether the user has saved an OpenRouter key in the
/// Keychain, and the custom OpenRouter model id from Settings
/// (empty = none).
struct CloudPickerInputs: Equatable, Sendable {
    var pccReady: Bool = false
    var openRouterKeyPresent: Bool = false
    var customOpenRouterModelID: String = ""
}

/// Builds the picker's rows from plain inputs (what's downloaded, what's
/// configured), so the list logic is unit-testable without any live
/// model, disk, or network state.
enum BackendRegistry {

    /// Rows in picker order: Auto first (Phase 4 — it's the default
    /// for new chats), then the built-in model, then Apple Private
    /// Cloud (Phase 8), then downloaded MLX models in catalog order,
    /// then saved local servers in the order the user arranged them,
    /// then the OpenRouter cloud models (curated shortlist, then the
    /// user's custom model id when one is set).
    static func descriptors(downloadedMLX: [MLXModelInfo],
                            endpoints: [EndpointConfig],
                            onDeviceReady: Bool,
                            cloud: CloudPickerInputs = CloudPickerInputs())
        -> [BackendDescriptor] {
        var rows: [BackendDescriptor] = [
            // Auto always counts as ready: it degrades to whatever
            // local route exists, and a route that's actually down
            // reports itself in plain English at send time.
            BackendDescriptor(
                selection: .auto,
                displayName: "Auto",
                detail: "Picks the best model for each message — "
                    + "on this Mac, or in the cloud when a prompt "
                    + "really needs it",
                budget: .onDevice,
                isReady: true),
            BackendDescriptor(
                selection: .onDevice,
                displayName: "Apple On-Device",
                detail: "Built into macOS · nothing to download",
                budget: .onDevice,
                isReady: onDeviceReady),
            // Phase 8: Apple's cloud. Always listed (like a saved
            // server); readiness is macOS's own eligibility, read by
            // the app shell. Under Local Only the factory refuses it
            // and the engine explains the switch, exactly as with
            // servers.
            BackendDescriptor(
                selection: .privateCloudCompute,
                displayName: "Apple Private Cloud",
                detail: cloud.pccReady
                    ? "Cloud · runs on Apple's servers, privately · no key needed"
                    : "Cloud · Apple's servers — not available on this Mac right now",
                budget: .privateCloudCompute,
                isReady: cloud.pccReady)
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
        // Phase 8: OpenRouter. The rows exist with or without a key
        // — without one they say exactly what's missing instead of
        // vanishing, and the send button stays off until a key is
        // saved (readiness drives that, as with the built-in model).
        for info in OpenRouterCatalog.models {
            rows.append(BackendDescriptor(
                selection: .openRouter(modelID: info.modelID),
                displayName: info.displayName,
                detail: cloud.openRouterKeyPresent
                    ? "Cloud · OpenRouter · paid per use"
                    : "Cloud · OpenRouter · needs your key — add it in Settings",
                budget: .openRouterCloud,
                isReady: cloud.openRouterKeyPresent))
        }
        let customID = cloud.customOpenRouterModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !customID.isEmpty,
           OpenRouterCatalog.info(forModelID: customID) == nil {
            rows.append(BackendDescriptor(
                selection: .openRouter(modelID: customID),
                displayName: customID,
                detail: cloud.openRouterKeyPresent
                    ? "Cloud · OpenRouter · your custom model"
                    : "Cloud · OpenRouter · needs your key — add it in Settings",
                budget: .openRouterCloud,
                isReady: cloud.openRouterKeyPresent))
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
                           onDeviceReady: Bool,
                           cloud: CloudPickerInputs = CloudPickerInputs())
        -> BackendDescriptor? {
        descriptors(downloadedMLX: downloadedMLX,
                    endpoints: endpoints,
                    onDeviceReady: onDeviceReady,
                    cloud: cloud)
            .first { $0.selection == selection }
    }
}
