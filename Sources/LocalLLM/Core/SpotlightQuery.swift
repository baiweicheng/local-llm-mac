import Foundation

/// Phase 5: building the Spotlight (NSMetadataQuery) predicate for
/// the file-search tool, plus shaping its results for the model.
///
/// The builder is pure string work — the user's keywords are escaped
/// before they go anywhere near a query string, so a keyword can't
/// break out of its quoted literal and rewrite the search. The query
/// itself matches a file when *every* keyword appears in its name or
/// its text content.
enum SpotlightQueryBuilder {

    static let maxKeywords = 5
    static let maxKeywordLength = 40

    /// Escape a raw keyword for a double-quoted Spotlight query
    /// literal: backslashes first, then quotes.
    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The predicate format string for a search phrase, or nil when
    /// the phrase has no usable keywords.
    static func predicateFormat(forPhrase phrase: String) -> String? {
        let keywords = phrase
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .prefix(maxKeywords)
            .map { String($0.prefix(maxKeywordLength)) }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return nil }
        let groups = keywords.map { keyword in
            let escaped = escape(keyword)
            return "(kMDItemDisplayName CONTAINS[cd] \"\(escaped)\""
                + " || kMDItemTextContent CONTAINS[cd] \"\(escaped)\""
                + " || kMDItemFSName CONTAINS[cd] \"\(escaped)\")"
        }
        return groups.joined(separator: " && ")
    }

    /// Shape raw hits into the text the model sees: name, path, and
    /// last-changed date, one per line, with an honest header when the
    /// full result set was larger than what's shown.
    static func formatResults(
        _ items: [(name: String, path: String, modified: Date?)],
        totalCount: Int
    ) -> String {
        guard !items.isEmpty else {
            return "No files matched that search."
        }
        var lines = ["Found \(totalCount) file\(totalCount == 1 ? "" : "s"):"]
        for item in items {
            var line = "• \(item.name) — \(item.path)"
            if let modified = item.modified {
                line += " (changed \(DateDisplay.day(modified)))"
            }
            lines.append(line)
        }
        if totalCount > items.count {
            lines.append("Showing the first \(items.count) — ask for a narrower search to see others.")
        }
        return lines.joined(separator: "\n")
    }
}
