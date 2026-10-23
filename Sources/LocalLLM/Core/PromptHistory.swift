import Foundation

/// One conversational turn, detached from storage — the shape the prompt
/// assembly logic works with.
struct ChatTurn: Equatable, Sendable {
    let role: MessageRole
    let text: String
}

/// Pure prompt/history helpers, kept free of any UI or model calls so they
/// can be unit-tested on their own.
///
/// Phase 1 note: each conversation keeps one live `LanguageModelSession`
/// while the app is running, so the model remembers the conversation
/// natively. After an app relaunch, a reopened conversation starts a fresh
/// session and the earlier turns are handed to it as a short written recap
/// on the first new prompt (`recap(of:)`). Phase 2 replaces this with real
/// context-window management (counting, summarizing, compacting).
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

    /// Estimated tokens for a whole conversation: instructions plus turns.
    static func estimatedContextTokens(instructions: String, turns: [ChatTurn]) -> Int {
        var total = approximateTokenCount(for: instructions)
        for turn in turns {
            total += approximateTokenCount(for: turn.text)
        }
        return total
    }

    /// The on-device model's documented context window (instructions +
    /// conversation share it).
    static let contextWindowTokens = 4_096

    /// A plain-text recap of earlier turns, prepended to the first prompt
    /// of a freshly created session so a reopened chat keeps its thread.
    /// Returns nil when there is nothing worth recapping.
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

    /// The exact prompt to send the model: the recap (when this session is
    /// new and there is history) followed by the user's actual words.
    static func promptForModel(userText: String, priorTurns: [ChatTurn], sessionIsFresh: Bool) -> String {
        guard sessionIsFresh, let recap = recap(of: priorTurns) else {
            return userText
        }
        return recap + "\n" + userText
    }
}
