import Foundation

/// Phase 8: the cloud tier's pure core — the curated OpenRouter
/// catalog and the usage reports its replies carry back.
///
/// THE CATALOG (checked 2026-10-23 against OpenRouter's own live
/// model list, https://openrouter.ai/api/v1/models — every id below
/// was read from that response, not remembered): the user's standing
/// rule is to pick from the LATEST generation, so these are the
/// current flagships of each family as listed that day:
///
/// - Anthropic: Claude Opus 5.5 (flagship, Sep 2026) and Sonnet 5.5.
/// - OpenAI: GPT-6 Astra (flagship, Sep 2026) and GPT-6.1 Sol.
/// - Google: Gemini 3.8 Flash — Google's most capable model on
///   OpenRouter at check time (there was no 3.x Pro text model
///   listed; the Flash tier is the current top there).
/// - Open weights: Moonshot's Kimi K3.1 Pro, the flagship
///   open-weight model (listed the same week).
///
/// Order in the list is preference order: `best` (the first entry)
/// is what Auto routes a cloud-worthy prompt to when a key exists.
/// Any other model on OpenRouter remains reachable through the
/// custom model id in Settings — the catalog is a shortlist, not a
/// fence. Re-check the list before changing it; ids go stale.
struct OpenRouterModelInfo: Equatable, Sendable, Identifiable {
    /// The exact model id OpenRouter expects, e.g.
    /// "anthropic/claude-opus-5.5".
    let modelID: String
    /// Plain display name for the picker, e.g. "Claude Opus 5.5".
    let displayName: String
    /// One plain-English line on what this pick is for.
    let note: String

    var id: String { modelID }
}

enum OpenRouterCatalog {

    /// The curated shortlist, best first.
    static let models: [OpenRouterModelInfo] = [
        OpenRouterModelInfo(
            modelID: "anthropic/claude-opus-5.5",
            displayName: "Claude Opus 5.5",
            note: "Anthropic's flagship — the strongest all-round "
                + "cloud pick in this list."),
        OpenRouterModelInfo(
            modelID: "anthropic/claude-sonnet-5.5",
            displayName: "Claude Sonnet 5.5",
            note: "Anthropic's everyday frontier model — nearly as "
                + "strong as Opus, faster and cheaper."),
        OpenRouterModelInfo(
            modelID: "openai/gpt-6-astra",
            displayName: "GPT-6 Astra",
            note: "OpenAI's flagship, for demanding end-to-end work."),
        OpenRouterModelInfo(
            modelID: "openai/gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            note: "OpenAI's high-end workhorse, one step below Astra."),
        OpenRouterModelInfo(
            modelID: "google/gemini-3.8-flash",
            displayName: "Gemini 3.8 Flash",
            note: "Google's most capable model on OpenRouter right "
                + "now — the fast Flash tier."),
        OpenRouterModelInfo(
            modelID: "moonshotai/kimi-k3.1-pro",
            displayName: "Kimi K3.1 Pro",
            note: "Moonshot AI's flagship open-weight model."),
    ]

    /// The model Auto prefers for a cloud-worthy prompt when an
    /// OpenRouter key exists: the head of the curated list.
    static var best: OpenRouterModelInfo { models[0] }

    /// The curated entry for a model id, or nil when the id is a
    /// custom one the user typed (or a model added since).
    static func info(forModelID modelID: String) -> OpenRouterModelInfo? {
        models.first { $0.modelID == modelID }
    }

    /// The display name for any OpenRouter model id: the curated
    /// name when known, otherwise the id itself (a custom model is
    /// most honestly labeled by the id the user chose).
    static func displayName(forModelID modelID: String) -> String {
        info(forModelID: modelID)?.displayName ?? modelID
    }

    /// The OpenRouter chat-completions endpoint (fixed — OpenRouter
    /// is one service, not a user-configured server).
    static let chatCompletionsURL = URL(
        string: "https://openrouter.ai/api/v1/chat/completions")!
}

/// What one cloud reply actually used and cost, as reported by
/// OpenRouter in the stream's final chunk when usage accounting is
/// requested (the app always requests it — see
/// `OpenAIRequestBuilder`). Every field is optional because a
/// provider may report tokens without a cost, or nothing at all;
/// the telemetry pill shows "cost unknown" rather than inventing a
/// number when `costUSD` is nil.
struct UsageReport: Equatable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    /// The real charge for the reply, in US dollars, when the
    /// provider reported one.
    let costUSD: Double?

    /// Extracts the report from one SSE data payload. Returns nil
    /// unless the payload is a JSON object carrying a `usage` object
    /// with at least one recognizable number in it — content chunks,
    /// role announcements, and malformed lines are not reports.
    static func parse(payload: String) -> UsageReport? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let usage = dictionary["usage"] as? [String: Any] else {
            return nil
        }
        let report = UsageReport(
            promptTokens: (usage["prompt_tokens"] as? NSNumber)?.intValue,
            completionTokens: (usage["completion_tokens"] as? NSNumber)?.intValue,
            totalTokens: (usage["total_tokens"] as? NSNumber)?.intValue,
            costUSD: (usage["cost"] as? NSNumber)?.doubleValue)
        guard report.promptTokens != nil || report.completionTokens != nil
                || report.totalTokens != nil || report.costUSD != nil else {
            return nil
        }
        return report
    }
}
