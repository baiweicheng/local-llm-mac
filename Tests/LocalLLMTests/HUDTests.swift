import XCTest
@testable import LocalLLM

/// Phase 7 tests: the quick panel's pure logic — the context
/// snapshot's toggle purge rules (the privacy boundary: clipboard
/// text and Finder paths exist in a snapshot ONLY when their source
/// switch is on), the chips the panel shows, the plain-language
/// context folded into prompts, conversation titling, and the
/// fresh-vs-continue session rule. The Carbon hotkey, the NSPanel,
/// and the AppleScript Finder probe are thin AppKit wrappers and
/// are exercised on the Mac.
final class HUDTests: XCTestCase {

    // MARK: - Snapshot purge rules

    func testMakeDropsClipboardTextWhenSourceOff() {
        let snapshot = HUDContextSnapshot.make(
            frontmostAppName: "Safari",
            clipboardKind: .text,
            clipboardText: "a copied secret",
            finderSelectionPaths: [],
            clipboardSourceEnabled: false,
            filesSourceEnabled: false)
        XCTAssertNil(snapshot.clipboardText)
        // The KIND is still known — it's a type, not a content.
        XCTAssertEqual(snapshot.clipboardKind, .text)
    }

    func testMakeKeepsClipboardTextWhenSourceOn() {
        let snapshot = HUDContextSnapshot.make(
            frontmostAppName: "Safari",
            clipboardKind: .text,
            clipboardText: "hello",
            finderSelectionPaths: [],
            clipboardSourceEnabled: true,
            filesSourceEnabled: false)
        XCTAssertEqual(snapshot.clipboardText, "hello")
    }

    func testMakeKeepsTextOnlyForTextKind() {
        // Even with the switch on, a "text" value riding along with
        // a non-text kind never lands in the snapshot.
        let snapshot = HUDContextSnapshot.make(
            frontmostAppName: nil,
            clipboardKind: .image,
            clipboardText: "should not survive",
            finderSelectionPaths: [],
            clipboardSourceEnabled: true,
            filesSourceEnabled: false)
        XCTAssertNil(snapshot.clipboardText)
    }

    func testMakeDropsFinderPathsWhenFilesOff() {
        let snapshot = HUDContextSnapshot.make(
            frontmostAppName: "Finder",
            clipboardKind: .empty,
            clipboardText: nil,
            finderSelectionPaths: ["/Users/a/report.pdf"],
            clipboardSourceEnabled: false,
            filesSourceEnabled: false)
        XCTAssertEqual(snapshot.finderSelectionPaths, [])
    }

    func testMakeKeepsFinderPathsWhenFilesOn() {
        let snapshot = HUDContextSnapshot.make(
            frontmostAppName: "Finder",
            clipboardKind: .empty,
            clipboardText: nil,
            finderSelectionPaths: ["/Users/a/report.pdf", "/Users/a/b.txt"],
            clipboardSourceEnabled: false,
            filesSourceEnabled: true)
        XCTAssertEqual(snapshot.finderSelectionPaths,
                       ["/Users/a/report.pdf", "/Users/a/b.txt"])
    }

    // MARK: - Chips

    func testChipsForAppOnly() {
        let chips = HUDContextSnapshot(
            frontmostAppName: "Safari", clipboardKind: .empty,
            clipboardText: nil, finderSelectionPaths: []).chips
        XCTAssertEqual(chips.map(\.text), ["Safari"])
    }

    func testChipsForEmptySnapshot() {
        XCTAssertTrue(HUDContextSnapshot.empty.chips.isEmpty)
        XCTAssertFalse(HUDContextSnapshot.empty.hasAnyContext)
    }

    func testChipsCoverClipboardKinds() {
        func chipText(_ kind: HUDClipboardKind) -> String? {
            HUDContextSnapshot(
                frontmostAppName: nil, clipboardKind: kind,
                clipboardText: nil, finderSelectionPaths: [])
                .chips.first?.text
        }
        XCTAssertNil(chipText(.empty))
        XCTAssertEqual(chipText(.text), "Clipboard: text")
        XCTAssertEqual(chipText(.image), "Clipboard: an image")
        XCTAssertEqual(chipText(.other), "Clipboard: something copied")
    }

    func testChipsCountFinderSelection() {
        func chipText(_ paths: [String]) -> String? {
            HUDContextSnapshot(
                frontmostAppName: nil, clipboardKind: .empty,
                clipboardText: nil, finderSelectionPaths: paths)
                .chips.first?.text
        }
        XCTAssertEqual(chipText(["/a.pdf"]), "1 item selected in Finder")
        XCTAssertEqual(chipText(["/a.pdf", "/b.txt", "/c.png"]),
                       "3 items selected in Finder")
    }

    func testChipsOrderIsAppFinderClipboard() {
        let chips = HUDContextSnapshot(
            frontmostAppName: "Notes", clipboardKind: .text,
            clipboardText: nil, finderSelectionPaths: ["/a.pdf"]).chips
        XCTAssertEqual(chips.map(\.text),
                       ["Notes", "1 item selected in Finder",
                        "Clipboard: text"])
    }

    // MARK: - Prompt context text

    func testPromptTextIsNilWithoutContext() {
        XCTAssertNil(HUDContextSnapshot.empty.promptContextText())
    }

