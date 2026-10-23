import AppKit
import Foundation

/// Phase 5: the clipboard tools (NSPasteboard).
///
/// Reading returns the current text (or says plainly when the
/// clipboard holds something that isn't text). Writing is the brief's
/// "bridge" — it executes directly, with no confirmation step, but it
/// goes through the same runtime as every other tool, so it is ALWAYS
/// in the access log and on a transcript card. That's the deal this
/// tool ships under; the log is what keeps it honest.
enum ClipboardService {

    static func read() -> String {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            return "The clipboard is empty, or what's on it isn't text."
        }
        return text
    }

    static func write(_ text: String) -> String {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return "Copied to the clipboard (\(text.count) characters) — ready to paste anywhere."
    }
}
