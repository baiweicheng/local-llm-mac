import Foundation

/// Phase 8: compare mode's pure core — how a finished side-by-side
/// answer becomes a normal conversation.
///
/// Compare itself is deliberately one-shot (see `CompareView`): one
/// prompt, two backends, two streamed answers, no tools and no
/// context compaction. "Continue with this one" is the bridge back
/// to the real thing: the chosen exchange is seeded into an ordinary
/// `Conversation` on the chosen backend, so the follow-up chat gets
/// the full engine — sessions, compaction, tools where the backend
/// supports them — with the compared question and answer as its
/// first two messages.
enum CompareSeeding {

    /// Everything needed to create the seeded conversation.
    struct Seed: Equatable, Sendable {
        /// The sidebar title: the prompt's opening, the same way the
        /// engine titles a new chat.
        let title: String
        let userText: String
        let assistantText: String
        /// The backend the winning column ran on — the new chat
        /// keeps chatting with it.
        let selection: ModelSelection
    }

    static func seed(prompt: String, answer: String,
                     selection: ModelSelection) -> Seed {
        let trimmedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let title = trimmedPrompt.isEmpty
            ? "Comparison"
            : String(trimmedPrompt.prefix(48))
        return Seed(title: title,
                    userText: trimmedPrompt,
                    assistantText: answer.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    selection: selection)
    }

    /// Whether a finished column may be continued with: it needs a
    /// real answer (not an error, not an empty reply).
    static func canContinue(answer: String) -> Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
