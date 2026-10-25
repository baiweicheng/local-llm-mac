import Foundation

/// Phase 7: the quick panel's captured context — pure data and pure
/// logic.
///
/// When the panel is summoned (⌘⇧Space), it quietly notes what the
/// user was in the middle of: which app is in front, what kind of
/// thing is on the clipboard, and which files Finder has selected.
/// Those facts render as small chips in the panel, and they're folded
/// into the outgoing prompt in plain language so "resize this" or
/// "summarize this" can mean the thing in front of the user.
///
/// The privacy shape is the Phase 5 shape, enforced HERE, in the pure
/// layer, so it can't be bypassed by a careless capture call:
///
/// - The clipboard's *kind* (text / image / something else) is always
///   fine to note — it's a type, not a content. The clipboard's actual
///   text is included ONLY when the Clipboard source toggle is on.
/// - Finder's selected paths are included ONLY when the Shared
///   folders (Files) source toggle is on.
/// - The frontmost app's name is not personal content — it's which
///   program the user is sitting in — and is always included.
///
/// `HUDContextCapture` (services) gathers the raw facts;
/// `make(...)` applies the purge rules above; everything the panel
/// shows and everything the prompt gains derives from the result.

// MARK: - Clipboard kind

/// What the clipboard currently holds, at the level of *kind* only.
enum HUDClipboardKind: String, Sendable, Equatable {
    case empty
    case text
    case image
    case other

    /// The chip wording for this kind (nil for empty — no chip).
    var chipText: String? {
        switch self {
        case .empty: return nil
        case .text: return "Clipboard: text"
        case .image: return "Clipboard: an image"
        case .other: return "Clipboard: something copied"
        }
    }
}

// MARK: - Snapshot

/// One captured moment, already purged by the toggle rules. The
/// panel renders `chips`; the send path folds `promptContextText()`
/// into the outgoing prompt (sent copy only — never a stored
/// message; see ChatEngine's prompt-prefix channel).
struct HUDContextSnapshot: Equatable, Sendable {
    var frontmostAppName: String?
    var clipboardKind: HUDClipboardKind
    /// The clipboard's text — non-nil ONLY when the Clipboard source
    /// is enabled and the clipboard actually holds text.
    var clipboardText: String?
    /// Finder's selected paths — non-empty ONLY when the Files
    /// source is enabled and Finder had a selection.
    var finderSelectionPaths: [String]
    /// Review finding 21: true when the Finder probe was DENIED
    /// Automation permission (as opposed to Finder having nothing
    /// selected, which leaves this false and the paths empty).
    /// Renders as its own chip so a denial never looks like an
    /// empty selection. Not folded into the prompt — it is a
    /// panel-state fact, not context for the model.
    var finderAutomationDenied: Bool = false

    static let empty = HUDContextSnapshot(frontmostAppName: nil,
                                          clipboardKind: .empty,
                                          clipboardText: nil,
                                          finderSelectionPaths: [])

    /// Builds a snapshot from raw probe results, applying the toggle
    /// rules: raw clipboard text is dropped unless the Clipboard
    /// source is on; raw Finder paths are dropped unless the Files
    /// source is on. The capture service may pass everything it
    /// found; what's kept is decided here, once.
    static func make(frontmostAppName: String?,
                     clipboardKind: HUDClipboardKind,
                     clipboardText: String?,
                     finderSelectionPaths: [String],
                     clipboardSourceEnabled: Bool,
                     filesSourceEnabled: Bool) -> HUDContextSnapshot {
        HUDContextSnapshot(
            frontmostAppName: frontmostAppName,
            clipboardKind: clipboardKind,
            clipboardText: (clipboardSourceEnabled
                            && clipboardKind == .text)
                ? clipboardText : nil,
            finderSelectionPaths: filesSourceEnabled
                ? finderSelectionPaths : [])
    }

    var hasAnyContext: Bool {
        frontmostAppName != nil || clipboardKind != .empty
            || !finderSelectionPaths.isEmpty
    }

    // MARK: Chips

    /// The small chips the panel shows: what was captured, in words,
    /// in display order (app, Finder, clipboard).
    var chips: [HUDContextChip] {
        var result: [HUDContextChip] = []
        if let app = frontmostAppName, !app.isEmpty {
            result.append(HUDContextChip(
                symbolName: "app.badge",
                text: app,
                helpText: "The app in front when you opened the quick panel"))
        }
        if !finderSelectionPaths.isEmpty {
            let count = finderSelectionPaths.count
            result.append(HUDContextChip(
                symbolName: "folder",
                text: count == 1
                    ? "1 item selected in Finder"
                    : "\(count) items selected in Finder",
                helpText: finderSelectionPaths.joined(separator: "\n")))
        } else if finderAutomationDenied {
            // Review finding 21: the denial surfaces HERE, as a
            // chip in its own right — never as a silent absence.
            result.append(HUDContextChip(
                symbolName: "exclamationmark.triangle",
                text: "Finder access denied",
                helpText: "Blink can't ask Finder what you selected — allow it in System Settings → Privacy & Security → Automation, then summon the panel again."))
        }
        if let chipText = clipboardKind.chipText {
            result.append(HUDContextChip(
                symbolName: "doc.on.clipboard",
                text: chipText,
                helpText: clipboardText != nil
                    ? "The Clipboard switch is on (Settings → What this app can see), so the text itself is shared with the model when you send."
                    : "Only the kind is noted — the contents are shared only when the Clipboard switch is on in Settings."))
        }
        return result
    }