    func testPromptTextIncludesAppAndFinderPaths() {
        let text = HUDContextSnapshot(
            frontmostAppName: "Safari", clipboardKind: .empty,
            clipboardText: nil,
            finderSelectionPaths: ["/Users/a/report.pdf"]).promptContextText()
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("opened this from inside Safari"))
        XCTAssertTrue(text!.contains("Finder has this item selected: "
                                     + "/Users/a/report.pdf"))
    }

    func testPromptTextListsMultipleFinderPaths() {
        let text = HUDContextSnapshot(
            frontmostAppName: nil, clipboardKind: .empty,
            clipboardText: nil,
            finderSelectionPaths: ["/a.pdf", "/b.txt"]).promptContextText()
        XCTAssertTrue(text!.contains("Finder has these items selected:"))
        XCTAssertTrue(text!.contains("/a.pdf"))
        XCTAssertTrue(text!.contains("/b.txt"))
    }

    func testPromptTextClipboardTextIncludedOnlyWhenKept() {
        let kept = HUDContextSnapshot(
            frontmostAppName: nil, clipboardKind: .text,
            clipboardText: "the copied words",
            finderSelectionPaths: []).promptContextText()
        XCTAssertTrue(kept!.contains("the copied words"))

        // Same kind, but the text was purged (switch off): the model
        // is told text exists, never what it says.
        let purged = HUDContextSnapshot.make(
            frontmostAppName: nil, clipboardKind: .text,
            clipboardText: "the copied words",
            finderSelectionPaths: [],
            clipboardSourceEnabled: false,
            filesSourceEnabled: false).promptContextText()
        XCTAssertTrue(purged!.contains("contents weren't shared"))
        XCTAssertFalse(purged!.contains("the copied words"))
    }

    func testPromptTextClipsLongClipboard() {
        let long = String(repeating: "x",
                          count: HUDContextSnapshot
                            .maxClipboardCharactersInPrompt + 500)
        let clipped = HUDContextSnapshot.clippedClipboardText(long)
        XCTAssertTrue(clipped.contains("only the first part was included"))
        XCTAssertLessThan(clipped.count,
                          HUDContextSnapshot.maxClipboardCharactersInPrompt
                            + 120)
        // Short text passes through untouched, in quotes.
        XCTAssertEqual(HUDContextSnapshot.clippedClipboardText("  hi  "),
                       "“hi”")
    }

    func testPromptTextNotesImageAndOtherClipboard() {
        let image = HUDContextSnapshot(
            frontmostAppName: nil, clipboardKind: .image,
            clipboardText: nil, finderSelectionPaths: []).promptContextText()
        XCTAssertTrue(image!.contains("clipboard holds an image"))
        let other = HUDContextSnapshot(
            frontmostAppName: nil, clipboardKind: .other,
            clipboardText: nil, finderSelectionPaths: []).promptContextText()
        XCTAssertTrue(other!.contains("isn't plain text or an image"))
    }

    // MARK: - Titling

    func testTitleFromPrompt() {
        XCTAssertEqual(HUDConversationNaming.title(forFirstPrompt: "resize this photo"),
                       "Quick — resize this photo")
    }

    func testTitleTidesWhitespaceAndNewlines() {
        XCTAssertEqual(
            HUDConversationNaming.title(forFirstPrompt: "  sum up\n  this   page "),
            "Quick — sum up this page")
    }

    func testTitleTruncatesLongPrompts() {
        let prompt = String(repeating: "word ", count: 30)
        let title = HUDConversationNaming.title(forFirstPrompt: prompt)
        XCTAssertTrue(title.hasPrefix("Quick — "))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(
            title.count,
            "Quick — ".count + HUDConversationNaming.maxPromptCharacters + 1)
    }

    func testTitleFallsBackForEmptyPrompt() {
        XCTAssertEqual(HUDConversationNaming.title(forFirstPrompt: ""),
                       HUDConversationNaming.fallbackTitle)
        XCTAssertEqual(HUDConversationNaming.title(forFirstPrompt: "   \n "),
                       HUDConversationNaming.fallbackTitle)
    }

    // MARK: - Session policy

    private let conversationID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testContinueWithinGrace() {
        XCTAssertTrue(HUDSessionPolicy.shouldContinue(
            previousConversationID: conversationID,
            dismissedAt: t0,
            now: t0.addingTimeInterval(60),
            previousStillExists: true,
            movedToMainWindow: false))
        // Exactly at the edge still counts as warm.
        XCTAssertTrue(HUDSessionPolicy.shouldContinue(
            previousConversationID: conversationID,
            dismissedAt: t0,
            now: t0.addingTimeInterval(HUDSessionPolicy.continueGrace),
            previousStillExists: true,
            movedToMainWindow: false))
    }

    func testFreshAfterGrace() {
        XCTAssertFalse(HUDSessionPolicy.shouldContinue(
            previousConversationID: conversationID,
            dismissedAt: t0,
            now: t0.addingTimeInterval(HUDSessionPolicy.continueGrace + 1),
            previousStillExists: true,
            movedToMainWindow: false))
    }

    func testFreshWhenMovedToMainWindow() {
        XCTAssertFalse(HUDSessionPolicy.shouldContinue(
            previousConversationID: conversationID,
            dismissedAt: t0,
            now: t0.addingTimeInterval(10),
            previousStillExists: true,
            movedToMainWindow: true))
    }

    func testFreshWhenDeletedOrNeverExisted() {
        XCTAssertFalse(HUDSessionPolicy.shouldContinue(
            previousConversationID: conversationID,
            dismissedAt: t0,
            now: t0.addingTimeInterval(10),
            previousStillExists: false,
            movedToMainWindow: false))
        XCTAssertFalse(HUDSessionPolicy.shouldContinue(
            previousConversationID: nil,
            dismissedAt: t0,
            now: t0.addingTimeInterval(10),
            previousStillExists: true,
            movedToMainWindow: false))
        XCTAssertFalse(HUDSessionPolicy.shouldContinue(
            previousConversationID: conversationID,
            dismissedAt: nil,
            now: t0,
            previousStillExists: true,
            movedToMainWindow: false))
    }
}
