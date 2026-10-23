import Foundation

/// What a prompt is asking for, as classified by the on-device model
/// (see `IntentClassifier` in the services layer) before the message is
/// sent. The raw values are the exact category strings the classifier
/// is instructed to answer with — they come from the product brief.
///
/// The classification is a *hint* for routing, never a gate: if it
/// fails or times out, the engine treats the message as
/// `.quickTransform` and the send proceeds on the built-in model.
enum PromptIntent: String, Equatable, Sendable, CaseIterable {
    /// Wants something done on this Mac — files, photos, calendar,
    /// apps, system state. (The tools themselves arrive in
    /// Phases 5–6; routing there now is already correct.)
    case osAction = "os_action"
    /// A quick edit or answer: summarize, rewrite, reformat, translate,
    /// a short simple question — the built-in model's home turf.
    case quickTransform = "quick_transform"
    /// Hard work that should stay on this Mac: writing or debugging
    /// code, long analysis, math — a bigger local model's job.
    case localHeavy = "local_heavy"
    /// Needs a frontier cloud model: very hard reasoning, or broad
    /// up-to-the-minute world knowledge.
    case frontierCloud = "frontier_cloud"
}

/// Everything the send path needs to decide where a message may go —
/// and, for a destination off this Mac, what must be hidden before it
/// leaves (see `Redactor`). Plain values only, gathered by the app
/// shell from the live stores and settings, so the routing policy and
/// the engine's privacy decisions are testable without any of them.
struct RoutingInputs: Equatable, Sendable {
    /// Downloaded MLX models, in catalog order (small → large).
    var downloadedMLX: [MLXModelInfo] = []
    /// Saved local-server configurations, in the user's order.
    var endpoints: [EndpointConfig] = []
    /// The Local Only lock (Settings). When on, no server backend may
    /// be used at all — only models that run on this Mac.
    var localOnly: Bool = false
    /// Phase 8: whether the user has saved an OpenRouter API key
    /// (in the Keychain — routing only ever learns THAT one exists,
    /// never the key itself). With a key, a `frontier_cloud` prompt
    /// routes to OpenRouter's best curated model for real.
    var openRouterKeyPresent: Bool = false
    /// Phase 8: whether Private Cloud Compute is offered by the OS
    /// right now. PCC is Auto's second cloud choice: no key needed,
    /// but eligibility is Apple's call.
    var pccReady: Bool = false
    /// Whether any cloud route exists at all (derived from the two
    /// inputs above). Never stored, so it can't drift out of sync.
    var cloudAvailable: Bool { openRouterKeyPresent || pccReady }
    /// Whether the built-in on-device model can chat right now
    /// (Apple Intelligence on and ready). Routing avoids it when it's
    /// known to be down and something else can stand in.
    var onDeviceReady: Bool = true
    /// The user's own additions to the privacy check (Settings): words
    /// or phrases that must never leave this Mac unhidden.
    var customRedactionTerms: [String] = []
    /// The Settings KV-cache mode for MLX models. Routing never looks
    /// at it — it travels here because the engine reads this one
    /// snapshot per send: it decides whether a live MLX session was
    /// created under the same mode (see `KVCacheMode.sessionReusable`),
    /// retiring the session when the setting has changed.
    var kvCacheMode: KVCacheMode = .defaultMode
}

/// The routing policy's answer: one concrete backend selection (never
/// `.auto` itself) plus the plain-English explanation the UI shows.
struct RoutingDecision: Equatable, Sendable {
    let selection: ModelSelection
    /// Why this backend got the message, in one short sentence.
    let reason: String
    /// An extra caveat when the route isn't the ideal one (a stand-in
    /// is covering, the built-in model is down, the lock changed the
    /// answer). Nil when the first choice was available.
    var note: String? = nil
}

/// Pure routing: (what the prompt looks like) × (what this Mac has)
/// → (which backend runs it). No model calls, no disk, no network —
/// the classifier supplies the intent, the app shell supplies the
/// inputs, and this maps them to a backend with a reason a person can
/// read. Kept deliberately small: four intents, a handful of fallback
/// rules, every branch covered by unit tests.
enum RoutingPolicy {

