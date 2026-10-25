import Foundation

/// One conversational turn, detached from storage — the shape the prompt
/// assembly logic works with.
struct ChatTurn: Equatable, Sendable {
    let role: MessageRole
    let text: String
    /// How many images this turn carried (their content is not part of
    /// the turn — old turns' images are never re-sent, but they still
    /// count when estimating what a context cost).
    var attachmentCount: Int = 0
}

/// Pure prompt/history helpers, kept free of any UI or model calls so they
/// can be unit-tested on their own.
///
/// Phase 2 note: each conversation keeps one live `LanguageModelSession`
/// while the app is running, so the model remembers the conversation
/// natively. Real context management — counting, and summarizing older
/// turns when the window fills — lives in `ContextManager`; this file
/// keeps the basic building blocks (instructions merge, token estimate,
/// and the plain recap used to seed a fresh session when nothing has
/// been summarized yet).
enum PromptHistory {

    /// Instructions every session starts from when a chat has none of its
    /// own. Honest about what the small on-device model is good at.
    static let defaultInstructions = """
        You are a helpful assistant running entirely on this Mac. \
        Answer clearly and directly. If you don't know something, say so \
        instead of guessing. Keep answers as short as the question allows.
        """

    /// The instructions a session should use: the chat's own text if it has
    /// any, otherwise the built-in default.
    static func mergedInstructions(userInstructions: String) -> String {
        let trimmed = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultInstructions : trimmed
    }

    /// A rough token estimate — about 4 characters per token for English
    /// text. This is a planning aid for the UI's context meter, NOT the
    /// model's real tokenizer count.
    static func approximateTokenCount(for text: String) -> Int {
        if text.isEmpty { return 0 }
        return max(1, text.count / 4)
    }

    /// Estimated tokens for a whole conversation: instructions plus
    /// turns, counting a flat allowance for each attached image.
    /// Review finding 12: `overheadTokens` is the rest of the actual
    /// prompt (see `ContextManager.planningOverheadTokens`) — the
    /// context meter passes transcript framing, so the meter no
    /// longer reports a number that ignores part of the prompt.
    static func estimatedContextTokens(instructions: String, turns: [ChatTurn],
                                       overheadTokens: Int = 0) -> Int {
        var total = approximateTokenCount(for: instructions) + overheadTokens
        for turn in turns {
            total += approximateTokenCount(for: turn.text)
            total += turn.attachmentCount * ImageAttachmentCodec.estimatedTokensPerImage
        }
        return total
    }

    /// A plain-text recap of earlier turns. Phase 2's `ContextManager`
    /// uses it as the seed for a freshly created session when the chat
    /// has history but nothing has been summarized yet — a reopened chat
    /// keeps its thread. Returns nil when there is nothing to recap.
    /// (The on-device model's context window itself lives in
    /// `ContextBudget` now.)
    static func recap(of turns: [ChatTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        var lines = ["Earlier in this conversation:"]
        for turn in turns {
            let speaker = turn.role == .user ? "User" : "Assistant"
            lines.append("\(speaker): \(turn.text)")
        }
        lines.append("")
        lines.append("Continuing from that conversation, here is the latest message:")
        return lines.joined(separator: "\n")
    }
}
