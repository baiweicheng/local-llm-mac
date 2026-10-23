import Foundation

/// The result of planning one send: does this conversation need
/// compacting first, and if so, which turns get folded into the summary
/// and which stay verbatim?
struct CompactionPlan: Equatable, Sendable {
    /// True when the oldest turns must be summarized before sending.
    let needsCompaction: Bool
    /// The oldest live turns to fold into the summary, in order. Always a
    /// prefix of the live turns, and capped so the summarizer's own input
    /// fits the window too (the engine may run several passes).
    let turnsToSummarize: [ChatTurn]
    /// The turns that stay verbatim — everything not summarized in this
    /// pass. Planning aims for this to start at a user turn, so the kept
    /// history is whole exchanges, never a split pair.
    let recentTurns: [ChatTurn]
    /// True when even the smallest sendable context is estimated to
    /// exceed the budget — the send proceeds anyway (best effort) and the
    /// framework's own error, if any, is what the user sees.
    let overflowWarning: Bool
    /// Estimated prompt tokens after this plan (instructions + summary
    /// allowance + recent turns + the new prompt).
    let projectedTokens: Int
}

/// Pure context-window planning and summary text handling for Phase 2.
///
/// The engine (`ChatEngine`) owns the actual model calls; everything that
/// can be decided without the model is decided here, so the behavior is
/// unit-testable: budget math, which turns get summarized, how summaries
/// merge, and what a rebuilt session is seeded with.
///
/// How compaction works, in one paragraph: a conversation's stored
/// messages are never deleted. The oldest ones get folded into a running
/// summary (stored on the conversation) by asking the on-device model to
/// condense them; the session the model actually talks to is rebuilt as
/// [instructions + summary + most recent turns verbatim]. Instructions
/// are never summarized away. Compaction is idempotent-ish: the next
/// round folds the running summary plus the next-oldest turns into a new
/// summary.
enum ContextManager {

    // MARK: - Planning

    /// Decides whether the live turns still fit, and what to compact if
    /// they don't.
    ///
    /// - Parameters:
    ///   - budget: the backend's context budget.
    ///   - instructions: the session instructions in force (never
    ///     compacted, always counted).
    ///   - existingSummary: the running summary of already-folded turns,
    ///     if any (counted, and merged into on the next round).
    ///   - liveTurns: stored turns NOT yet folded into the summary,
    ///     oldest first, EXCLUDING the message about to be sent.
    ///   - newPrompt: the message about to be sent.
    static func plan(budget: ContextBudget,
                     instructions: String,
                     existingSummary: String?,
                     liveTurns: [ChatTurn],
                     newPrompt: ChatTurn) -> CompactionPlan {
        let instructionsTokens = PromptHistory.approximateTokenCount(for: instructions)
        let summaryTokens = existingSummary.map {
            PromptHistory.approximateTokenCount(for: $0)
        } ?? 0
        let promptTokens = tokens(for: newPrompt)
        let turnTokens = liveTurns.map { tokens(for: $0) }
        let totalTokens = instructionsTokens + summaryTokens
            + turnTokens.reduce(0, +) + promptTokens

        guard totalTokens > budget.promptAllowanceTokens else {
            return CompactionPlan(needsCompaction: false,
                                  turnsToSummarize: [],
                                  recentTurns: liveTurns,
                                  overflowWarning: false,
                                  projectedTokens: totalTokens)
        }

        // Room the post-compaction summary may take: what exists, but at
        // least the budget's target (a fresh summary needs space to land).
        let summaryAllowance = max(summaryTokens, budget.summaryTargetTokens)
        let fixedTokens = instructionsTokens + summaryAllowance + promptTokens
        let recentAllowance = budget.promptAllowanceTokens - fixedTokens

        // Pick the longest suffix of whole exchanges that fits alongside
        // the fixed parts. Candidate suffixes start at user turns;
        // scanning from the oldest candidate gives the longest fit.
        var suffixStart: Int? = nil
        for candidate in liveTurns.indices where liveTurns[candidate].role == .user {
            if turnTokens[candidate...].reduce(0, +) <= recentAllowance {
                suffixStart = candidate
                break
            }
        }
        if suffixStart == nil {
            // Not even the latest exchange fits alongside the fixed
            // parts. Aim to keep it anyway — a best-effort send beats
            // dropping the user's most recent context — and let the
            // projection below flag the overflow.
            suffixStart = liveTurns.lastIndex(where: { $0.role == .user }) ?? 0
        }
        let idealRecentStart = suffixStart ?? 0

        // The summarizer reads its input through the same window: cap
        // one pass to the oldest turns that fit, keeping at least one.
        // The engine repeats the pass if a huge history needs several;
        // turns a capped pass leaves behind simply stay verbatim in
        // `recentTurns` below until their pass runs.
        var toSummarize = Array(liveTurns[..<idealRecentStart])
        let summarizerAllowance = budget.promptAllowanceTokens
            - summaryTokens - summarizerOverheadTokens
        if toSummarize.count > 1 {
            var used = 0
            var kept = 0
            for turn in toSummarize {
                let cost = tokens(for: turn)
                if kept > 0, used + cost > summarizerAllowance { break }
                used += cost
                kept += 1
            }
            toSummarize = Array(toSummarize.prefix(kept))
        }

        let recent = Array(liveTurns.dropFirst(toSummarize.count))
        let projected = instructionsTokens + summaryAllowance
            + recent.map { tokens(for: $0) }.reduce(0, +) + promptTokens
        return CompactionPlan(
            needsCompaction: !toSummarize.isEmpty,
            turnsToSummarize: toSummarize,
            recentTurns: recent,
            overflowWarning: projected > budget.promptAllowanceTokens,
            projectedTokens: projected)
    }

