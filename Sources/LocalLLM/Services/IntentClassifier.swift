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
        // Review finding 20: the loser IS cancelled now (and a
        // cancelled parent send cancels the classification too),
        // so cooperative model work stops instead of running on
        // after the chat starts; only a framework call that ignores
        // cancellation can outlive the race, on a throwaway session
        // that touches no shared state, and its verdict is discarded.
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
///
/// Review finding 20: the B-50 shape kept NO handles and cancelled
/// NEITHER task, so a slow classification kept using the on-device
/// model after the chat had already started (and a stopped send
/// did not stop it). This shape retains both tasks and cancels
/// the loser on every exit path: timer wins → the operation is
/// cancelled; operation wins → the timer is cancelled; the
/// parent is cancelled → both are cancelled and the race returns
/// nil. The loser is still NOT awaited — cancelling cooperative
/// work stops it promptly, but waiting for an uncooperative loser
/// (a framework call that ignores cancellation) would reintroduce
/// exactly the unbounded wait B-50 removed, so the race returns
/// at its deadline regardless and the loser's verdict is discarded.
enum TimeoutRace {

    /// Runs `operation`, returning its value — or nil when
    /// `timeoutSeconds` elapse first, or when the awaiting task is
    /// cancelled. A nil result from the operation itself is
    /// indistinguishable from a timeout, which is precisely the
    /// fallback semantics the classifier wants ("no verdict in
    /// time" and "no verdict" both fall back the same way).
    static func run<T: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = RaceGate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                gate.operationTask = Task.detached {
                    let value = await operation()
                    gate.win(with: value)
                }
                gate.timerTask = Task.detached {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    gate.win(with: nil)
                }
                gate.cancelIfParentCancelled()
            }
        } onCancel: {
            gate.cancelAll()
        }
    }

    /// Exactly-once resumption across the two racing tasks, plus
    /// the retained task handles finding 20 requires. Cancellation
    /// is cooperative and never kills a task outright, so cancelling
    /// a task that already finished (the winner, or a timer that
    /// already fired) is a harmless no-op — `win` therefore cancels
    /// BOTH handles rather than trying to identify the loser.
    private final class RaceGate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var finished = false
        /// Set before `attach` returns; `cancelAll` from the parent
        /// may run before either task is stored, so it must not
        /// depend on the handles already existing.
        private var parentCancelled = false
        var operationTask: Task<Void, Never>?
        var timerTask: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            // The parent was already cancelled while this race was
            // being set up: resume immediately instead of parking a
            // continuation nothing will ever resume, and mark the
            // race finished so a later `win` cannot resume it again
            // (a double resume traps a checked continuation).
            // The tasks themselves are cancelled by
            // `cancelIfParentCancelled`, called once they exist.
            if parentCancelled {
                finished = true
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        /// Called once both task handles exist: if the parent was
        /// already cancelled (so `attach` resumed immediately),
        /// cancel the just-created tasks too — otherwise they
        /// would run uncancelled behind an already-returned race.
        func cancelIfParentCancelled() {
            lock.lock()
            guard parentCancelled else {
                lock.unlock()
                return
            }
            let operationTask = self.operationTask
            let timerTask = self.timerTask
            lock.unlock()
            operationTask?.cancel()
            timerTask?.cancel()
        }

        func win(with value: T?) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            let operationTask = self.operationTask
            let timerTask = self.timerTask
            lock.unlock()
            operationTask?.cancel()
            timerTask?.cancel()
            continuation.resume(returning: value)
        }

        func cancelAll() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            parentCancelled = true
            let continuation = self.continuation
            self.continuation = nil
            let operationTask = self.operationTask
            let timerTask = self.timerTask
            lock.unlock()
            operationTask?.cancel()
            timerTask?.cancel()
            continuation?.resume(returning: nil)
        }
    }
}
