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

    /// Review finding 12: tokens for the fixed wording wrapped
    /// around a rebuilt session's seed ("Summary of the earlier
    /// part…", "Most recent messages:", speaker labels). Small,
    /// but the old planner counted none of it — one more part of
    /// the actual prompt the meter said fit.
    static let transcriptFramingTokens = 64

    /// Review finding 12: estimated tokens for ONE tool's argument
    /// schema in the serialized prompt. Framework tools expose the
    /// full shared 14-field `ToolCallArguments` schema for every
    /// tool (field names plus their guide descriptions run to
    /// roughly 880 characters, ~220 tokens at the app's 4-chars-per
    /// token estimate); MCP tools carry their own JSON schema of
    /// comparable size. An estimate, like all the app's token math
    /// — but counting zero schemas per tool, as the old planner
    /// did, understated a 23-tool session by thousands of tokens.
    static let toolSchemaTokensPerTool = 220

    /// Review finding 12: allowance for what stored messages cannot
    /// show — a tool-capable session's retained tool calls and
    /// results, plus session framing. Only applied when tools are
    /// actually bound; the engine cannot measure the session's
    /// native tool history from stored state, so this is a
    /// reserve, not a measurement, and it is named as one.
    static let toolSessionAllowanceTokens = 256

    /// Review finding 12: the complete overhead for one planned
    /// send — everything the actual prompt carries beyond
    /// instructions, summary, live turns, and the new prompt:
    /// transcript framing, every bound tool's schema, the
    /// tool-session allowance, the approval-outcome note, and the
    /// quick-panel (HUD) prompt prefix, when each is present.
    /// The engine passes this into `plan(overheadTokens:)`; a
    /// caller that passes nothing still gets the old
    /// instructions+summary+turns+prompt math (the default keeps
    /// existing tests' exact projections intact).
    static func planningOverheadTokens(toolCount: Int,
                                       outcomeNote: String?,
                                       promptPrefix: String?,
                                       hasTools: Bool) -> Int {
        var total = transcriptFramingTokens
        total += toolCount * toolSchemaTokensPerTool
        if hasTools { total += toolSessionAllowanceTokens }
        if let outcomeNote { total += PromptHistory.approximateTokenCount(for: outcomeNote) }
        if let promptPrefix { total += PromptHistory.approximateTokenCount(for: promptPrefix) }
        return total
    }

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
    ///   - overheadTokens: review finding 12 — the rest of the
    ///     actual prompt (see `planningOverheadTokens`): tool
    ///     schemas, retained tool traffic, approval outcome notes,
    ///     HUD context, transcript framing. Counted in BOTH the
    ///     fits check and the projection, so a prompt that only
    ///     fits by ignoring its schemas no longer plans as fitting.
    static func plan(budget: ContextBudget,
                     instructions: String,
                     existingSummary: String?,
                     liveTurns: [ChatTurn],
                     newPrompt: ChatTurn,
                     overheadTokens: Int = 0) -> CompactionPlan {
        let instructionsTokens = PromptHistory.approximateTokenCount(for: instructions)
        let summaryTokens = existingSummary.map {
            PromptHistory.approximateTokenCount(for: $0)
        } ?? 0
        let promptTokens = tokens(for: newPrompt)
        let turnTokens = liveTurns.map { tokens(for: $0) }
        let totalTokens = instructionsTokens + summaryTokens
            + turnTokens.reduce(0, +) + promptTokens + overheadTokens

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
            + overheadTokens
        let recentAllowance = budget.promptAllowanceTokens - fixedTokens

        // Pick the longest suffix of whole exchanges that fits alongside
        // the fixed parts. Candidate suffixes start at user turns;
        // scanning from the oldest candidate gives the longest fit.
        // Audit E-07: suffix sums are computed ONCE, in a single
        // pass from the end — the old loop re-summed the suffix
        // from scratch for every user-turn candidate, O(u·n) adds
        // per plan, and planning runs up to four times per send.
        let suffixTokens = suffixSums(turnTokens)
        var suffixStart: Int? = nil
        for candidate in liveTurns.indices where liveTurns[candidate].role == .user {
            if suffixTokens[candidate] <= recentAllowance {
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
            // `toSummarize` is a prefix of `liveTurns`, so its
            // costs are `turnTokens`' prefix — reuse them (E-07).
            for cost in turnTokens.prefix(toSummarize.count) {
                if kept > 0, used + cost > summarizerAllowance { break }
                used += cost
                kept += 1
            }
            // Audit B-15: the cap is a token budget, but the plan's
            // contract is whole exchanges. Round the cut DOWN to the
            // preceding user-turn boundary, so `recentTurns` still
            // starts at a user turn instead of mid-exchange. (A cut
            // that would summarize nothing at all keeps the plain
            // token cut — a summary pass still has to happen.)
            if kept > 0, kept < liveTurns.count {
                var rounded = kept
                while rounded > 0, liveTurns[rounded].role != .user {
                    rounded -= 1
                }
                if rounded > 0 { kept = rounded }
            }
            toSummarize = Array(toSummarize.prefix(kept))
        }

        let recent = Array(liveTurns.dropFirst(toSummarize.count))
        // Audit E-07: the projection reuses `turnTokens` (the
        // counts this plan already computed) instead of recounting
        // every recent turn's text a second time.
        let recentTokens = turnTokens.dropFirst(toSummarize.count)
            .reduce(0, +)
        let projected = instructionsTokens + summaryAllowance
            + recentTokens + promptTokens + overheadTokens
        return CompactionPlan(
            needsCompaction: !toSummarize.isEmpty,
            turnsToSummarize: toSummarize,
            recentTurns: recent,
            overflowWarning: projected > budget.promptAllowanceTokens,
            projectedTokens: projected)
    }

    /// Suffix sums of per-turn token counts (audit E-07):
    /// `result[i]` is the total tokens of turns `i...`, computed in
    /// one pass from the end. Pure, and pinned by tests — the
    /// planning loop above used to recompute these per candidate.
    static func suffixSums(_ turnTokens: [Int]) -> [Int] {
        var result = [Int](repeating: 0, count: turnTokens.count)
        var running = 0
        for index in turnTokens.indices.reversed() {
            running += turnTokens[index]
            result[index] = running
        }
        return result
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
    ///
    /// Review finding 13: the result is BOUNDED by `maxTokens`.
    /// The old form appended each new note to the ENTIRE previous
    /// summary with no limit, so a summary that kept failing grew
    /// until it consumed the summarizer's own allowance and made
    /// every later summarization fail too. Now, when the merged
    /// text would exceed the cap, the older part of the existing
    /// summary is trimmed (from the front — the note about the
    /// just-folded turns is always kept whole) and the trim is
    /// marked, so the summary can never grow past the cap through
    /// this path. The default matches the largest summary target
    /// any budget allows; the engine passes its backend's target.
    static func mechanicalFallbackSummary(existing: String?,
                                          droppedTurns: [ChatTurn],
                                          maxTokens: Int = 2_000) -> String {
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
        let merged = mergedSummary(existing: existing, new: note)
        guard PromptHistory.approximateTokenCount(for: merged) > maxTokens,
              let existing, !existing.isEmpty else { return merged }
        // Room for the existing part, in characters, after the note,
        // the separator, and the trim marker: the note is never cut.
        let marker = "[earlier summary trimmed to fit] "
        let allowedChars = max(0, maxTokens * 4 - note.count - 1 - marker.count)
        guard allowedChars > 0 else { return note }
        var kept = String(existing.suffix(allowedChars))
        // Don't start mid-word: drop the partial first word, unless
        // that would leave nothing.
        if kept.count < existing.count,
           let firstSpace = kept.firstIndex(of: " ") {
            let trimmed = String(kept[kept.index(after: firstSpace)...])
            if !trimmed.isEmpty { kept = trimmed }
        }
        return marker + kept + "\n" + note
    }

    /// Review finding 13: a HARD cap on a summary's size, applied
    /// to what the summarizer actually returned — not just the
    /// "at most about N words" instruction in `summarizerInput`,
    /// which a model may exceed. The engine caps every summary
    /// (model-produced or fallback) to its backend's target before
    /// storing it, so a too-long summary cannot eat the next pass's
    /// allowance. The cut is at a word boundary and marked, so the
    /// truncation is visible in the stored summary rather than
    /// silently mid-sentence.
    static func cappedSummary(_ text: String, maxTokens: Int) -> String {
        guard PromptHistory.approximateTokenCount(for: text) > maxTokens else {
            return text
        }
        let marker = "… [summary trimmed to fit]"
        let allowedChars = max(0, maxTokens * 4 - marker.count)
        var kept = String(text.prefix(allowedChars))
        if let lastSpace = kept.lastIndex(of: " ") {
            kept = String(kept[..<lastSpace])
        }
        return kept + marker
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
