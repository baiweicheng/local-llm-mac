import Foundation

/// The outcome of a privacy-check pass: the text as it may leave this
/// Mac, and how many things were hidden along the way.
struct RedactionResult: Equatable, Sendable {
    let text: String
    let replacementCount: Int

    var didRedact: Bool { replacementCount > 0 }
}

/// The privacy firewall's scrubber (pure, heavily unit-tested).
///
/// Before any prompt or history is sent to a destination off this Mac,
/// this masks the things that should never travel: API keys and other
/// secret-shaped tokens, labeled secrets ("password: …"), email
/// addresses, phone numbers, card-number-shaped digit runs, and any
/// custom words or phrases the user added in Settings.
///
/// Rules, in the order they run:
/// 1. The user's custom terms (literal, case-insensitive).
/// 2. Labeled secrets — a secret word followed by `:` or `=` hides the
///    value after it (the label itself stays, so the message still
///    makes sense to the receiving model).
/// 3. Known key shapes (OpenAI-style `sk-…`, GitHub tokens, AWS access
///    keys, Slack tokens, Google API keys).
/// 4. Email addresses.
/// 5. US Social Security numbers (3-2-4 digits, dashes required) —
///    too short for the card rule, the wrong shape for the phone
///    rule, so they get a rule of their own.
/// 6. Card-number-shaped digit runs (13 or more digits, spaces or
///    dashes allowed between them; the whole run is hidden, however
///    long it is). Shape-based by design — no checksum.
/// 7. Long opaque tokens (24+ characters mixing letters and digits —
///    hex and base64 secrets; plain long words are left alone).
/// 8. Common phone-number shapes (separators or parentheses required,
///    so a bare short number is never mistaken for one).
///
/// The input is never mutated — the engine redacts the outgoing copy
/// only; what the user typed stays untouched in the saved chat.
enum Redactor {

    /// What a hidden value is replaced with.
    static let mask = "[redacted]"

    /// Terms shorter than this (after trimming) are ignored: hiding
    /// every "a" or "id" in a message would mangle it beyond use.
    static let minimumCustomTermLength = 3

    static func redact(_ text: String,
                       customTerms: [String] = []) -> RedactionResult {
        var current = text
        var count = 0

        // 1. Custom terms — longest first, so "Acme Corp" is hidden
        // before a shorter "Acme" inside it can be.
        let terms = customTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minimumCustomTermLength }
            .sorted { $0.count > $1.count }
        for term in terms {
            let pattern = NSRegularExpression.escapedPattern(for: term)
            guard let regex = compile(pattern, options: [.caseInsensitive])
            else { continue }
            let (next, hits) = apply(regex, to: current, template: mask)
            current = next
            count += hits
        }

        // 2–6. The built-in rules that precede the opaque-token
        // rule in the documented sequence.
        for rule in rules {
            let (next, hits) = apply(rule.regex, to: current,
                                     template: rule.template)
            current = next
            count += hits
        }

        // 7 (audit E-80): the opaque-token rule runs as a linear
        // code-driven scan, not a regex — its old pattern carried
        // two lookaheads over the whole token charset, which is
        // quadratic on long token-shaped runs. It runs at exactly
        // the point in the sequence the regex occupied (after the
        // card rule, before phone numbers), with identical match
        // semantics.
        let tokens = maskOpaqueTokens(in: current)
        current = tokens.text
        count += tokens.count

        // 8. Phone numbers — after the token scan, as before.
        if let phoneRule {
            let (next, hits) = apply(phoneRule.regex, to: current,
                                     template: phoneRule.template)
            current = next
            count += hits
        }

