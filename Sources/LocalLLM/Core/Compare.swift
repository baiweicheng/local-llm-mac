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

/// UAT-01: compare-mode honesty notes. A column is headed by the
/// model the user PICKED, but the shared factory can resolve that
/// pick to a different backend (Local Only refuses the cloud, an
/// OpenRouter pick has no key yet, a model was removed) — in chat,
/// the engine banners exactly that switch; compare originally said
/// nothing, so a local answer could appear under a cloud header
/// and two "different" columns could be the same model. These
/// pure wordings are what the column shows instead: before a run,
/// why a pick can't run at all; after a run, which backend
/// actually answered.
enum CompareNotices {

    /// The note under a column whose pick can't run right now —
    /// shown before any run, and the reason "Ask both" stays off
    /// for that column. (Readiness itself comes from the picker
    /// descriptors, the same source chat's send gate uses.)
    static func unavailableNote(for selection: ModelSelection) -> String {
        switch selection {
        case .openRouter:
            return "Needs your OpenRouter key first — add it in "
                + "Settings → Cloud models, or pick another model "
                + "for this column."
        case .privateCloudCompute:
            return "Apple Private Cloud isn't available on this "
                + "Mac right now — pick another model for this column."
        case .onDevice:
            return "The built-in model isn't ready right now — "
                + "pick another model for this column."
        case .auto, .mlx, .endpoint:
            return "This model isn't available right now — pick "
                + "another one for this column."
        }
    }

    /// The note a column shows after a run when the backend that
    /// answered differs from the one picked: it names BOTH, so the
    /// answer is never read as coming from the picked model.
    /// Nil when the pick ran as picked.
    static func fallbackNotice(pickedSelection: ModelSelection,
                               effectiveSelection: ModelSelection,
                               pickedName: String,
                               effectiveName: String) -> String? {
        guard pickedSelection != effectiveSelection else { return nil }
        return "You picked \(pickedName), but it isn't available "
            + "right now — \(effectiveName) answered this column "
            + "instead."
    }
}
