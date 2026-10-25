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
///   Automation permission prompt). Finder not running or nothing
///   selected delivers an empty list: the chip is simply absent.
///   A DENIED Automation permission is different (review finding
///   21) — it delivers `.denied` through the detailed probe, so the
///   panel shows a "Finder access denied" chip instead of silently
///   looking like nothing was selected. It is NEVER an error dialog.
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

    /// One Finder probe's outcome, kept distinct on purpose.
    ///
    /// Review finding 21: a denied Automation permission used to
    /// collapse into the same empty list as "Finder has nothing
    /// selected" (and as Finder not running), so a user who
    /// declined the prompt — or whose packaged app lacked the
    /// entitlement entirely — saw no chip and no reason. Now:
    /// `.denied` is surfaced as its own chip in the panel (see
    /// `HUDContextSnapshot.finderAutomationDenied`), while
    /// `.unavailable` (Finder not running, script failure) still
    /// means simply no chip.
    enum FinderProbeOutcome: Equatable, Sendable {
        case selection([String])
        case denied
        case unavailable
    }

    /// The AppleScript error number macOS reports when Automation
    /// permission for Finder is denied (errAEEventNotPermitted):
    /// the user declined the prompt, or the app was never granted
    /// it. This is the one failure mode that gets its own surface.
    static let automationDeniedErrorNumber = -1743

    /// Maps a probe's AppleScript error number to its outcome
    /// class — the testable seam (the live probe below feeds it
    /// the number from the script's error dictionary).
    static func outcomeForErrorNumber(
        _ number: Int?) -> FinderProbeOutcome {
        number == automationDeniedErrorNumber ? .denied : .unavailable
    }

    /// Asks Finder for its selected items' POSIX paths and delivers
    /// them via `completion` (called on the probe queue — hop to the
    /// main actor before touching UI state). Empty on failure, as
    /// before — callers that need to tell denial apart from
    /// "nothing selected" use `probeFinderSelectionDetailed`.
    static func probeFinderSelection(
        completion: @escaping @Sendable ([String]) -> Void
    ) {
        probeFinderSelectionDetailed { outcome in
            if case .selection(let paths) = outcome {
                completion(paths)
            } else {
                completion([])
            }
        }
    }

    /// The distinguishing probe: delivers `.selection`, `.denied`,
    /// or `.unavailable` (called on the probe queue).
    static func probeFinderSelectionDetailed(
        completion: @escaping @Sendable (FinderProbeOutcome) -> Void
    ) {
        scriptQueue.async {
            completion(finderSelectionOutcome())
        }
    }

    /// The blocking probe itself. Kept separate so its failure modes
    /// are all in one place.
    private static func finderSelectionOutcome() -> FinderProbeOutcome {
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
        guard let script = NSAppleScript(source: source) else {
            return .unavailable
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo["NSAppleScriptErrorNumber"]
                          as? NSNumber)?.intValue
            return outcomeForErrorNumber(number)
        }
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
        return .selection(paths)
    }
}