        return RedactionResult(text: current, replacementCount: count)
    }

    // MARK: - Opaque tokens (rule 7, code-driven)

    /// The opaque-token charset: base64/hex alphabet.
    private static let opaqueCharset =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/_=-")

    /// Masks every maximal run of the opaque charset that is at
    /// least 24 characters long AND contains at least one letter
    /// and one digit — exactly the old regex
    /// `(?=[A-Za-z0-9+/_=-]*\d)(?=[A-Za-z0-9+/_=-]*[A-Za-z])[A-Za-z0-9+/_=-]{24,}`.
    /// (Regex and scan agree on maximal runs: the pattern is
    /// greedy, unanchored, and its lookaheads range over the same
    /// charset, so a match always extends to the whole run — a
    /// run qualifies iff its full length qualifies.) One linear
    /// pass, no backtracking.
    static func maskOpaqueTokens(in text: String) -> (text: String, count: Int) {
        var output = ""
        output.reserveCapacity(text.count)
        var masked = 0
        var index = text.startIndex
        while index < text.endIndex {
            guard opaqueCharset.contains(text[index]) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            // One maximal run of the charset.
            var runEnd = index
            var hasLetter = false
            var hasDigit = false
            var length = 0
            while runEnd < text.endIndex, opaqueCharset.contains(text[runEnd]) {
                let char = text[runEnd]
                if char.isLetter { hasLetter = true }
                if char.isNumber { hasDigit = true }
                length += 1
                runEnd = text.index(after: runEnd)
            }
            if length >= 24, hasLetter, hasDigit {
                output += mask
                masked += 1
            } else {
                output += text[index..<runEnd]
            }
            index = runEnd
        }
        return (output, masked)
    }

    // MARK: - Rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        var rules: [Rule] = []

        func add(_ pattern: String, template: String = mask,
                 options: NSRegularExpression.Options = []) {
            if let regex = compile(pattern, options: options) {
                rules.append(Rule(regex: regex, template: template))
            }
        }

        // 2. Labeled secrets: "api_key = …", "Password: …". Group 1
        // (label, separator, an optional opening quote) is kept; the
        // value is hidden. Three shapes the original rule missed
        // (audit B-06) are covered now:
        //  - Prefixed labels: the keyword may sit inside a longer
        //    snake/kebab label ("client_secret", "refresh_token",
        //    "aws_secret_access_key") — the label is word-character
        //    segments around the keyword, joined by _ or - (so a
        //    plain word like "secretary" still doesn't qualify:
        //    extra letters must be separated, not run on).
        //  - Quoted labels: an optional quote may sit between the
        //    label and the separator, as in {"password": "…"}.
        //  - Quoted values: a quoted value is hidden whole, spaces
        //    and all (passphrases), at any length; an unquoted
        //    value still needs 4+ non-space characters, so a short
        //    example like "token: abc" in prose survives.
        add(#"((?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|secret|access[_-]?token|auth[_-]?token|token|password|passwd|pwd)(?:[_-][A-Za-z0-9]+)*["']?\s*[:=]\s*["']?)(?:(?<=")[^"]+(?=")|(?<=')[^']+(?=')|[^\s"']{4,})"#,
            template: "$1" + mask, options: [.caseInsensitive])

        // 3. Known key shapes.
        add(#"\bsk-[A-Za-z0-9_-]{10,}\b"#)
        add(#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#)
        add(#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#)
        add(#"\bAKIA[0-9A-Z]{16}\b"#)
        add(#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#)
        add(#"\bAIza[0-9A-Za-z_-]{20,}\b"#)

        // 4. Email addresses.
        add(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

        // 5. Social Security numbers (audit B-05): the 3-2-4 shape
        // fits neither the card rule (13+ digits) nor the phone rule
        // (3-3-4), so without this it crossed unmasked.
        add(#"\b\d{3}-\d{2}-\d{4}\b"#)

        // 6. Card-number-shaped digit runs. The run is matched in
        // full, however long it runs (audit B-14): capping the
        // match at 19 digits left the tail of a longer account or
        // reference number exposed.
        add(#"(?:\d[ -]?){12,}\d"#)

        // 7. Long opaque tokens: 24+ chars of the base64/hex alphabet
        // containing at least one letter AND one digit (a long plain
        // word never qualifies). NOT a regex — audit E-80: the
        // lookahead pattern was quadratic on long token-shaped runs,
        // so this slot in the sequence is filled by the linear
        // `maskOpaqueTokens` scan in `redact`, between this rule
        // list and the phone rule below.

        return rules
    }()

    /// Rule 8, phone numbers — kept apart from `rules` only so it
    /// still runs AFTER the code-driven opaque-token scan, exactly
    /// where it sat in the original sequence (audit E-80).
    /// Country code optional; the area code may be parenthesized.
    /// A separator is required between the later groups, but after
    /// a parenthesized area code it is optional — "(404)555-0123"
    /// is as common as "(404) 555-0123" (audit B-17).
    private static let phoneRule: Rule? = {
        guard let regex = compile(
            #"(?:\+\d{1,3}[\s-]?)?(?:\(\d{3}\)\s?|\d{3}[\s.-])\d{3}[\s.-]\d{4}"#)
        else { return nil }
        return Rule(regex: regex, template: mask)
    }()

    // MARK: - Applying

    /// Replaces every match of `regex` using `template`, returning the
    /// new text and how many replacements were made.
    private static func apply(_ regex: NSRegularExpression,
                              to text: String,
                              template: String) -> (String, Int) {
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let replaced = regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: template)
        return (replaced, count)
    }

    /// Compiles one of the constant patterns above. They're literals
    /// in this file, so a failure would be a programming error the
    /// unit tests exist to catch — not a runtime condition to hide.
    private static func compile(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }
}
