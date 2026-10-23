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

    // MARK: - Phase 3: model selection codec

    func testModelSelectionStorageRoundTrip() {
        XCTAssertEqual(ModelSelection.onDevice.storageKey, "onDevice")
        XCTAssertEqual(ModelSelection(storageKey: "onDevice"), .onDevice)

        let mlx = ModelSelection.mlx(
            repoID: "mlx-community/gemma-4-12B-it-4bit")
        XCTAssertEqual(mlx.storageKey,
                       "mlx:mlx-community/gemma-4-12B-it-4bit")
        XCTAssertEqual(ModelSelection(storageKey: mlx.storageKey), mlx)

        let endpointID = UUID()
        let endpoint = ModelSelection.endpoint(id: endpointID)
        XCTAssertEqual(ModelSelection(storageKey: endpoint.storageKey),
                       endpoint)
    }

    func testModelSelectionUnknownKeysFallBackToOnDevice() {
        // A value from a newer app version, a corrupt store, or a model
        // reference this build doesn't understand must never strand a
        // chat — it reads back as the built-in model.
        XCTAssertEqual(ModelSelection(storageKey: ""), .onDevice)
        XCTAssertEqual(ModelSelection(storageKey: "  "), .onDevice)
        XCTAssertEqual(ModelSelection(storageKey: "mlx:"), .onDevice)
        XCTAssertEqual(ModelSelection(storageKey: "endpoint:not-a-uuid"),
                       .onDevice)
        XCTAssertEqual(ModelSelection(storageKey: "cloud:gpt-99"), .onDevice)
    }

    func testModelSelectionBudgets() {
        // Auto plans against the tightest budget until it resolves.
        XCTAssertEqual(ModelSelection.auto.budget.windowTokens, 4_096)
        XCTAssertEqual(ModelSelection.onDevice.budget.windowTokens, 4_096)
        XCTAssertEqual(ModelSelection.mlx(repoID: "x").budget.windowTokens,
                       ContextBudget.mlxLocal.windowTokens)
        XCTAssertEqual(
            ModelSelection.endpoint(id: UUID()).budget.windowTokens,
            ContextBudget.mlxLocal.windowTokens)
    }

    func testConversationPersistsModelSelection() {
        let conversation = Conversation()
        // Phase 4: a brand-new chat starts on Auto.
        XCTAssertEqual(conversation.modelSelection, .auto)

        let mlx = ModelSelection.mlx(repoID: "mlx-community/Qwen2.5-14B-Instruct-4bit")
        conversation.modelSelection = mlx
        XCTAssertEqual(conversation.modelSelectionRaw, mlx.storageKey)
        XCTAssertEqual(conversation.modelSelection, mlx)

        conversation.modelSelectionRaw = "endpoint:not-a-uuid"
        XCTAssertEqual(conversation.modelSelection, .onDevice)
    }

    // MARK: - Phase 3: backend registry

    func testRegistryOrderAndBudgets() {
        let downloaded = [MLXCatalog.models[1], MLXCatalog.models[0]]
        // Registry orders MLX rows as given (the store passes catalog
        // order); endpoints follow in their saved order.
        let rows = BackendRegistry.descriptors(
            downloadedMLX: downloaded,
            endpoints: EndpointConfig.defaultConfigs,
            onDeviceReady: true)
        // Phase 4: Auto leads the picker, then the built-in model.
        XCTAssertEqual(rows.count, 1 + 1 + 2 + 2)
        XCTAssertEqual(rows[0].selection, .auto)
        XCTAssertEqual(rows[0].displayName, "Auto")
        XCTAssertTrue(rows[0].isReady)
        XCTAssertEqual(rows[1].selection, .onDevice)
        XCTAssertEqual(rows[1].displayName, "Apple On-Device")
        XCTAssertEqual(rows[1].budget.windowTokens, 4_096)
        XCTAssertTrue(rows[1].isReady)
        XCTAssertEqual(rows[2].selection, .mlx(repoID: downloaded[0].repoID))
        XCTAssertEqual(rows[2].budget.windowTokens,
                       ContextBudget.mlxLocal.windowTokens)
        XCTAssertEqual(rows[4].selection,
                       .endpoint(id: EndpointConfig.ollamaPresetID))
        XCTAssertEqual(rows[5].displayName, "LM Studio")
    }

    func testRegistryOnDeviceReadinessAndLookup() {
        let rows = BackendRegistry.descriptors(
            downloadedMLX: [], endpoints: [], onDeviceReady: false)
        // Phase 4: Auto + the built-in model; Auto stays "ready" (it
        // falls back gracefully), the on-device row reports the truth.
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].selection, .auto)
        XCTAssertTrue(rows[0].isReady)
        XCTAssertFalse(rows[1].isReady)

        // A selection for a model that isn't downloaded has no row.
        let missing = BackendRegistry.descriptor(
            for: .mlx(repoID: MLXCatalog.models[0].repoID),
            downloadedMLX: [], endpoints: [], onDeviceReady: true)
        XCTAssertNil(missing)

        let found = BackendRegistry.descriptor(
            for: .endpoint(id: EndpointConfig.lmStudioPresetID),
            downloadedMLX: [],
            endpoints: EndpointConfig.defaultConfigs,
            onDeviceReady: true)
        XCTAssertEqual(found?.displayName, "LM Studio")
    }

    // MARK: - Phase 3: MLX catalog & memory fit

    func testCatalogTiersFitAn18GBMac() {
        XCTAssertEqual(MLXCatalog.models.count, 3)
        let sizes = MLXCatalog.models.map { $0.approximateBytes }
        XCTAssertEqual(sizes, sizes.sorted()) // small → large
        for info in MLXCatalog.models {
            XCTAssertTrue(info.repoID.hasPrefix("mlx-community/"))
            XCTAssertNotEqual(
                MLXCatalog.fit(bytes: info.approximateBytes, totalMemoryGB: 18),
                .tooBig, "\(info.displayName) should fit the target Mac")
        }
        XCTAssertEqual(
            MLXCatalog.fit(bytes: MLXCatalog.models[0].approximateBytes,
                           totalMemoryGB: 18), .comfortable)
        // The default (Gemma 4 12B, ≈6.5 GB ≈ 36% of 18 GB) sits in
        // the comfortable tier; only the 14B reaches "fits".
        XCTAssertEqual(MLXCatalog.models[1].repoID,
                       "mlx-community/gemma-4-12B-it-4bit")
        XCTAssertEqual(MLXCatalog.models[1].displayName, "Gemma 4 12B")
        XCTAssertEqual(
            MLXCatalog.fit(bytes: MLXCatalog.models[1].approximateBytes,
                           totalMemoryGB: 18), .comfortable)
        XCTAssertEqual(
            MLXCatalog.fit(bytes: MLXCatalog.models[2].approximateBytes,
                           totalMemoryGB: 18), .fits)
    }

    func testMemoryFitThresholds() {
        // 18 GB: comfortable up to 8.1 GB of weights, fits up to 10.8.
        XCTAssertEqual(MLXCatalog.fit(bytes: 8_100_000_000, totalMemoryGB: 18),
                       .comfortable)
        XCTAssertEqual(MLXCatalog.fit(bytes: 8_100_000_001, totalMemoryGB: 18),
                       .fits)
        XCTAssertEqual(MLXCatalog.fit(bytes: 10_800_000_000, totalMemoryGB: 18),
                       .fits)
        XCTAssertEqual(MLXCatalog.fit(bytes: 10_800_000_001, totalMemoryGB: 18),
                       .tooBig)
        // The 14B pick does not fit an 8 GB machine.
        XCTAssertEqual(MLXCatalog.fit(bytes: 8_400_000_000, totalMemoryGB: 8),
                       .tooBig)
        XCTAssertEqual(MLXCatalog.fit(bytes: 1_000_000_000, totalMemoryGB: 0),
                       .tooBig)
    }

    func testFormatBytes() {
        XCTAssertEqual(MLXCatalog.formatBytes(1_900_000_000), "1.9 GB")
        XCTAssertEqual(MLXCatalog.formatBytes(4_900_000_000), "4.9 GB")
        XCTAssertEqual(MLXCatalog.formatBytes(800_000_000), "0.8 GB")
        XCTAssertEqual(MLXCatalog.formatBytes(50_000_000), "50 MB")
        XCTAssertEqual(MLXCatalog.formatBytes(0), "0 MB")
    }

    func testDownloadPlannerFiltersAndSorts() {
        let siblings = [
            MLXDownloadPlanner.RemoteFile(path: "tokenizer.json", size: 10),
            MLXDownloadPlanner.RemoteFile(path: "README.md", size: 5),
            MLXDownloadPlanner.RemoteFile(path: "model.safetensors", size: 100),
            MLXDownloadPlanner.RemoteFile(path: ".gitattributes", size: 1),
            MLXDownloadPlanner.RemoteFile(path: "config.json", size: 2),
        ]
        let files = MLXDownloadPlanner.filesToDownload(from: siblings)
        XCTAssertEqual(files.map { $0.path },
                       ["config.json", "model.safetensors", "tokenizer.json"])
        XCTAssertEqual(MLXDownloadPlanner.totalBytes(of: files), 112)
        XCTAssertEqual(MLXCatalog.models[0].directoryName,
                       "mlx-community--Llama-3.2-3B-Instruct-4bit")
    }

    func testDownloadPlannerParsesFileList() {
        let json = """
            {"id": "mlx-community/X", "siblings": [
              {"rfilename": "config.json", "size": 42},
              {"rfilename": "model.safetensors"},
              {"size": 9}
            ]}
            """
        let files = MLXDownloadPlanner.parseFileList(jsonData: Data(json.utf8))
        XCTAssertEqual(files?.count, 2)
        XCTAssertEqual(files?[0],
                       MLXDownloadPlanner.RemoteFile(path: "config.json", size: 42))
        XCTAssertEqual(files?[1].size, 0) // size absent → 0, not a failure
        XCTAssertNil(MLXDownloadPlanner.parseFileList(
            jsonData: Data("not json".utf8)))
        XCTAssertNil(MLXDownloadPlanner.parseFileList(
            jsonData: Data("{}".utf8)))
    }

    // MARK: - Phase 3: endpoint configs

    func testEndpointPresets() {
        let ollama = EndpointConfig.ollamaPreset
        XCTAssertEqual(ollama.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(ollama.chatCompletionsURL?.absoluteString,
                       "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(ollama.hostDescription, "localhost:11434")
        XCTAssertEqual(ollama.pickerDetail, "llama3.1 · localhost:11434")

        let lmStudio = EndpointConfig.lmStudioPreset
        XCTAssertEqual(lmStudio.chatCompletionsURL?.absoluteString,
                       "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(lmStudio.pickerDetail, "localhost:1234")

        // A trailing slash on the base URL doesn't double the slash.
        var sloppy = ollama
        sloppy.baseURL = "http://localhost:11434/v1/"
        XCTAssertEqual(sloppy.chatCompletionsURL?.absoluteString,
                       "http://localhost:11434/v1/chat/completions")
        sloppy.baseURL = "   "
        XCTAssertNil(sloppy.chatCompletionsURL)
    }

    func testEndpointConfigCodecRoundTrip() {
        let configs = EndpointConfig.defaultConfigs
        let data = EndpointConfigCodec.encode(configs)
        XCTAssertEqual(EndpointConfigCodec.decode(data), configs)
        XCTAssertEqual(EndpointConfigCodec.decode(nil), [])
        XCTAssertEqual(EndpointConfigCodec.decode(Data()), [])
        XCTAssertEqual(EndpointConfigCodec.decode(Data("junk".utf8)), [])
    }

    // MARK: - Phase 3: endpoint request building

    func testRequestBuilderMessageOrder() {
        let history = [ChatMessagePayload(role: "user", content: "hi"),
                       ChatMessagePayload(role: "assistant", content: "hello")]
        let messages = OpenAIRequestBuilder.messages(
            instructions: "Be brief.", history: history,
            newUserMessage: "next?")
        XCTAssertEqual(messages.map { $0.role },
                       ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.first?.content, "Be brief.")
        XCTAssertEqual(messages.last?.content, "next?")

        // Empty instructions → no system message at all.
        let noSystem = OpenAIRequestBuilder.messages(
            instructions: "  ", history: [], newUserMessage: "hey")
        XCTAssertEqual(noSystem, [ChatMessagePayload(role: "user", content: "hey")])
    }

    func testRequestBodyJSON() throws {
        let body = OpenAIRequestBuilder.bodyData(
            model: "llama3.1", instructions: "Be brief.", history: [],
            newUserMessage: "hey")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "llama3.1")
        XCTAssertEqual(object["stream"] as? Bool, true)
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[1]["content"], "hey")
    }

    // MARK: - Phase 3: SSE parsing

    func testSSEAccumulatorContentDeltas() {
        var accumulator = SSEAccumulator()
        // Role-only first chunk: no content piece.
        XCTAssertNil(accumulator.consume(
            line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertEqual(accumulator.consume(
            line: #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#),
            "Hello")
        XCTAssertEqual(accumulator.consume(
            line: #"data: {"choices":[{"delta":{"content":" world"}}]}"#),
            "Hello world")
        XCTAssertEqual(accumulator.text, "Hello world")
        XCTAssertFalse(accumulator.isDone)
        // The [DONE] marker flips isDone and yields nothing.
        XCTAssertNil(accumulator.consume(line: "data: [DONE]"))
        XCTAssertTrue(accumulator.isDone)
    }

    func testSSEAccumulatorIgnoresJunk() {
        var accumulator = SSEAccumulator()
        XCTAssertNil(accumulator.consume(line: ""))
        XCTAssertNil(accumulator.consume(line: ": keep-alive"))
        XCTAssertNil(accumulator.consume(line: "event: message"))
        XCTAssertNil(accumulator.consume(line: "data: {not json"))
        XCTAssertNil(accumulator.consume(
            line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#))
        XCTAssertEqual(accumulator.text, "")
        // An explicitly empty content piece is real and returns the
        // (unchanged) accumulated text rather than nil.
        accumulator.consume(line: #"data: {"choices":[{"delta":{"content":"x"}}]}"#)
        XCTAssertEqual(accumulator.consume(
            line: #"data: {"choices":[{"delta":{"content":""}}]}"#), "x")
    }

    // MARK: - Phase 4: Auto selection codec

    func testAutoSelectionStorageRoundTrip() {
        XCTAssertEqual(ModelSelection.auto.storageKey, "auto")
        XCTAssertEqual(ModelSelection(storageKey: "auto"), .auto)
        XCTAssertTrue(ModelSelection.auto.isAuto)
        XCTAssertFalse(ModelSelection.auto.isOnDevice)
        // "auto" must not swallow lookalike legacy values.
        XCTAssertEqual(ModelSelection(storageKey: "automatic"), .onDevice)
    }

    func testIntentRawValuesMatchBrief() {
        // The classifier is instructed to answer with exactly these.
        XCTAssertEqual(PromptIntent(rawValue: "os_action"), .osAction)
        XCTAssertEqual(PromptIntent(rawValue: "quick_transform"), .quickTransform)
        XCTAssertEqual(PromptIntent(rawValue: "local_heavy"), .localHeavy)
        XCTAssertEqual(PromptIntent(rawValue: "frontier_cloud"), .frontierCloud)
        XCTAssertNil(PromptIntent(rawValue: "something_else"))
    }

    // MARK: - Phase 4: routing policy

    /// Inputs with nothing optional set up: no downloads, no servers.
    private func bareInputs(localOnly: Bool = false,
                            onDeviceReady: Bool = true) -> RoutingInputs {
        RoutingInputs(downloadedMLX: [], endpoints: [],
                      localOnly: localOnly, cloudAvailable: false,
                      onDeviceReady: onDeviceReady)
    }

    func testRoutingQuickAndActionGoToOnDevice() {
        let inputs = bareInputs()
        let quick = RoutingPolicy.decide(intent: .quickTransform, inputs: inputs)
        XCTAssertEqual(quick.selection, .onDevice)
        XCTAssertNil(quick.note)
        XCTAssertTrue(quick.reason.contains("Apple On-Device"))

        let action = RoutingPolicy.decide(intent: .osAction, inputs: inputs)
        XCTAssertEqual(action.selection, .onDevice)
        XCTAssertNil(action.note)
    }

    func testRoutingLocalHeavyPrefersLargestMLX() {
        // Deliberately unordered: the policy must pick by size,
        // not by position.
        var inputs = bareInputs()
        inputs.downloadedMLX = [MLXCatalog.models[1], MLXCatalog.models[2],
                                MLXCatalog.models[0]]
        let decision = RoutingPolicy.decide(intent: .localHeavy, inputs: inputs)
        XCTAssertEqual(decision.selection,
                       .mlx(repoID: MLXCatalog.models[2].repoID))
        XCTAssertTrue(decision.reason.contains("Qwen 2.5 14B"))
    }

    func testRoutingLocalHeavyFallsBackToEndpointThenOnDevice() {
        var inputs = bareInputs()
        inputs.endpoints = EndpointConfig.defaultConfigs
        let viaServer = RoutingPolicy.decide(intent: .localHeavy, inputs: inputs)
        XCTAssertEqual(viaServer.selection,
                       .endpoint(id: EndpointConfig.ollamaPresetID))

        let bare = RoutingPolicy.decide(intent: .localHeavy, inputs: bareInputs())
        XCTAssertEqual(bare.selection, .onDevice)
        XCTAssertTrue(bare.reason.contains("no bigger local model"))
    }

    func testRoutingLocalOnlySkipsEndpoints() {
        var inputs = bareInputs(localOnly: true)
        inputs.endpoints = EndpointConfig.defaultConfigs
        // Even for local_heavy, the lock keeps servers off the table.
        let heavy = RoutingPolicy.decide(intent: .localHeavy, inputs: inputs)
        XCTAssertEqual(heavy.selection, .onDevice)
        XCTAssertNotNil(heavy.note)

        // ...but a downloaded MLX model is still fair game.
        inputs.downloadedMLX = [MLXCatalog.models[1]]
        let heavyMLX = RoutingPolicy.decide(intent: .localHeavy, inputs: inputs)
        XCTAssertEqual(heavyMLX.selection,
                       .mlx(repoID: MLXCatalog.models[1].repoID))
    }

    func testRoutingFrontierCloudStandsInAndSaysSo() {
        // A server stands in first…
        var inputs = bareInputs()
        inputs.endpoints = EndpointConfig.defaultConfigs
        inputs.downloadedMLX = [MLXCatalog.models[2]]
        let viaServer = RoutingPolicy.decide(intent: .frontierCloud, inputs: inputs)
        XCTAssertEqual(viaServer.selection,
                       .endpoint(id: EndpointConfig.ollamaPresetID))
        XCTAssertTrue(viaServer.reason.contains("later phase"))
        XCTAssertTrue(viaServer.reason.contains("stands in"))

        // …then the biggest local model…
        inputs.endpoints = []
        let viaMLX = RoutingPolicy.decide(intent: .frontierCloud, inputs: inputs)
        XCTAssertEqual(viaMLX.selection, .mlx(repoID: MLXCatalog.models[2].repoID))
        XCTAssertTrue(viaMLX.reason.contains("stands in"))

        // …then the built-in model, honestly.
        let viaOnDevice = RoutingPolicy.decide(intent: .frontierCloud,
                                               inputs: bareInputs())
        XCTAssertEqual(viaOnDevice.selection, .onDevice)
        XCTAssertTrue(viaOnDevice.reason.contains("later phase"))
    }

    func testRoutingFrontierCloudLocalOnlyNeverPicksEndpoint() {
        var inputs = bareInputs(localOnly: true)
        inputs.endpoints = EndpointConfig.defaultConfigs
        let decision = RoutingPolicy.decide(intent: .frontierCloud, inputs: inputs)
        XCTAssertEqual(decision.selection, .onDevice)
        XCTAssertNotNil(decision.note)
    }

    func testRoutingStandsInWhenOnDeviceNotReady() {
        var inputs = bareInputs(onDeviceReady: false)
        inputs.downloadedMLX = [MLXCatalog.models[0]]
        let quick = RoutingPolicy.decide(intent: .quickTransform, inputs: inputs)
        XCTAssertEqual(quick.selection,
                       .mlx(repoID: MLXCatalog.models[0].repoID))
        XCTAssertNotNil(quick.note)

        // With nothing else available, routing still answers
        // on-device and lets its availability state explain itself.
        let stuck = RoutingPolicy.decide(
            intent: .quickTransform,
            inputs: bareInputs(onDeviceReady: false))
        XCTAssertEqual(stuck.selection, .onDevice)
    }

    // MARK: - Phase 4: local-only factory enforcement

    func testFactoryRefusesEndpointsWhenLocalOnly() {
        let endpoints = EndpointConfig.defaultConfigs
        let locked = BackendFactory.resolve(
            selection: .endpoint(id: EndpointConfig.ollamaPresetID),
            downloadedMLXRepoIDs: [], endpoints: endpoints, localOnly: true)
        XCTAssertEqual(locked.effectiveSelection, .onDevice)

        let open = BackendFactory.resolve(
            selection: .endpoint(id: EndpointConfig.ollamaPresetID),
            downloadedMLXRepoIDs: [], endpoints: endpoints, localOnly: false)
        XCTAssertEqual(open.effectiveSelection,
                       .endpoint(id: EndpointConfig.ollamaPresetID))

        // Auto arriving at the factory unresolved means "no routing
        // context" — the built-in model, never a crash.
        let auto = BackendFactory.resolve(
            selection: .auto, downloadedMLXRepoIDs: [], endpoints: endpoints)
        XCTAssertEqual(auto.effectiveSelection, .onDevice)
    }

    // MARK: - Phase 4: endpoint locality

    func testEndpointLocalhostDetection() {
        func config(_ url: String) -> EndpointConfig {
            EndpointConfig(id: UUID(), name: "X", baseURL: url, modelName: "")
        }
        XCTAssertTrue(config("http://localhost:11434/v1").isLocalhost)
        XCTAssertTrue(config("http://127.0.0.1:1234/v1").isLocalhost)
        XCTAssertTrue(config("http://[::1]:8080/v1").isLocalhost)
        XCTAssertFalse(config("http://192.168.1.20:11434/v1").isLocalhost)
        XCTAssertFalse(config("https://api.example.com/v1").isLocalhost)
        XCTAssertFalse(config("not a url").isLocalhost)
    }

    // MARK: - Phase 4: redactor

    func testRedactorMasksAPIKeyShapes() {
        let text = "Use sk-proj-abc123XYZ789def456 for the call, "
            + "token ghp_0123456789abcdefghijABCD and AKIAIOSFODNN7EXAMPLE."
        let result = Redactor.redact(text)
        XCTAssertFalse(result.text.contains("sk-proj-abc123XYZ789def456"))
        XCTAssertFalse(result.text.contains("ghp_0123456789abcdefghijABCD"))
        XCTAssertFalse(result.text.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertEqual(result.replacementCount, 3)
        XCTAssertTrue(result.text.contains(Redactor.mask))
    }

    func testRedactorMasksLabeledSecrets() {
        let result = Redactor.redact(
            "My password: hunter22! and api_key = abcdef123456 ok?")
        XCTAssertTrue(result.text.contains("password: \(Redactor.mask)"))
        XCTAssertTrue(result.text.contains("api_key = \(Redactor.mask)"))
        XCTAssertFalse(result.text.contains("hunter22"))
        XCTAssertFalse(result.text.contains("abcdef123456"))
        XCTAssertEqual(result.replacementCount, 2)
    }

    func testRedactorMasksEmailsPhonesAndCards() {
        let text = "Reach jane.doe+news@example-mail.com or (404) 555-0123; "
            + "card 4111 1111 1111 1111 or 4111-1111-1111-1111."
        let result = Redactor.redact(text)
        XCTAssertFalse(result.text.contains("jane.doe+news@example-mail.com"))
        XCTAssertFalse(result.text.contains("555-0123"))
        XCTAssertFalse(result.text.contains("4111"))
        XCTAssertEqual(result.replacementCount, 4)
    }

    func testRedactorMasksLongOpaqueTokens() {
        // A git-style SHA (hex, letters + digits, 40 chars) is
        // secret-shaped and goes; a long plain word stays.
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let result = Redactor.redact("commit \(sha) fixed it")
        XCTAssertEqual(result.replacementCount, 1)
        XCTAssertFalse(result.text.contains(sha))

        let wordy = Redactor.redact(
            "Antidisestablishmentarianism is a long word.")
        XCTAssertEqual(wordy.replacementCount, 0)
    }

    func testRedactorCustomTerms() {
        let result = Redactor.redact(
            "The FALCON launch moved to the falcon site.",
            customTerms: ["Falcon"])
        XCTAssertEqual(result.replacementCount, 2)
        XCTAssertFalse(result.text.lowercased().contains("falcon"))

        // Too-short terms are ignored rather than mangling the text.
        let short = Redactor.redact("a cat sat", customTerms: ["a", "at"])
        XCTAssertEqual(short.replacementCount, 0)
        XCTAssertEqual(short.text, "a cat sat")
    }

    func testRedactorLeavesOrdinaryTextAlone() {
        let text = "Please summarize chapter 3 for me. My order "
            + "12345678 shipped on 2026-10-23, and the meeting is at "
            + "10:30 on Friday."
        let result = Redactor.redact(text)
        XCTAssertEqual(result.replacementCount, 0)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.didRedact)
    }

    // MARK: - Phase 4: telemetry

    func testTelemetryLabels() {
        XCTAssertEqual(
            TelemetryFormat.label(for: .onDevice, displayName: "ignored"),
            "Apple On-Device")
        XCTAssertEqual(
            TelemetryFormat.label(for: .mlx(repoID: "x"),
                                  displayName: "Gemma 4 12B"),
            "Local MLX · Gemma 4 12B")
        XCTAssertEqual(
            TelemetryFormat.label(for: .endpoint(id: UUID()),
                                  displayName: "Ollama"),
            "Ollama")
    }

    func testTelemetryFormatting() {
        XCTAssertEqual(TelemetryFormat.durationText(0.4), "0.4s")
        XCTAssertEqual(TelemetryFormat.durationText(1.24), "1.2s")
        XCTAssertEqual(TelemetryFormat.durationText(65), "1m 5s")
        XCTAssertEqual(TelemetryFormat.costText(0), "$0.00")

        let pill = TelemetryFormat.line(for: MessageTelemetry(
            backendLabel: "Local MLX · Gemma 4 12B", seconds: 3.44,
            estimatedTokens: 210))
        XCTAssertEqual(pill, "Local MLX · Gemma 4 12B · 3.4s · ≈210 tokens · $0.00")

        // Zero-token replies (shouldn't happen, but) omit the segment.
        let bare = TelemetryFormat.line(for: MessageTelemetry(
            backendLabel: "Apple On-Device", seconds: 1.0,
            estimatedTokens: 0))
        XCTAssertEqual(bare, "Apple On-Device · 1.0s · $0.00")
    }

    func testMessageTelemetryRoundTrip() {
        let message = Message(role: .assistant, text: "hi")
        XCTAssertNil(message.telemetry)
        message.telemetry = MessageTelemetry(
            backendLabel: "Apple On-Device", seconds: 1.5,
            estimatedTokens: 42)
        XCTAssertEqual(message.telemetry?.backendLabel, "Apple On-Device")
        XCTAssertEqual(message.telemetry?.seconds, 1.5)
        XCTAssertEqual(message.telemetry?.estimatedTokens, 42)
        XCTAssertEqual(message.telemetry?.costUSD, 0)
        message.telemetry = nil
        XCTAssertNil(message.telemetry)
    }

    // MARK: - KV cache mode (MLX refinement after Phase 4)

    func testKVCacheModeDecodingFallsBackToEightBit() {
        XCTAssertEqual(KVCacheMode.defaultMode, .eightBit)
        // A fresh install has nothing stored — the default applies.
        XCTAssertEqual(KVCacheMode(storedValue: nil), .eightBit)
        // So does anything unrecognized (an older/newer version's
        // value, a hand-edited plist): never a crash, never a
        // stranded setting.
        XCTAssertEqual(KVCacheMode(storedValue: "banana"), .eightBit)
        XCTAssertEqual(KVCacheMode(storedValue: ""), .eightBit)
        XCTAssertEqual(KVCacheMode(storedValue: "off"), .off)
        XCTAssertEqual(KVCacheMode(storedValue: "eightBit"), .eightBit)
        XCTAssertEqual(KVCacheMode(storedValue: "fourBit"), .fourBit)
    }

    func testKVCacheModeStoredValueRoundTrips() {
        // The stored strings are a persistence contract — they must
        // not change spelling once written to a user's defaults.
        XCTAssertEqual(KVCacheMode.off.storedValue, "off")
        XCTAssertEqual(KVCacheMode.eightBit.storedValue, "eightBit")
        XCTAssertEqual(KVCacheMode.fourBit.storedValue, "fourBit")
        for mode in KVCacheMode.allCases {
            XCTAssertEqual(KVCacheMode(storedValue: mode.storedValue), mode)
        }
    }

    func testKVCacheModeParameterMapping() {
        // Off = no quantization at all.
        XCTAssertNil(KVCacheMode.off.parameters.bits)
        // The two quantized modes map to the library's preset values:
        // that many bits, groups of 64, compress from the first token.
        let eight = KVCacheMode.eightBit.parameters
        XCTAssertEqual(eight.bits, 8)
        XCTAssertEqual(eight.groupSize, 64)
        XCTAssertEqual(eight.compressionStart, 0)
        let four = KVCacheMode.fourBit.parameters
        XCTAssertEqual(four.bits, 4)
        XCTAssertEqual(four.groupSize, 64)
        XCTAssertEqual(four.compressionStart, 0)
    }

    func testKVCacheSessionReuseRule() {
        // MLX session + unchanged mode: reusable.
        XCTAssertTrue(KVCacheMode.sessionReusable(
            sessionMode: .eightBit, currentMode: .eightBit,
            selectionIsMLX: true))
        // MLX session + changed mode (either direction): retired, so
        // the next send rebuilds it under the new cache layout.
        XCTAssertFalse(KVCacheMode.sessionReusable(
            sessionMode: .eightBit, currentMode: .fourBit,
            selectionIsMLX: true))
        XCTAssertFalse(KVCacheMode.sessionReusable(
            sessionMode: .fourBit, currentMode: .off,
            selectionIsMLX: true))
        // Any other backend: the setting can't touch its cache, so it
        // never blocks reuse.
        XCTAssertTrue(KVCacheMode.sessionReusable(
            sessionMode: .eightBit, currentMode: .fourBit,
            selectionIsMLX: false))
        XCTAssertTrue(KVCacheMode.sessionReusable(
            sessionMode: .off, currentMode: .eightBit,
            selectionIsMLX: false))
        // The routing snapshot a send reads carries the default until
        // the app shell wires the live setting in.
        XCTAssertEqual(RoutingInputs().kvCacheMode, .defaultMode)
    }

    func testFactoryHandsKVCacheModeToMLXBackend() {
        let info = MLXCatalog.models[1] // Gemma 4 12B, the default
        let resolved = BackendFactory.resolve(
            selection: .mlx(repoID: info.repoID),
            downloadedMLXRepoIDs: [info.repoID], endpoints: [],
            kvCacheMode: .fourBit)
        let backend = resolved.backend as? MLXBackend
        XCTAssertNotNil(backend)
        XCTAssertEqual(backend?.kvCacheMode, .fourBit)

        // Without an explicit mode, the factory default is the
        // Settings default: 8-bit.
        let defaulted = BackendFactory.resolve(
            selection: .mlx(repoID: info.repoID),
            downloadedMLXRepoIDs: [info.repoID], endpoints: [])
        XCTAssertEqual((defaulted.backend as? MLXBackend)?.kvCacheMode,
                       .eightBit)
    }

    @MainActor
    func testKVCacheModePersistsInSettings() {
        let suite = "LocalLLMTests.kvCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Fresh defaults: the 8-bit default, nothing written yet.
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.kvCacheMode, .eightBit)

        // Changing it persists immediately — a fresh settings object
        // over the same defaults reads the new value back.
        settings.kvCacheMode = .fourBit
        XCTAssertEqual(AppSettings(defaults: defaults).kvCacheMode,
                       .fourBit)
        settings.kvCacheMode = .off
        XCTAssertEqual(AppSettings(defaults: defaults).kvCacheMode, .off)
    }
}