    // MARK: Prompt folding

    /// How much clipboard text a prompt may carry. The clipboard can
    /// hold a novel; the model's window can't.
    static let maxClipboardCharactersInPrompt = 1500

    /// The plain-language context block folded into a prompt sent
    /// from the panel, or nil when nothing was captured. Written for
    /// the model, in the user's terms — app name, selected files,
    /// clipboard text (already toggle-gated by `make`).
    func promptContextText() -> String? {
        guard hasAnyContext else { return nil }
        var lines = ["Context from this Mac right now "
                     + "(captured when the quick panel opened):"]
        if let app = frontmostAppName, !app.isEmpty {
            lines.append("- The user opened this from inside \(app).")
        }
        if !finderSelectionPaths.isEmpty {
            if finderSelectionPaths.count == 1 {
                lines.append("- Finder has this item selected: "
                             + finderSelectionPaths[0])
            } else {
                lines.append("- Finder has these items selected:")
                for path in finderSelectionPaths {
                    lines.append("  \(path)")
                }
            }
        }
        switch clipboardKind {
        case .text:
            if let text = clipboardText {
                lines.append("- The clipboard holds this text: "
                             + Self.clippedClipboardText(text))
            } else {
                lines.append("- The clipboard holds some text "
                             + "(its contents weren't shared — the "
                             + "Clipboard switch is off).")
            }
        case .image:
            lines.append("- The clipboard holds an image "
                         + "(the image itself wasn't shared).")
        case .other:
            lines.append("- The clipboard holds something that isn't "
                         + "plain text or an image.")
        case .empty:
            break
        }
        return lines.joined(separator: "\n")
    }

    /// Clipboard text for a prompt: trimmed, and cut to the cap with
    /// an honest note when it was longer.
    static func clippedClipboardText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard trimmed.count > maxClipboardCharactersInPrompt else {
            return "“\(trimmed)”"
        }
        let kept = String(trimmed.prefix(maxClipboardCharactersInPrompt))
        return "“\(kept)…” (the clipboard text was longer; "
            + "only the first part was included)"
    }
}

/// One context chip in the panel: an SF Symbol name, its label, and
/// the longer explanation behind the hover text.
struct HUDContextChip: Equatable, Sendable {
    let symbolName: String
    let text: String
    let helpText: String
}

// MARK: - Conversation naming

/// HUD conversations are real conversations (they live in the
/// sidebar like any chat), titled from their first prompt so the
/// list stays scannable: "Quick — resize this photo".
enum HUDConversationNaming {

    /// The most prompt characters a title carries.
    static let maxPromptCharacters = 36

    static let fallbackTitle = "Quick question"

    /// The title for a HUD conversation's first prompt: "Quick — "
    /// plus the prompt's first words, whitespace tidied, cut to the
    /// cap with an ellipsis. An empty prompt (there is no way to send
    /// one from the panel today, but the rule stays total) gets the
    /// fallback title.
    static func title(forFirstPrompt prompt: String) -> String {
        let tidied = prompt
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !tidied.isEmpty else { return fallbackTitle }
        if tidied.count <= maxPromptCharacters {
            return "Quick — \(tidied)"
        }
        return "Quick — \(tidied.prefix(maxPromptCharacters))…"
    }
}

// MARK: - Session reuse

/// Which conversation a summon talks to.
///
/// The rule, in one paragraph: **each summon starts a fresh
/// conversation — unless the previous summon's conversation is still
/// warm**: the panel was dismissed less than `continueGrace` seconds
/// ago, that conversation still exists, and the user didn't move it
/// to the main window. A quick dismiss-and-resummon (summon, glance
/// at Finder, summon again) continues the thread instead of
/// scattering one exchange across three sidebar entries; anything
/// older is a new question and gets a new conversation. Follow-ups
/// sent without dismissing always continue, trivially — the panel
/// never switches conversations mid-session.
enum HUDSessionPolicy {

    /// How long after a dismissal a re-summon continues the
    /// previous HUD conversation.
    static let continueGrace: TimeInterval = 120

    /// The pure decision.
    ///
    /// - Parameters:
    ///   - previousConversationID: the last HUD conversation, if any.
    ///   - dismissedAt: when the panel was last dismissed, if known.
    ///   - now: the moment of this summon.
    ///   - previousStillExists: whether that conversation is still in
    ///     the store (it may have been deleted from the sidebar).
    ///   - movedToMainWindow: whether the user took the previous
    ///     conversation into the main window — that ends the chain
    ///     by design, so the next summon starts fresh.
    static func shouldContinue(previousConversationID: UUID?,
                               dismissedAt: Date?,
                               now: Date,
                               previousStillExists: Bool,
                               movedToMainWindow: Bool) -> Bool {
        guard previousConversationID != nil,
              previousStillExists,
              !movedToMainWindow,
              let dismissedAt else { return false }
        let elapsed = now.timeIntervalSince(dismissedAt)
        return elapsed >= 0 && elapsed <= continueGrace
    }
}
