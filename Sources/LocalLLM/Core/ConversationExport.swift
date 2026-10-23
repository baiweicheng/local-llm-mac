import Foundation

/// Phase 10: a conversation as a clean Markdown document — the
/// export behind the sidebar's and the chat header's "Export as
/// Markdown…" / "Copy as Markdown". Pure: the views hand in plain
/// values and get a finished document back, so the format is
/// golden-tested here and documented in the README.
///
/// The format:
///
///     # <chat title>
///
///     _Started Oct 23, 2026 at 2:15 PM · Last updated Oct 23, 2026 at 3:02 PM · Exported Oct 23, 2026 at 4:48 PM_
///
///     ## You — Oct 23, 2026 at 2:15 PM
///
///     <message text>
///
///     ## Assistant — Oct 23, 2026 at 2:16 PM
///
///     <message text>
///
///     _Apple On-Device · 1.2s · ≈96 tokens · $0.00_
///
/// One section per message, in order. The italic line under an
/// assistant reply is its telemetry pill (the same wording the app
/// shows), and only appears when `includeTelemetry` is on and the
/// reply has telemetry. Images can't live in a text file, so a
/// message with attachments gets an italic "_[2 images attached]_"
/// note instead — the pictures stay in the app.
enum ConversationExport {

    /// One message, as plain values.
    struct MessageInput: Equatable, Sendable {
        var role: MessageRole
        var createdAt: Date
        var text: String
        var attachmentCount: Int = 0
        var telemetry: MessageTelemetry? = nil
    }

    static func markdown(title: String,
                         createdAt: Date,
                         updatedAt: Date,
                         exportedAt: Date,
                         messages: [MessageInput],
                         includeTelemetry: Bool = true,
                         timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("_Started \(stamp(createdAt, timeZone: timeZone))"
                     + " · Last updated \(stamp(updatedAt, timeZone: timeZone))"
                     + " · Exported \(stamp(exportedAt, timeZone: timeZone))_")
        if messages.isEmpty {
            lines.append("")
            lines.append("_No messages yet._")
        }
        for message in messages {
            lines.append("")
            lines.append("## \(label(for: message.role))"
                         + " — \(stamp(message.createdAt, timeZone: timeZone))")
            lines.append("")
            let body = message.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append(body)
            }
            if message.attachmentCount > 0 {
                if !body.isEmpty { lines.append("") }
                lines.append(message.attachmentCount == 1
                             ? "_[1 image attached]_"
                             : "_[\(message.attachmentCount) images attached]_")
            }
            if body.isEmpty, message.attachmentCount == 0 {
                lines.append("_(empty)_")
            }
            if includeTelemetry, let telemetry = message.telemetry {
                lines.append("")
                lines.append("_\(TelemetryFormat.line(for: telemetry))_")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The save panel's starting file name: "<title>.md" with the
    /// characters a file name can't carry replaced by "-", runs of
    /// replacements collapsed, and the result kept to a sensible
    /// length. An unsalvageable title becomes "Chat.md".
    static func suggestedFileName(forTitle title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
        var cleaned = ""
        var lastWasDash = true // also trims a leading dash
        for scalar in title.unicodeScalars {
            if illegal.contains(scalar) {
                if !lastWasDash { cleaned.append("-") }
                lastWasDash = true
            } else {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            }
        }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        while cleaned.hasPrefix("-") { cleaned.removeFirst() }
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Chat" : String(trimmed.prefix(80))
        return base + ".md"
    }

    private static func label(for role: MessageRole) -> String {
        switch role {
        case .user: return "You"
        case .assistant: return "Assistant"
        }
    }

    /// "Oct 23, 2026 at 2:15 PM" — an explicit format (not a
    /// locale style) so the output is identical on every Mac and
    /// the golden tests are stable; `timeZone` is injectable for
    /// the same reason and defaults to the reader's own zone.
    private static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }
}
