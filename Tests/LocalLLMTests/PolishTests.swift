import XCTest
@testable import LocalLLM

/// Phase 10 tests: the polish pass's pure logic — the instructions
/// library (codec + naming rules + settings persistence), the
/// default model for new chats (persistence through the existing
/// `ModelSelection` codec), chat search (matching + snippets), and
/// the Markdown export (golden documents + file names). The bundle
/// script, the login-item wrapper, and the save panel are exercised
/// on the Mac.
final class PolishTests: XCTestCase {

    // MARK: - Instructions library: codec

    func testPresetCodecRoundTrip() {
        let presets = [
            InstructionPreset(name: "Beginner mode",
                              text: "Explain like I'm a beginner."),
            InstructionPreset(name: "Résumé — 日本語",
                              text: "Be brief.\nTwo lines max."),
        ]
        let data = InstructionPresetCodec.encode(presets)
        XCTAssertNotNil(data)
        XCTAssertEqual(InstructionPresetCodec.decode(data!), presets)
    }

    func testPresetCodecJunkDecodesToEmpty() {
        XCTAssertEqual(InstructionPresetCodec.decode(Data("junk".utf8)), [])
        XCTAssertEqual(InstructionPresetCodec.decode(Data()), [])
    }

    // MARK: - Instructions library: naming rules

    func testPresetRulesRefuseBlankAndDuplicates() {
        let existing = [InstructionPreset(name: "Brief", text: "Be brief.")]
        XCTAssertFalse(InstructionPresetRules.canSave(
            name: "  ", text: "Something.", existing: existing))
        XCTAssertFalse(InstructionPresetRules.canSave(
            name: "New", text: "   ", existing: existing))
        XCTAssertFalse(InstructionPresetRules.canSave(
            name: "brief", text: "Short answers.", existing: existing))
        XCTAssertFalse(InstructionPresetRules.canSave(
            name: " Brief ", text: "Short answers.", existing: existing))
        XCTAssertTrue(InstructionPresetRules.canSave(
            name: "Detailed", text: "Long answers.", existing: existing))
        // Editing a preset may keep its own name.
        XCTAssertTrue(InstructionPresetRules.canSave(
            name: "Brief", text: "Even shorter.", existing: existing,
            excludingID: existing[0].id))
    }

    // MARK: - Instructions library: settings

    @MainActor
    func testSettingsPresetsAddUpdateRemoveAndPersist() {
        let suite = "LocalLLMTests.polish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.instructionPresets.isEmpty)

        let saved = settings.addInstructionPreset(
            name: "  Beginner mode  ", text: " Explain gently. ")
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.name, "Beginner mode")
        XCTAssertEqual(saved?.text, "Explain gently.")
        // A duplicate name (any case) is refused.
        XCTAssertNil(settings.addInstructionPreset(
            name: "beginner MODE", text: "Other text."))

        let reread = AppSettings(defaults: defaults)
        XCTAssertEqual(reread.instructionPresets, [saved!])

        XCTAssertTrue(settings.updateInstructionPreset(
            id: saved!.id, name: "Expert mode", text: "Skip the basics."))
        XCTAssertEqual(settings.instructionPresets.first?.name, "Expert mode")
        XCTAssertFalse(settings.updateInstructionPreset(
            id: UUID(), name: "Ghost", text: "Boo."))

