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
        // Audit B-50: the timeout must actually BOUND this call.
        // A task group can't do that — `withTaskGroup` implicitly
        // awaits ALL children before returning, and `cancelAll()`
        // only *requests* cancellation, so a framework call that
        // ignores cancellation kept `classify()` blocked for its
        // full duration despite the timer "winning". The race below
        // runs the classification in a DETACHED task and returns
        // when the timer wins, without awaiting the loser.
        //
        // Cancellation uncertainty, noted honestly: whether
        // `LanguageModelSession.respond` aborts promptly when its
        // task is cancelled is framework behaviour this code can't
        // control — which is exactly why the loser is not awaited.
        // The abandoned call runs on a throwaway session and
        // touches no shared state, so letting it finish (or fail)
        // in the background is harmless; its verdict is discarded.
        return await TimeoutRace.run(timeoutSeconds: timeoutSeconds) {
            await runClassification(prompt: prompt)
        } ?? nil
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

/// Audit B-50: a timeout race whose deadline is a HARD bound.
///
/// The operation runs in a detached unstructured task; a timer task
/// races it to resume the continuation. Whichever resumes first
/// wins, and the loser is NOT awaited — that is the whole point
/// (a task group's implicit await-all was the B-50 bug). Pure
/// Swift concurrency with no framework dependency, so the race
/// semantics themselves are unit-testable with async sleeps.
enum TimeoutRace {

    /// Runs `operation`, returning its value — or nil when
    /// `timeoutSeconds` elapse first. A nil result from the
    /// operation itself is indistinguishable from a timeout,
    /// which is precisely the fallback semantics the classifier
    /// wants ("no verdict in time" and "no verdict" both fall
    /// back the same way).
    static func run<T: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = ResumeGate<T>()
        return await withCheckedContinuation { continuation in
            gate.attach(continuation)
            Task.detached {
                let value = await operation()
                gate.resume(with: value)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                gate.resume(with: nil)
            }
        }
    }

    /// Exactly-once resumption across the two racing tasks.
    private final class ResumeGate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var resumed = false

        func attach(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(with value: T?) {
            lock.lock()
            guard !resumed, let continuation else {
                lock.unlock()
                return
            }
            resumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }
    }
}