    static func decide(intent: PromptIntent,
                       inputs: RoutingInputs) -> RoutingDecision {
        // Under the Local Only lock, servers are off the table
        // entirely — even ones running on this Mac. The factory
        // enforces the same rule for manually picked servers.
        let usableEndpoints = inputs.localOnly ? [] : inputs.endpoints
        let largestMLX = inputs.downloadedMLX
            .max { $0.approximateBytes < $1.approximateBytes }
        let firstEndpoint = usableEndpoints.first

        // The built-in model's slot, shared by the two intents that
        // belong there: prefer it when it's ready; stand in with the
        // strongest local option when it isn't, and say so.
        func onDeviceSlot(reason: String) -> RoutingDecision {
            if inputs.onDeviceReady {
                return RoutingDecision(selection: .onDevice, reason: reason)
            }
            if let largestMLX {
                return RoutingDecision(
                    selection: .mlx(repoID: largestMLX.repoID),
                    reason: reason,
                    note: "The built-in model isn't ready right now, so "
                        + "\(largestMLX.displayName) is standing in.")
            }
            if let firstEndpoint {
                return RoutingDecision(
                    selection: .endpoint(id: firstEndpoint.id),
                    reason: reason,
                    note: "The built-in model isn't ready right now, so "
                        + "\(firstEndpoint.name) is standing in.")
            }
            // Nothing else exists — route to the built-in model and
            // let its own availability message explain the situation.
            return RoutingDecision(selection: .onDevice, reason: reason)
        }

        switch intent {
        case .osAction:
            return onDeviceSlot(
                reason: "Auto: this sounds like something to do on "
                    + "your Mac, and the built-in model is where those "
                    + "tools will live — Apple On-Device has it.")

        case .quickTransform:
            return onDeviceSlot(
                reason: "Auto: a quick edit or question — Apple "
                    + "On-Device handles those instantly and privately.")

        case .localHeavy:
            if let largestMLX {
                return RoutingDecision(
                    selection: .mlx(repoID: largestMLX.repoID),
                    reason: "Auto: this needs a bigger brain but stays "
                        + "on your Mac — \(largestMLX.displayName) is "
                        + "your largest downloaded model.")
            }
            if let firstEndpoint {
                return RoutingDecision(
                    selection: .endpoint(id: firstEndpoint.id),
                    reason: "Auto: this needs a bigger brain and no "
                        + "MLX model is downloaded, so \(firstEndpoint.name) "
                        + "gets it — that still runs on this Mac.")
            }
            var decision = RoutingDecision(
                selection: .onDevice,
                reason: "Auto: this needs a bigger brain, but no "
                    + "bigger local model is set up — Apple On-Device "
                    + "takes it. Heavy work is where it's weakest; "
                    + "downloading a model in Models would give the "
                    + "next one a stronger local option.")
            if inputs.localOnly, !inputs.endpoints.isEmpty {
                decision.note = "Local Only is on, so your servers "
                    + "are off-limits for routing."
            }
            return decision

        case .frontierCloud:
            // Phase 8: cloud routes are real now. Preference order:
            // OpenRouter's best curated model when a key exists
            // (the strongest frontier route), then Private Cloud
            // Compute (no key — Apple's own cloud), then the best
            // local stand-in, said plainly. Under Local Only the
            // cloud is off the table entirely, key or no key — the
            // factory enforces the same refusal for manual picks.
            if !inputs.localOnly {
                if inputs.openRouterKeyPresent {
                    let best = OpenRouterCatalog.best
                    return RoutingDecision(
                        selection: .openRouter(modelID: best.modelID),
                        reason: "Auto: this one wants a frontier cloud "
                            + "model — \(best.displayName) on OpenRouter "
                            + "has it. The privacy check runs first, and "
                            + "the reply shows what it cost.")
                }
                if inputs.pccReady {
                    return RoutingDecision(
                        selection: .privateCloudCompute,
                        reason: "Auto: this one wants a frontier cloud "
                            + "model — Apple Private Cloud has it: "
                            + "Apple's servers under Apple's privacy "
                            + "design, and the privacy check runs first "
                            + "anyway.")
                }
            }
            // Stand in with the strongest network-adjacent option:
            // a configured server first (it's the closest thing to a
            // bigger brain), then the largest MLX model, then the
            // built-in model — and say plainly what happened.
            let why = "Auto: this one really wants a frontier cloud "
                + "model, but no cloud route is ready — "
            let cloudNote: String? = inputs.localOnly
                ? "Local Only is on, so cloud models are off-limits "
                    + "while the lock is on — nothing leaves this Mac."
                : "To use a cloud model for prompts like this, add "
                    + "your OpenRouter key in Settings → Cloud models; "
                    + "Apple Private Cloud also joins on its own when "
                    + "macOS offers it."
            if let firstEndpoint {
                return RoutingDecision(
                    selection: .endpoint(id: firstEndpoint.id),
                    reason: why + "for now \(firstEndpoint.name) "
                        + "stands in.",
                    note: cloudNote)
            }
            if let largestMLX {
                return RoutingDecision(
                    selection: .mlx(repoID: largestMLX.repoID),
                    reason: why + "for now \(largestMLX.displayName), "
                        + "your biggest local model, stands in.",
                    note: cloudNote)
            }
            return RoutingDecision(
                selection: .onDevice,
                reason: why + "for now Apple On-Device does its best.",
                note: cloudNote)
        }
    }
}