        settings.removeInstructionPreset(id: saved!.id)
        XCTAssertTrue(settings.instructionPresets.isEmpty)
        XCTAssertTrue(AppSettings(defaults: defaults).instructionPresets.isEmpty)
    }

    // MARK: - Default model for new chats

    @MainActor
    func testSettingsDefaultModelDefaultsToAuto() {
        let suite = "LocalLLMTests.polish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).defaultModelSelection,
                       .auto)
    }

    @MainActor
    func testSettingsDefaultModelPersistsAcrossInstances() {
        let suite = "LocalLLMTests.polish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.defaultModelSelection = .onDevice
        XCTAssertEqual(AppSettings(defaults: defaults).defaultModelSelection,
                       .onDevice)

        settings.defaultModelSelection = .mlx(repoID: "mlx-community/gemma-4-12B-it-4bit")
        XCTAssertEqual(AppSettings(defaults: defaults).defaultModelSelection,
                       .mlx(repoID: "mlx-community/gemma-4-12B-it-4bit"))

        // A model id containing a colon (OpenRouter's ":free"
        // variants) survives the round trip.
        settings.defaultModelSelection = .openRouter(modelID: "some/model:free")
        XCTAssertEqual(AppSettings(defaults: defaults).defaultModelSelection,
                       .openRouter(modelID: "some/model:free"))

        settings.defaultModelSelection = .privateCloudCompute
        XCTAssertEqual(AppSettings(defaults: defaults).defaultModelSelection,
                       .privateCloudCompute)
    }

    // MARK: - Chat search

    func testSearchEmptyQueryNeverHits() {
        XCTAssertNil(ChatSearch.hit(title: "Anything",
                                    messageTexts: ["everything"], query: ""))
        XCTAssertNil(ChatSearch.hit(title: "Anything",
                                    messageTexts: ["everything"], query: "   "))
    }

    func testSearchTitleOnlyMatch() {
        let hit = ChatSearch.hit(title: "Revenue plan",
                                 messageTexts: ["hello", "unrelated"],
                                 query: "revenue")
        XCTAssertEqual(hit?.titleMatched, true)
        XCTAssertNil(hit?.snippet)
    }

    func testSearchMessageMatchSnippetContainsQuery() {
        let hit = ChatSearch.hit(
            title: "Chat",
            messageTexts: ["Please find the Revenue figures attached"],
            query: "revenue")
        XCTAssertEqual(hit?.titleMatched, false)
        // Short text: the snippet is the whole line, no ellipses.
        XCTAssertEqual(hit?.snippet,
                       "Please find the Revenue figures attached")
    }

    func testSearchIsCaseAndAccentInsensitive() {
        let hit = ChatSearch.hit(title: "Weekend",
                                 messageTexts: ["Meet me at the café on Fifth."],
                                 query: "CAFE")
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.snippet?.contains("café") ?? false)
    }

    func testSearchFirstMatchingMessageWins() {
        let hit = ChatSearch.hit(
            title: "Chat",
            messageTexts: ["nothing here", "first revenue note",
                           "second revenue note"],
            query: "revenue")
        XCTAssertEqual(hit?.snippet, "first revenue note")
    }

    func testSearchNoMatchReturnsNil() {
        XCTAssertNil(ChatSearch.hit(title: "Groceries",
                                    messageTexts: ["milk", "eggs"],
                                    query: "revenue"))
    }

    func testSearchNormalizesQueryWhitespace() {
        // UAT-09: the query is collapsed exactly like the text it
        // is matched against.
        XCTAssertEqual(ChatSearch.normalizedQuery("  body \t fat \n"),
                       "body fat")
        XCTAssertEqual(ChatSearch.normalizedQuery("revenue"), "revenue")
        XCTAssertEqual(ChatSearch.normalizedQuery("   "), "")
    }

    func testSearchQueryWithIrregularSpacingStillMatches() {
        // UAT-09: "body  fat" (double space) must find the
        // single-spaced message text — before the fix this
        // falsely reported "No chats match".
        let hit = ChatSearch.hit(
            title: "Chat",
            messageTexts: ["Notes on my body fat goal"],
            query: "body  fat")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.snippet, "Notes on my body fat goal")
    }

    func testSearchTitleWithIrregularSpacingStillMatches() {
        // UAT-09, mirror image: irregular spacing in the TITLE
        // must not hide it from a normally typed query either.
        let hit = ChatSearch.hit(title: "Body  fat log",
                                 messageTexts: [], query: "body fat")
        XCTAssertEqual(hit?.titleMatched, true)
    }

    func testSnippetCollapsesWhitespaceAndMarksCuts() {
        let text = (0..<30).map { _ in "word" }.joined(separator: " ")
            + " target here "
            + (0..<30).map { _ in "more" }.joined(separator: " ")
        let snippet = ChatSearch.snippet(in: text, matching: "target")
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.hasPrefix("…"))
        XCTAssertTrue(snippet!.hasSuffix("…"))
        XCTAssertTrue(snippet!.contains("target here"))
        // Cut edges land on word boundaries, never mid-word.
        XCTAssertFalse(snippet!.contains("…ord"))
        XCTAssertTrue(snippet!.hasSuffix("more…"))
    }

    func testSnippetFlattensNewlines() {
        let snippet = ChatSearch.snippet(
            in: "line one\n\nline   two mentions revenue",
            matching: "revenue")
        XCTAssertEqual(snippet, "line one line two mentions revenue")
    }

    // MARK: - Markdown export

    private var gmt: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private func goldenMessages() -> [ConversationExport.MessageInput] {
        [
            ConversationExport.MessageInput(
                role: .user,
                createdAt: Date(timeIntervalSince1970: 1_792_764_900),
                text: "Hello there.",
                attachmentCount: 2),
            ConversationExport.MessageInput(
                role: .assistant,
                createdAt: Date(timeIntervalSince1970: 1_792_764_960),
                text: "Hi! How can I help?",
                telemetry: MessageTelemetry(
                    backendLabel: "Apple On-Device", seconds: 1.2,
                    estimatedTokens: 96)),
        ]
    }

    func testExportGoldenDocument() {
        let markdown = ConversationExport.markdown(
            title: "Weekend Plans",
            createdAt: Date(timeIntervalSince1970: 1_792_764_900),
            updatedAt: Date(timeIntervalSince1970: 1_792_767_720),
            exportedAt: Date(timeIntervalSince1970: 1_792_774_080),
            messages: goldenMessages(),
            timeZone: gmt)
        let expected = """
        # Weekend Plans

        _Started Oct 23, 2026 at 2:15 PM · Last updated Oct 23, 2026 at 3:02 PM · Exported Oct 23, 2026 at 4:48 PM_

        ## You — Oct 23, 2026 at 2:15 PM

        Hello there.

        _[2 images attached]_

        ## Assistant — Oct 23, 2026 at 2:16 PM

        Hi! How can I help?

        _Apple On-Device · 1.2s · ≈96 tokens · $0.00_

        """
        XCTAssertEqual(markdown, expected)
    }

    func testExportWithoutTelemetryOmitsPillLines() {
        let markdown = ConversationExport.markdown(
            title: "Quiet",
            createdAt: Date(timeIntervalSince1970: 1_792_764_900),
            updatedAt: Date(timeIntervalSince1970: 1_792_764_960),
            exportedAt: Date(timeIntervalSince1970: 1_792_764_960),
            messages: goldenMessages(),
            includeTelemetry: false,
            timeZone: gmt)
        XCTAssertFalse(markdown.contains("Apple On-Device"))
        XCTAssertTrue(markdown.contains("Hi! How can I help?"))
        // The attachment note is content, not telemetry — it stays.
        XCTAssertTrue(markdown.contains("_[2 images attached]_"))
    }

    func testExportAttachmentsNoteSingularAndPlural() {
        let one = ConversationExport.markdown(
            title: "T", createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            exportedAt: Date(timeIntervalSince1970: 0),
            messages: [ConversationExport.MessageInput(
                role: .user, createdAt: Date(timeIntervalSince1970: 0),
                text: "", attachmentCount: 1)],
            timeZone: gmt)
        XCTAssertTrue(one.contains("_[1 image attached]_"))
        XCTAssertFalse(one.contains("images attached"))
    }

    func testExportEmptyConversation() {
        let markdown = ConversationExport.markdown(
            title: "Fresh",
            createdAt: Date(timeIntervalSince1970: 1_792_764_900),
            updatedAt: Date(timeIntervalSince1970: 1_792_764_900),
            exportedAt: Date(timeIntervalSince1970: 1_792_764_900),
            messages: [],
            timeZone: gmt)
        XCTAssertTrue(markdown.hasPrefix("# Fresh\n"))
        XCTAssertTrue(markdown.contains("_No messages yet._"))
    }

    func testExportFileNameSanitizes() {
        XCTAssertEqual(ConversationExport.suggestedFileName(forTitle: "Weekend Plans"),
                       "Weekend Plans.md")
        XCTAssertEqual(ConversationExport.suggestedFileName(forTitle: "a/b: c?"),
                       "a-b- c.md")
        XCTAssertEqual(ConversationExport.suggestedFileName(forTitle: "///"),
                       "Chat.md")
        XCTAssertEqual(ConversationExport.suggestedFileName(forTitle: ""),
                       "Chat.md")
        XCTAssertEqual(ConversationExport.suggestedFileName(forTitle: "-Report-"),
                       "Report.md")
    }
}
