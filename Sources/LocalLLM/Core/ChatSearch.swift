import Foundation

/// Phase 10: sidebar chat search — the pure matching and snippet
/// logic behind the sidebar's search field. The view fetches the
/// conversations; everything about "does this chat match, and what
/// line proves it" lives here, so it's testable without SwiftData.
///
/// Matching is case- and accent-insensitive ("cafe" finds "café"),
/// against the title first and then each message's text in order.
/// The snippet is the first matching message's text around the
/// match — flattened to one line, with a little context on each
/// side, trimmed back to word boundaries, and "…" marking where
/// text was cut.
struct ChatSearchHit: Equatable, Sendable {
    /// The title itself matched (the row needs no snippet to
    /// explain itself, though one may still be present).
    let titleMatched: Bool
    /// A one-line excerpt of the first matching message, or nil
    /// when only the title matched.
    let snippet: String?
}

enum ChatSearch {

    /// How much context to keep on each side of a match in a
    /// snippet, in characters.
    static let snippetContext = 42

    /// The query as matching sees it: trimmed of surrounding
    /// whitespace AND with internal whitespace runs collapsed to
    /// single spaces (UAT-09) — message text is matched in its
    /// flattened (single-spaced) form, so a query typed with a
    /// double space ("body  fat") must be collapsed the same way
    /// or it can never match. An empty result means "not
    /// searching" — the sidebar shows everything, and `hit` is
    /// never called.
    static func normalizedQuery(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Whether a chat matches, and the proof. Nil means no match:
    /// neither the title nor any message contains the query.
    static func hit(title: String, messageTexts: [String],
                    query rawQuery: String) -> ChatSearchHit? {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return nil }
        // The title is flattened before the verbatim test, for the
        // same reason the query is collapsed (UAT-09): irregular
        // spacing on EITHER side shouldn't hide a match.
        let titleMatched = contains(flatten(title), query)
        var snippet: String? = nil
        for text in messageTexts {
            if let found = snippet(in: text, matching: query) {
                snippet = found
                break
            }
        }
        guard titleMatched || snippet != nil else { return nil }
        return ChatSearchHit(titleMatched: titleMatched, snippet: snippet)
    }

    /// Every hit in a list of chats, computed in ONE pass (audit
    /// E-01): the sidebar caches this keyed by (query, corpus
    /// fingerprint) instead of re-running `hit` per row per body
    /// evaluation — the old shape rescanned (and re-flattened)
    /// every message of every conversation several times per
    /// keystroke.
    static func hits(
        in chats: [(id: UUID, title: String, messageTexts: [String])],
        query rawQuery: String
    ) -> [UUID: ChatSearchHit] {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return [:] }
        var result: [UUID: ChatSearchHit] = [:]
        for chat in chats {
            if let found = hit(title: chat.title,
                               messageTexts: chat.messageTexts,
                               query: query) {
                result[chat.id] = found
            }
        }
        return result
    }

    /// The snippet for one message's text, or nil when the text
    /// doesn't contain the query.
    static func snippet(in text: String, matching rawQuery: String,
                        context: Int = snippetContext) -> String? {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return nil }
        // Audit E-01: test the match BEFORE flattening. Flattening
        // allocates a split+join over the WHOLE text; doing it first
        // meant every non-matching message paid that cost before
        // the range test could fail. The cheap test runs on the raw
        // text with whitespace runs collapsed in the QUERY instead:
        // a query whose words appear in order, separated only by
        // whitespace, is the only way the flattened text can match.
        // When that test passes, the text is flattened exactly once
        // and the snippet is built from the flattened form, as
        // before — identical results, a fraction of the allocation.
        guard rawTextMayMatch(text, query: query) else { return nil }
        let flat = flatten(text)
        guard let match = flat.range(of: query,
                                     options: [.caseInsensitive,
                                               .diacriticInsensitive])
        else { return nil }

        var start = flat.index(match.lowerBound, offsetBy: -context,
                               limitedBy: flat.startIndex) ?? flat.startIndex
        var end = flat.index(match.upperBound, offsetBy: context,
                             limitedBy: flat.endIndex) ?? flat.endIndex
        let cutStart = start > flat.startIndex
        let cutEnd = end < flat.endIndex
        // Trim a cut edge back to a word boundary when there's one
        // nearby, so the snippet doesn't start mid-word.
        if cutStart, let space = flat[start..<match.lowerBound]
            .firstIndex(of: " ") {
            start = flat.index(after: space)
        }
        if cutEnd, let space = flat[match.upperBound..<end]
            .lastIndex(of: " ") {
            end = space
        }
        let core = String(flat[start..<end])
            .trimmingCharacters(in: .whitespaces)
        return (cutStart ? "…" : "") + core + (cutEnd ? "…" : "")
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query,
                   options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The pre-flatten match test (audit E-01): could `flatten(text)`
    /// contain `query`? Flattening only collapses whitespace runs
    /// to single spaces, so a flattened match means the query's
    /// whitespace-separated words occur in `text` in order, each
    /// found (case/diacritic-insensitively) after the previous
    /// one's end, with nothing but whitespace allowed BETWEEN
    /// words beyond what the words themselves span. Single-word
    /// queries (the overwhelmingly common case) reduce to the
    /// plain `contains` test on the raw text.
    static func rawTextMayMatch(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let first = words.first else { return false }
        guard words.count > 1 else { return contains(text, first) }
        var searchFrom = text.startIndex
        for word in words {
            let slice = text[searchFrom...]
            guard let found = slice.range(
                of: word,
                options: [.caseInsensitive, .diacriticInsensitive])
            else { return false }
            searchFrom = found.upperBound
        }
        return true
    }

    /// Message text as a snippet can show it: newlines and runs of
    /// whitespace collapsed to single spaces.
    private static func flatten(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
