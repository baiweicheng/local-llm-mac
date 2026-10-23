import XCTest
@testable import LocalLLM

/// Tests for the pure logic — instructions merging, token estimation,
/// history recaps, and the markdown block splitter. Nothing here touches
/// the real on-device model, so the suite runs anywhere: in Xcode, use
/// Product → Test (⌘U) after the app builds.
final class LocalLLMTests: XCTestCase {

    // MARK: - Instructions

    func testMergedInstructionsFallsBackToDefaultWhenEmpty() {
        XCTAssertEqual(PromptHistory.mergedInstructions(userInstructions: ""),
                       PromptHistory.defaultInstructions)
        XCTAssertEqual(PromptHistory.mergedInstructions(userInstructions: "   \n "),
                       PromptHistory.defaultInstructions)
    }

    func testMergedInstructionsUsesCustomTextTrimmed() {
        XCTAssertEqual(PromptHistory.mergedInstructions(userInstructions: "  Be brief. "),
                       "Be brief.")
    }

    // MARK: - Token estimation

    func testTokenEstimateIsZeroForEmptyAndRoughlyFourCharsPerToken() {
        XCTAssertEqual(PromptHistory.approximateTokenCount(for: ""), 0)
        XCTAssertEqual(PromptHistory.approximateTokenCount(for: "abcd"), 1)
        XCTAssertEqual(PromptHistory.approximateTokenCount(for: String(repeating: "a", count: 400)), 100)
    }

    func testContextEstimateIncludesInstructionsAndTurns() {
        let turns = [ChatTurn(role: .user, text: "hello"),
                     ChatTurn(role: .assistant, text: "hi there")]
        let total = PromptHistory.estimatedContextTokens(instructions: "abcd", turns: turns)
        XCTAssertGreaterThan(total, PromptHistory.approximateTokenCount(for: "abcd"))
    }

    // MARK: - Recap / prompt assembly

    func testRecapIsNilWithoutHistory() {
        XCTAssertNil(PromptHistory.recap(of: []))
        XCTAssertEqual(
            PromptHistory.promptForModel(userText: "Hi", priorTurns: [], sessionIsFresh: true),
            "Hi")
    }

    func testPromptForModelIncludesRecapOnlyForFreshSessions() {
        let history = [ChatTurn(role: .user, text: "What is 2+2?"),
                       ChatTurn(role: .assistant, text: "4")]
        let fresh = PromptHistory.promptForModel(userText: "And 3+3?",
                                                 priorTurns: history,
                                                 sessionIsFresh: true)
        XCTAssertTrue(fresh.contains("Earlier in this conversation:"))
        XCTAssertTrue(fresh.contains("User: What is 2+2?"))
        XCTAssertTrue(fresh.hasSuffix("And 3+3?"))

        let ongoing = PromptHistory.promptForModel(userText: "And 3+3?",
                                                   priorTurns: history,
                                                   sessionIsFresh: false)
        XCTAssertEqual(ongoing, "And 3+3?")
    }

    // MARK: - Markdown blocks

    func testMarkdownPlainTextIsOneParagraph() {
        XCTAssertEqual(MarkdownBlocks.parse("Hello there."),
                       [.paragraph("Hello there.")])
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
    }

    func testMarkdownSplitsParagraphsOnBlankLines() {
        XCTAssertEqual(MarkdownBlocks.parse("One.\n\nTwo."),
                       [.paragraph("One."), .paragraph("Two.")])
    }

    func testMarkdownExtractsFencedCodeWithLanguage() {
        let text = "Here:\n\n```swift\nlet x = 1\n```\n\nDone."
        XCTAssertEqual(MarkdownBlocks.parse(text),
                       [.paragraph("Here:"),
                        .code(code: "let x = 1", language: "swift"),
                        .paragraph("Done.")])
    }

    func testMarkdownUnclosedFenceStillRendersAsCode() {
        // Happens mid-stream, before the closing fence arrives.
        XCTAssertEqual(MarkdownBlocks.parse("```\nlet y = 2"),
                       [.code(code: "let y = 2", language: nil)])
    }

    // MARK: - Availability presentation

    func testAvailabilityStatesOnlyAvailableCanChat() {
        XCTAssertTrue(ModelAvailabilityState.available.canChat)
        for state in [ModelAvailabilityState.appleIntelligenceNotEnabled,
                      .deviceNotEligible, .modelNotReady, .unknown] {
            XCTAssertFalse(state.canChat)
            XCTAssertFalse(state.headline.isEmpty)
            XCTAssertFalse(state.explanation.isEmpty)
        }
    }
}
