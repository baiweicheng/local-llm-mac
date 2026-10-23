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
    /// whitespace. An empty result means "not searching" — the
    /// sidebar shows everything, and `hit` is never called.
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a chat matches, and the proof. Nil means no match:
    /// neither the title nor any message contains the query.
    static func hit(title: String, messageTexts: [String],
                    query rawQuery: String) -> ChatSearchHit? {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return nil }
        let titleMatched = contains(title, query)
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

    /// The snippet for one message's text, or nil when the text
    /// doesn't contain the query.
    static func snippet(in text: String, matching rawQuery: String,
                        context: Int = snippetContext) -> String? {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return nil }
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

    /// Message text as a snippet can show it: newlines and runs of
    /// whitespace collapsed to single spaces.
    private static func flatten(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
