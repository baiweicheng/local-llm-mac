import Foundation

/// How much context a model backend can hold, and how this app divides
/// that room up.
///
/// Every backend (the built-in on-device model, Private Cloud
/// Compute, local MLX models, local servers, and OpenRouter) gets one of
/// these budgets. All of Phase 2's context math — when to compact, how
/// much room to leave for a reply, how long a summary may be — reads from
/// here, so a new backend only needs a new row in ``table`` and nothing
/// else changes.
///
/// "Tokens" here are the app's estimates (see `PromptHistory` — about 4
/// characters per token). The framework does report exact usage on
/// finished responses, but planning has to happen *before* sending, with
/// an estimate; the numbers below keep a safety margin for that.
struct ContextBudget: Equatable, Sendable {

    /// Identifies a backend for the budget table. Later phases key their
    /// picker/routing off these same cases.
    enum Backend: String, CaseIterable, Sendable {
        case onDevice
        case privateCloudCompute
        case mlxLocal
        case openRouterCloud
    }

    let backend: Backend

    /// The backend's full context window, in tokens — instructions,
    /// conversation, and the reply all share it.
    let windowTokens: Int

    /// Room held back for the model's next reply (and estimation error).
    /// A prompt is only ever planned up to `windowTokens - replyReserve`.
    let replyReserveTokens: Int

    /// The most a compacted summary is allowed to grow to. Summaries
    /// replace old conversation, so a runaway summary would defeat the
    /// point.
    let summaryTargetTokens: Int

    /// Room available for instructions + summary + conversation + the new
    /// prompt, keeping the reply reserve untouched.
    var promptAllowanceTokens: Int { windowTokens - replyReserveTokens }

    init(backend: Backend, windowTokens: Int) {
        self.backend = backend
        self.windowTokens = windowTokens
        // Bigger windows can afford to reserve more for long replies and
        // longer summaries; the small on-device window stays tight.
        self.replyReserveTokens = min(4_096, max(512, windowTokens / 8))
        self.summaryTargetTokens = min(2_000, max(150, windowTokens / 8))
    }

    // MARK: - The budget table

    /// The built-in on-device model: Apple's documented 4,096-token
    /// window. The only backend that exists in Phase 2.
    static let onDevice = ContextBudget(backend: .onDevice, windowTokens: 4_096)

    /// Private Cloud Compute (Phase 8): Apple's documented 32K window.
    static let privateCloudCompute = ContextBudget(backend: .privateCloudCompute,
                                                   windowTokens: 32_768)

    /// Local MLX models (Phase 3): windows vary by model (8K–128K), so
    /// this is a conservative default the model layer can override per
    /// downloaded model.
    static let mlxLocal = ContextBudget(backend: .mlxLocal, windowTokens: 8_192)

    /// OpenRouter cloud models (Phase 8): windows vary widely by model;
    /// conservative default, overridable per model.
    static let openRouterCloud = ContextBudget(backend: .openRouterCloud,
                                               windowTokens: 128_000)

    /// Every budget, keyed by backend — the table new phases slot into.
    static let table: [Backend: ContextBudget] = [
        .onDevice: .onDevice,
        .privateCloudCompute: .privateCloudCompute,
        .mlxLocal: .mlxLocal,
        .openRouterCloud: .openRouterCloud,
    ]

    static func budget(for backend: Backend) -> ContextBudget {
        table[backend] ?? .onDevice
    }
}
