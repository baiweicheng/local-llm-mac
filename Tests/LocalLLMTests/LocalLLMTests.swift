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

    // MARK: - Recap

    func testRecapIsNilWithoutHistory() {
        XCTAssertNil(PromptHistory.recap(of: []))
    }

    func testRecapRendersTurnsAsTranscript() {
        let history = [ChatTurn(role: .user, text: "What is 2+2?"),
                       ChatTurn(role: .assistant, text: "4")]
        let recap = PromptHistory.recap(of: history)
        XCTAssertNotNil(recap)
        XCTAssertTrue(recap!.contains("Earlier in this conversation:"))
        XCTAssertTrue(recap!.contains("User: What is 2+2?"))
        XCTAssertTrue(recap!.contains("Assistant: 4"))
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

    // MARK: - Phase 2 helpers

    /// A turn whose text estimates to exactly `tokens` tokens (4 chars
    /// per token), optionally carrying images.
    private func turn(_ role: MessageRole, tokens: Int, attachments: Int = 0) -> ChatTurn {
        ChatTurn(role: role,
                 text: String(repeating: "a", count: tokens * 4),
                 attachmentCount: attachments)
    }

    /// `pairs` user+assistant exchanges, each turn `turnTokens` tokens.
    private func pairs(_ count: Int, turnTokens: Int) -> [ChatTurn] {
        (0..<count).flatMap { _ in
            [turn(.user, tokens: turnTokens), turn(.assistant, tokens: turnTokens)]
        }
    }

    // MARK: - Phase 2: context budgets

    func testBudgetTableCoversEveryBackend() {
        XCTAssertEqual(ContextBudget.table.count,
                       ContextBudget.Backend.allCases.count)
        let onDevice = ContextBudget.onDevice
        XCTAssertEqual(onDevice.windowTokens, 4_096)
        XCTAssertEqual(onDevice.promptAllowanceTokens, 3_584)
        XCTAssertEqual(onDevice.summaryTargetTokens, 512)
        XCTAssertEqual(ContextBudget.budget(for: .privateCloudCompute).windowTokens,
                       32_768)
        XCTAssertGreaterThan(ContextBudget.budget(for: .mlxLocal).windowTokens,
                             onDevice.windowTokens)
    }

    // MARK: - Phase 2: compaction planning

    func testPlanNoCompactionWhenConversationFits() {
        let turns = [turn(.user, tokens: 100), turn(.assistant, tokens: 100)]
        let plan = ContextManager.plan(budget: .onDevice,
                                       instructions: "Be brief.",
                                       existingSummary: nil,
                                       liveTurns: turns,
                                       newPrompt: turn(.user, tokens: 50))
        XCTAssertFalse(plan.needsCompaction)
        XCTAssertTrue(plan.turnsToSummarize.isEmpty)
        XCTAssertEqual(plan.recentTurns, turns)
        XCTAssertFalse(plan.overflowWarning)
        XCTAssertEqual(plan.projectedTokens, 252) // 2 + 200 + 50
    }

    func testPlanCompactsOldestKeepingRecentPairs() {
        let turns = pairs(8, turnTokens: 250) // 4,000 tokens of history
        let plan = ContextManager.plan(budget: .onDevice,
                                       instructions: "Be brief.",
                                       existingSummary: nil,
                                       liveTurns: turns,
                                       newPrompt: turn(.user, tokens: 100))
        XCTAssertTrue(plan.needsCompaction)
        XCTAssertEqual(plan.turnsToSummarize, Array(turns.prefix(6)))
        XCTAssertEqual(plan.recentTurns, Array(turns.dropFirst(6)))
        XCTAssertEqual(plan.recentTurns.first?.role, .user)
        XCTAssertFalse(plan.overflowWarning)
        XCTAssertEqual(plan.projectedTokens, 3_114) // 2 + 512 + 2,500 + 100
    }

    func testPlanNeverSummarizesTheOnlyExchange() {
        // One enormous exchange: nothing may be folded away, so the plan
        // reports overflow instead of compacting.
        let turns = [turn(.user, tokens: 3_000), turn(.assistant, tokens: 3_000)]
        let plan = ContextManager.plan(budget: .onDevice,
                                       instructions: "Be brief.",
                                       existingSummary: nil,
                                       liveTurns: turns,
                                       newPrompt: turn(.user, tokens: 100))
        XCTAssertFalse(plan.needsCompaction)
        XCTAssertTrue(plan.turnsToSummarize.isEmpty)
        XCTAssertEqual(plan.recentTurns, turns)
        XCTAssertTrue(plan.overflowWarning)
    }

    func testPlanCountsImageAttachments() {
        // Text alone is tiny (25 tokens a turn); the images (1,600
        // tokens a pair) are what push this history over the limit.
        let withImages = (0..<3).flatMap { _ in
            [turn(.user, tokens: 25, attachments: 4),
             turn(.assistant, tokens: 25)]
        }
        let plan = ContextManager.plan(budget: .onDevice,
                                       instructions: "Be brief.",
                                       existingSummary: nil,
                                       liveTurns: withImages,
                                       newPrompt: turn(.user, tokens: 100))
        XCTAssertTrue(plan.needsCompaction)
        XCTAssertEqual(plan.turnsToSummarize.count, 4)
        XCTAssertEqual(plan.recentTurns.count, 2)

        let textOnly = withImages.map {
            ChatTurn(role: $0.role, text: $0.text, attachmentCount: 0)
        }
        let fitsPlan = ContextManager.plan(budget: .onDevice,
                                           instructions: "Be brief.",
                                           existingSummary: nil,
                                           liveTurns: textOnly,
                                           newPrompt: turn(.user, tokens: 100))
        XCTAssertFalse(fitsPlan.needsCompaction)
    }

    func testPlanCapsOneSummarizerPass() {
        // 10,000 tokens of history: one pass may only fold the oldest
        // chunk that itself fits the window (~3,364 tokens here); the
        // rest stays verbatim until the next pass.
        let turns = pairs(20, turnTokens: 250)
        let plan = ContextManager.plan(budget: .onDevice,
                                       instructions: "Be brief.",
                                       existingSummary: nil,
                                       liveTurns: turns,
                                       newPrompt: turn(.user, tokens: 100))
        XCTAssertTrue(plan.needsCompaction)
        XCTAssertEqual(plan.turnsToSummarize.count, 13)
        XCTAssertEqual(plan.recentTurns.count, 27)
        XCTAssertTrue(plan.overflowWarning) // until later passes run
    }

    func testPlanCountsExistingSummary() {
        let summary = String(repeating: "s", count: 2_000) // 500 tokens
        let turns = pairs(6, turnTokens: 250)
        let plan = ContextManager.plan(budget: .onDevice,
                                       instructions: "Be brief.",
                                       existingSummary: summary,
                                       liveTurns: turns,
                                       newPrompt: turn(.user, tokens: 100))
        XCTAssertTrue(plan.needsCompaction)
        XCTAssertEqual(plan.turnsToSummarize.count, 2)
        XCTAssertEqual(plan.recentTurns.count, 10)
    }

    // MARK: - Phase 2: summaries

    func testMergedSummary() {
        XCTAssertEqual(ContextManager.mergedSummary(existing: nil, new: "B"), "B")
        XCTAssertEqual(ContextManager.mergedSummary(existing: "", new: "B"), "B")
        XCTAssertEqual(ContextManager.mergedSummary(existing: "A", new: "B"), "A\nB")
    }

    func testSummarizerInputIncludesExistingSummaryAndTurns() {
        let input = ContextManager.summarizerInput(
            existingSummary: "They planned a trip.",
            turns: [ChatTurn(role: .user, text: "Add Lisbon."),
                    ChatTurn(role: .assistant, text: "Done.")],
            targetTokens: 512)
        XCTAssertTrue(input.contains("Summary so far:"))
        XCTAssertTrue(input.contains("They planned a trip."))
        XCTAssertTrue(input.contains("User: Add Lisbon."))
        XCTAssertTrue(input.contains("384 words")) // 512 * 3/4
    }

    func testMechanicalFallbackNotesTrimmedTopics() {
        let dropped = [ChatTurn(role: .user, text: "What is the capital of France?"),
                       ChatTurn(role: .assistant, text: "Paris.")]
        let fallback = ContextManager.mechanicalFallbackSummary(
            existing: nil, droppedTurns: dropped)
        XCTAssertTrue(fallback.contains("trimmed to make room"))
        XCTAssertTrue(fallback.contains("\"What is the capital of France?\""))

        let merged = ContextManager.mechanicalFallbackSummary(
            existing: "Base summary.", droppedTurns: dropped)
        XCTAssertTrue(merged.hasPrefix("Base summary.\n"))
    }

    func testSeedTextWithSummary() {
        let seed = ContextManager.seedText(
            existingSummary: "They discussed budgets.",
            recentTurns: [ChatTurn(role: .user, text: "What's next?")])
        XCTAssertTrue(seed.contains("Summary of the earlier part"))
        XCTAssertTrue(seed.contains("They discussed budgets."))
        XCTAssertTrue(seed.contains("Most recent messages:"))
        XCTAssertTrue(seed.contains("User: What's next?"))
    }

    func testSeedTextWithoutSummaryMatchesRecap() {
        let turns = [ChatTurn(role: .user, text: "Hi"),
                     ChatTurn(role: .assistant, text: "Hello")]
        XCTAssertEqual(ContextManager.seedText(existingSummary: nil,
                                               recentTurns: turns),
                       PromptHistory.recap(of: turns))
        XCTAssertEqual(ContextManager.seedText(existingSummary: nil,
                                               recentTurns: []), "")
    }

    func testTranscriptNotesAttachments() {
        let line = ContextManager.transcript(
            of: [ChatTurn(role: .user, text: "look", attachmentCount: 2)])
        XCTAssertEqual(line, "User: look [2 image(s) attached]")
    }

    // MARK: - Phase 2: attachment coding

    func testAttachmentCodecRoundTrip() {
        let attachments = [
            ImageAttachment(data: Data([1, 2, 3]), pixelWidth: 3, pixelHeight: 2),
            ImageAttachment(data: Data(repeating: 7, count: 100)),
        ]
        let blob = ImageAttachmentCodec.encode(attachments)
        XCTAssertNotNil(blob)
        XCTAssertEqual(ImageAttachmentCodec.decode(blob), attachments)
    }

    func testAttachmentCodecDropsInvalidAndCapsCount() {
        XCTAssertNil(ImageAttachmentCodec.encode([]))
        XCTAssertNil(ImageAttachmentCodec.encode([ImageAttachment(data: Data())]))
        XCTAssertEqual(ImageAttachmentCodec.decode(nil), [])
        XCTAssertEqual(ImageAttachmentCodec.decode(Data("garbage".utf8)), [])

        let six = (0..<6).map { _ in ImageAttachment(data: Data([9])) }
        XCTAssertEqual(ImageAttachmentCodec.decode(
            ImageAttachmentCodec.encode(six)).count,
            ImageAttachmentCodec.maxAttachmentsPerMessage)

        let oversize = ImageAttachment(
            data: Data(count: ImageAttachmentCodec.maxStoredBytesPerImage + 1))
        XCTAssertFalse(ImageAttachmentCodec.isValid(data: oversize.data))
        XCTAssertNil(ImageAttachmentCodec.encode([oversize]))
        XCTAssertTrue(ImageAttachmentCodec.isValid(
            data: Data(count: ImageAttachmentCodec.maxStoredBytesPerImage)))
    }

    func testEstimatedTokensIncludeImages() {
        let total = PromptHistory.estimatedContextTokens(
            instructions: "abcd",
            turns: [ChatTurn(role: .user, text: "aaaa", attachmentCount: 2)])
        XCTAssertEqual(total, 1 + 1 + 2 * ImageAttachmentCodec.estimatedTokensPerImage)
        XCTAssertEqual(ContextManager.tokens(
            for: ChatTurn(role: .user, text: "aaaa", attachmentCount: 2)), total - 1)
    }
}
