import Foundation
import FoundationModels

// ============================================================
//  THE ONLY FILE THAT KNOWS HOW CLASSIFICATION TALKS TO THE MODEL.
//
//  Every model-facing symbol for Phase 4's triage lives here — the
//  `@Generable` verdict type and the `respond(to:generating:)` call —
//  so if a symbol needs adjusting at first compile, the fix is
//  contained to this one file. Everything downstream (the engine,
//  `RoutingPolicy`) only ever sees a `PromptIntent` value, or nil.
//
//  How it works: before a message in an Auto chat is sent, a
//  throwaway on-device session sorts the prompt into one of four
//  categories. The classifier is a hint, not a jailer — if the model
//  is unavailable, the call fails, an answer doesn't parse, or it
//  takes too long, this returns nil and the engine falls back to
//  treating the message as a quick transform on the built-in model.
//  Classification never blocks a send.
// ============================================================

/// The classifier's structured answer. Deliberately minimal — one
/// string field — because the built-in model's 4,096-token window is
/// shared between instructions, schema, and prompt, and this call is
/// supposed to be cheap. The raw-value strings are `PromptIntent`'s.
@Generable
struct PromptIntentVerdict {
    @Guide(description: "The category: os_action, quick_transform, local_heavy, or frontier_cloud")
    var category: String
}

enum IntentClassifier {

    /// Instructions for the throwaway classification session. Kept as
    /// small as they can be while still drawing the four lines clearly
    /// — every token here is a token the actual chat can't use.
    static let instructions = """
        You sort one user message into exactly one category.
        os_action: they want something done on their Mac — files, photos, calendar, apps, settings.
        quick_transform: a quick edit (summarize, rewrite, reformat, translate) or a short, simple question.
        local_heavy: hard work that should stay on this Mac — writing or debugging code, long analysis, math.
        frontier_cloud: needs the newest, most capable AI model — very hard reasoning, or broad up-to-the-minute world knowledge.
        Answer with the category only.
        """

    /// How much of the prompt the classifier reads. Classification
    /// judges intent, not content — the opening is plenty, and capping
    /// it keeps the call cheap on a long paste.
    static let promptExcerptLimit = 600

    /// How long classification may take before the engine stops
    /// waiting and routes by the fallback instead. Generous against
    /// the brief's ~150 ms ambition (first-call model warm-up is real)
    /// while still never holding a send hostage.
    static let timeoutSeconds: TimeInterval = 5

    /// Classifies one outgoing prompt, or returns nil when no verdict
    /// arrived in time (model unavailable, failure, bad answer). A nil
    /// verdict is normal operation — the caller falls back.
    static func classify(prompt: String) async -> PromptIntent? {
        guard ModelAvailabilityState.current.canChat else { return nil }
        return await withTaskGroup(of: PromptIntent?.self) { group in
            group.addTask {
                await runClassification(prompt: prompt)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            // Whichever finishes first wins; a timeout verdict of nil
            // is indistinguishable from a failed classification, and
            // both mean "fall back" to the caller.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// One classification attempt on a fresh session: the session is
    /// thrown away afterwards, so no chat state ever leaks into (or
    /// out of) routing.
    private static func runClassification(prompt: String) async -> PromptIntent? {
        let excerpt = String(prompt.prefix(promptExcerptLimit))
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: excerpt, generating: PromptIntentVerdict.self)
            let raw = response.content.category
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return PromptIntent(rawValue: raw)
        } catch {
            return nil
        }
    }
}