    /// Estimated tokens for one turn: its text plus a flat allowance per
    /// attached image.
    static func tokens(for turn: ChatTurn) -> Int {
        PromptHistory.approximateTokenCount(for: turn.text)
            + turn.attachmentCount * ImageAttachmentCodec.estimatedTokensPerImage
    }

    /// Rough size of the fixed wording wrapped around a summarizer call,
    /// so planning can reserve room for it.
    static let summarizerOverheadTokens = 220

    // MARK: - Summarizing

    /// Instructions for the throwaway session that condenses history.
    /// Deliberately separate from the chat's own instructions — "answer
    /// like a pirate" must not leak into the record of what happened.
    static let summarizerInstructions = """
        You condense conversation history into brief, faithful summaries. \
        You keep facts, names, numbers, decisions, and preferences. You \
        never answer questions or continue the conversation.
        """

    /// The prompt for one summarization pass: fold these turns into the
    /// running summary (if any) and return only the new summary.
    static func summarizerInput(existingSummary: String?,
                                turns: [ChatTurn],
                                targetTokens: Int) -> String {
        let targetWords = max(60, targetTokens * 3 / 4)
        var parts = ["""
            Rewrite the summary of this conversation so it includes the \
            newer messages below. Keep every fact, name, number, decision, \
            and preference that might matter later. Plain sentences, no \
            headings, no preamble — return only the summary, at most \
            about \(targetWords) words.
            """]
        if let existingSummary, !existingSummary.isEmpty {
            parts.append("Summary so far:\n\(existingSummary)")
        }
        parts.append("Newer messages to fold in:\n\(transcript(of: turns))")
        return parts.joined(separator: "\n\n")
    }

    /// Combines summaries when a pass is merged mechanically (and used
    /// by tests to pin the merge shape): existing text first, then new.
    static func mergedSummary(existing: String?, new: String) -> String {
        guard let existing, !existing.isEmpty else { return new }
        return existing + "\n" + new
    }

    /// The no-model fallback when a summarization call fails: the old
    /// turns are still folded away, but the "summary" only notes the
    /// topics they covered. Lossy, honest about it, and it keeps the
    /// conversation going instead of failing the send.
    static func mechanicalFallbackSummary(existing: String?,
                                          droppedTurns: [ChatTurn]) -> String {
        let topics = droppedTurns
            .filter { $0.role == .user }
            .prefix(5)
            .map { "\"\(String($0.text.prefix(60)))\"" }
        let note: String
        if topics.isEmpty {
            note = "Some earlier messages were trimmed to make room."
        } else {
            note = "Some earlier messages were trimmed to make room; "
                + "they covered: " + topics.joined(separator: ", ") + "."
        }
        return mergedSummary(existing: existing, new: note)
    }

    // MARK: - Seeding a rebuilt session

    /// The context text a fresh session is seeded with (as the first
    /// part of its first prompt): the summary of folded turns, then the
    /// turns still kept verbatim. Empty string when there is nothing to
    /// seed. The user's own words for the current message are appended
    /// by the caller.
    static func seedText(existingSummary: String?, recentTurns: [ChatTurn]) -> String {
        var parts: [String] = []
        if let existingSummary, !existingSummary.isEmpty {
            parts.append("""
                Summary of the earlier part of this conversation (older \
                messages were summarized to fit the model's memory):

                \(existingSummary)
                """)
            if !recentTurns.isEmpty {
                parts.append("Most recent messages:\n\(transcript(of: recentTurns))")
            }
        } else if !recentTurns.isEmpty,
                  let recap = PromptHistory.recap(of: recentTurns) {
            // No summary yet — Phase 1's recap is exactly the seed.
            parts.append(recap)
        }
        return parts.joined(separator: "\n\n")
    }

    /// "User: … / Assistant: …" lines for a set of turns. Turns that
    /// carried images say so — the images themselves are not re-sent for
    /// old turns (their token cost is why they were folded away).
    static func transcript(of turns: [ChatTurn]) -> String {
        turns.map { turn in
            let speaker = turn.role == .user ? "User" : "Assistant"
            var line = "\(speaker): \(turn.text)"
            if turn.attachmentCount > 0 {
                line += " [\(turn.attachmentCount) image(s) attached]"
            }
            return line
        }.joined(separator: "\n")
    }
}
