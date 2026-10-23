import AppKit
import Foundation

/// Phase 7: gathers the quick panel's context at summon time.
///
/// Two halves:
///
/// - `captureSync` — the facts readable instantly from this process:
///   the frontmost app (`NSWorkspace`) and the clipboard's *kind*
///   (from the pasteboard's declared types — contents are only read
///   when the user has enabled the Clipboard source, and even then
///   only the text). The purge rules live in `HUDContextSnapshot
///   .make`; this service just reports what it found.
/// - `probeFinderSelection` — Finder's selection, which lives in
///   another app and is only reachable through Apple Events. It runs
///   on a dedicated background queue because an AppleScript round
///   trip can block (and the first call can sit behind macOS's
///   Automation permission prompt). Any failure — permission denied,
///   Finder not running, nothing selected — delivers an empty list:
///   the chip is simply absent. It is NEVER an error dialog.
///
/// The Finder probe only runs when the Files source toggle is on:
/// with it off, no Apple event is sent at all, so the app doesn't
/// even ask macOS for Automation permission it doesn't need.
enum HUDContextCapture {

    // MARK: - Synchronous facts

    /// The instantly-readable context. `includeClipboardText` is the
    /// Clipboard source toggle: when false, the clipboard's contents
    /// are never read here — only its declared types.
    static func captureSync(includeClipboardText: Bool) -> HUDContextSnapshot {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        let pasteboard = NSPasteboard.general
        let kind = clipboardKind(of: pasteboard)
        let text = (includeClipboardText && kind == .text)
            ? pasteboard.string(forType: .string)
            : nil
        return HUDContextSnapshot.make(
            frontmostAppName: appName,
            clipboardKind: kind,
            clipboardText: text,
            finderSelectionPaths: [],
            clipboardSourceEnabled: includeClipboardText,
            filesSourceEnabled: false)
    }

    /// The clipboard's kind from its declared types alone.
    static func clipboardKind(of pasteboard: NSPasteboard) -> HUDClipboardKind {
        guard let types = pasteboard.types, !types.isEmpty else {
            return .empty
        }
        if types.contains(.string) {
            return .text
        }
        if types.contains(.tiff) || types.contains(.png)
            || pasteboard.canReadObject(forClasses: [NSImage.self],
                                        options: nil) {
            return .image
        }
        return .other
    }

    // MARK: - Finder selection (Apple Events)

    /// A serial queue for AppleScript work: `NSAppleScript` objects
    /// aren't documented as thread-safe, so every probe compiles and
    /// runs on this one queue, one at a time.
    private static let scriptQueue = DispatchQueue(
        label: "LocalLLM.FinderProbe", qos: .userInitiated)

    /// Asks Finder for its selected items' POSIX paths and delivers
    /// them via `completion` (called on the probe queue — hop to the
    /// main actor before touching UI state). Empty on ANY failure,
    /// by design.
    static func probeFinderSelection(
        completion: @escaping @Sendable ([String]) -> Void
    ) {
        scriptQueue.async {
            completion(finderSelectionPaths())
        }
    }

    /// The blocking probe itself. Kept separate so its failure modes
    /// are all in one place: every path out of here that isn't a
    /// clean answer is an empty list.
    private static func finderSelectionPaths() -> [String] {
        let source = """
            tell application "Finder"
                set thePaths to {}
                repeat with anItem in (selection)
                    try
                        set end of thePaths to POSIX path of (anItem as alias)
                    end try
                end repeat
                return thePaths
            end tell
            """
        guard let script = NSAppleScript(source: source) else { return [] }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        // A denied Automation permission, a missing Finder, anything
        // at all — the answer is the same: no chip.
        guard errorInfo == nil else { return [] }
        var paths: [String] = []
        if result.numberOfItems > 0 {
            for index in 1...result.numberOfItems {
                if let item = result.atIndex(index),
                   let path = item.stringValue, !path.isEmpty {
                    paths.append(path)
                }
            }
        } else if let single = result.stringValue, !single.isEmpty {
            paths.append(single)
        }
        return paths
    }
}
