import XCTest
import SwiftData
@testable import LocalLLM

/// Efficiency/Quality fix-pass tests (audit E-01…E-19): the pure
/// logic behind the fixes — search early-exit + one-pass hits,
/// context suffix sums, the header-only attachment count, the
/// opaque-token scan, the MCP parser's line cap, the shell
/// wording constants, backup-retention decisions — plus the
/// in-memory-SwiftData coverage E-14 asked for: access-log
/// rotation against a REAL store (not just its arithmetic) and
/// plan/activity record round-trips through a container.
///
/// NOT covered here, deliberately (E-14 feasibility): MLXModelStore
/// state transitions need the Hugging Face network path and the
/// store's init touches the real Application Support folder;
/// MCP manager lifecycle needs real child processes. Those remain
/// Mac-verified behaviors; everything below is deterministic.
final class EfficiencyFixTests: XCTestCase {

    // MARK: - E-01: ChatSearch early-exit + one-pass hits

    func testSnippetReturnsNilWithoutFlatteningNonMatches() {
        // Behavior: a non-matching message yields no snippet, and
        // a matching one yields the same snippet as before.
        XCTAssertNil(ChatSearch.snippet(
            in: "nothing relevant in this long message body",
            matching: "zebra"))
        let hit = ChatSearch.snippet(
            in: "the quick brown fox jumps over the lazy dog",
            matching: "brown")
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit!.contains("brown"))
    }

    func testRawTextMayMatchIsAConservativeFilter() {
        // True positives the flattened text would match: words
        // separated by a newline in the raw text flatten to a
        // single space.
        XCTAssertTrue(ChatSearch.rawTextMayMatch(
            "hello\nworld", query: "hello world"))
        XCTAssertTrue(ChatSearch.rawTextMayMatch(
            "say hello   world now", query: "hello world"))
        XCTAssertTrue(ChatSearch.rawTextMayMatch(
            "Café menu", query: "cafe"))
        // Negatives: a missing word, or words in the wrong order,
        // can never match the flattened text.
        XCTAssertFalse(ChatSearch.rawTextMayMatch(
            "hello there", query: "hello world"))
        XCTAssertFalse(ChatSearch.rawTextMayMatch(
            "world hello", query: "hello world"))
    }

    func testSnippetMatchesAcrossNewlinesLikeBefore() {
        // The flattened-form semantics are unchanged: a phrase
        // split by a newline in the message still matches.
        let hit = ChatSearch.hit(
            title: "Notes",
            messageTexts: ["first line\nsecond line"],
            query: "line second")
        XCTAssertNotNil(hit)
        XCTAssertNotNil(hit?.snippet)
    }

    func testHitsComputesEveryChatInOnePass() {
        let idA = UUID(), idB = UUID(), idC = UUID()
        let hits = ChatSearch.hits(in: [
            (id: idA, title: "Budget", messageTexts: ["rent is due"]),
            (id: idB, title: "Trip", messageTexts: ["flights and hotels"]),
            (id: idC, title: "Rent notes", messageTexts: ["nothing here"]),
        ], query: "rent")
        XCTAssertEqual(Set(hits.keys), [idA, idC])
        XCTAssertEqual(hits[idA]?.snippet?.contains("rent"), true)
        XCTAssertEqual(hits[idC]?.titleMatched, true)
        // Empty query → no hits (the sidebar shows everything).
        XCTAssertTrue(ChatSearch.hits(in: [
            (id: idA, title: "Budget", messageTexts: ["rent"]),
        ], query: "  ").isEmpty)
    }

    // MARK: - E-07: context suffix sums

    func testSuffixSumsMatchNaiveSummation() {
        let tokens = [5, 1, 9, 2, 7]
        let sums = ContextManager.suffixSums(tokens)
        XCTAssertEqual(sums, [24, 19, 18, 9, 7])
        for index in tokens.indices {
            XCTAssertEqual(sums[index],
                           tokens[index...].reduce(0, +))
        }
        XCTAssertEqual(ContextManager.suffixSums([]), [])
        XCTAssertEqual(ContextManager.suffixSums([3]), [3])
    }

    func testPlanStillPicksTheLongestFittingSuffix() {
        // The suffix-sum rewrite must not change planning: with a
        // tight budget the plan summarizes the oldest turns and
        // keeps the newest whole exchange verbatim.
        let budget = ContextBudget(backend: .onDevice, windowTokens: 4_096)
        let turns = (0..<10).map { index in
            ChatTurn(role: index.isMultiple(of: 2) ? .user : .assistant,
                     text: String(repeating: "word ", count: 300))
        }
        let plan = ContextManager.plan(
            budget: budget, instructions: "Be brief.",
            existingSummary: nil, liveTurns: turns,
            newPrompt: ChatTurn(role: .user, text: "and now?"))
        XCTAssertTrue(plan.needsCompaction)
        XCTAssertEqual(plan.recentTurns.first?.role, .user)
        XCTAssertEqual(plan.turnsToSummarize.count
                       + plan.recentTurns.count, turns.count)
    }

    // MARK: - E-03: attachment count without decoding

    func testAttachmentCountMatchesDecodeWithoutDecoding() {
        let attachments = (0..<3).map { index in
            ImageAttachment(data: Data(repeating: UInt8(index + 1),
                                       count: 128),
                            pixelWidth: 10, pixelHeight: 10)
        }
        let blob = ImageAttachmentCodec.encode(attachments)
        XCTAssertEqual(ImageAttachmentCodec.count(in: blob), 3)
        XCTAssertEqual(ImageAttachmentCodec.count(in: blob),
                       ImageAttachmentCodec.decode(blob).count)
        XCTAssertEqual(ImageAttachmentCodec.count(in: nil), 0)
        XCTAssertEqual(ImageAttachmentCodec.count(in: Data()), 0)
        XCTAssertEqual(ImageAttachmentCodec.count(
            in: Data("not json".utf8)), 0)
        XCTAssertEqual(ImageAttachmentCodec.count(
            in: Data("{}".utf8)), 0)
    }

    func testMessageChatTurnUsesTheCheapCount() {
        let message = Message(role: .user, text: "look")
        message.attachmentsData = ImageAttachmentCodec.encode([
            ImageAttachment(data: Data(repeating: 7, count: 64)),
            ImageAttachment(data: Data(repeating: 9, count: 64)),
        ])
        XCTAssertEqual(message.attachmentCount, 2)
        XCTAssertEqual(message.chatTurn.attachmentCount, 2)
        XCTAssertEqual(message.chatTurn.text, "look")
    }

    // MARK: - E-80: opaque-token scan

    func testOpaqueTokenScanMasksQualifyingRuns() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let result = Redactor.maskOpaqueTokens(in: "commit \(sha) fixed")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.text, "commit \(Redactor.mask) fixed")
        // Full-redactor equivalence with the old regex behavior:
        // the SHA is masked, a long plain word is not.
        let wordy = Redactor.redact(
            "Antidisestablishmentarianism is a long word.")
        XCTAssertEqual(wordy.replacementCount, 0)
    }

    func testOpaqueTokenScanBoundaries() {
        // 23 chars: too short. 24: masked.
        let short = String(repeating: "a1", count: 11) + "a" // 23
        XCTAssertEqual(Redactor.maskOpaqueTokens(in: short).count, 0)
        let exact = String(repeating: "a1", count: 12) // 24
        XCTAssertEqual(Redactor.maskOpaqueTokens(in: exact).count, 1)
        // Letters only / digits only never qualify.
        XCTAssertEqual(Redactor.maskOpaqueTokens(
            in: String(repeating: "a", count: 40)).count, 0)
        XCTAssertEqual(Redactor.maskOpaqueTokens(
            in: String(repeating: "7", count: 40)).count, 0)
        // A run broken by a character outside the charset is two
        // short runs, not one long one.
        let broken = String(repeating: "a1", count: 8) + " "
            + String(repeating: "b2", count: 8)
        XCTAssertEqual(Redactor.maskOpaqueTokens(in: broken).count, 0)
        // '=' and '+' are charset members (base64 padding/plus).
        let b64 = String(repeating: "ab12", count: 6) + "+/==" // 28
        XCTAssertEqual(Redactor.maskOpaqueTokens(in: b64).count, 1)
    }

    // MARK: - E-12: MCP parser line cap

    func testParserDropsAnOversizedUnterminatedLineOnce() {
        var parser = MCPStreamParser()
        let big = Data(repeating: 0x61, // 'a'
                       count: MCPStreamParser.maxBufferedLineBytes + 10)
        let first = parser.feed(big)
        XCTAssertEqual(first.count, 1)
        guard case .malformed = first[0] else {
            return XCTFail("expected one .malformed for the overlong line")
        }
        // The rest of the dropped line (still no newline) produces
        // nothing more; framing resumes at its newline.
        XCTAssertTrue(parser.feed(Data("more junk".utf8)).isEmpty)
        let resumed = parser.feed(Data(
            "\n{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n".utf8))
        XCTAssertEqual(resumed.count, 1)
        guard case .response(let id, _, _) = resumed[0] else {
            return XCTFail("expected framing to resume after the dropped line")
        }
        XCTAssertEqual(id, 7)
    }

    func testParserHandlesManyLinesInOneChunk() {
        var parser = MCPStreamParser()
        let chunk = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n"
            + "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n"
            + "not json\n"
        let messages = parser.feed(chunk)
        XCTAssertEqual(messages.count, 3)
        // A line straddling chunks still completes (B-01 intact).
        var second = MCPStreamParser()
        XCTAssertTrue(second.feed(
            Data("{\"jsonrpc\":\"2.0\",\"id\":2,".utf8)).isEmpty)
        let tail = second.feed(Data("\"result\":{}}\n".utf8))
        XCTAssertEqual(tail.count, 1)
    }

    // MARK: - E-18: shared wording

    func testSharedWordingIsTheSingleSource() {
        // The refusal both MCP-unavailable paths produce.
        guard case .refused(let reason) = ActionProposal.make(
            kind: .mcpCall, inputs: ActionInputs(),
            roots: [], probe: TestProbe(), home: "/Users/test") else {
            return XCTFail("expected a refusal without an MCP tool")
        }
        XCTAssertEqual(reason, SharedWording.mcpToolUnavailable)
        XCTAssertTrue(SharedWording.modelUnavailableFallback
            .contains("built-in on-device model"))
        XCTAssertTrue(SharedWording.modelUnavailableBanner
            .contains("Pick a model in the header"))
    }

    // MARK: - E-05: backup retention decisions

    private func renameItem() -> ExecutedActionItem {
        ExecutedActionItem(
            action: PlannedAction(kind: .rename,
                                  sourcePath: "/shared/a.txt",
                                  destinationPath: "/shared/b.txt",
                                  summary: "Rename a.txt to b.txt"),
            outcome: .done, resultNote: "Renamed.")
    }

    func testBackupRetentionProtectsOnlyUndoableRecords() {
        let live = UUID(), undone = UUID(), discarded = UUID()
        let gone = UUID() // rotated away — no record at all
        let folders = [live, undone, discarded, gone]
            .map { $0.uuidString } + ["not-a-uuid-folder"]
        let deletable = ActionBackupRetention.deletableFolders(
            folderNames: folders,
            retained: [
                (id: live, status: .executed, isUndone: false),
                (id: undone, status: .executed, isUndone: true),
                (id: discarded, status: .discarded, isUndone: false),
            ])
        // The live executed record's folder survives; EVERYTHING
        // else — undone, discarded, record-less, stray — goes.
        XCTAssertEqual(Set(deletable),
                       Set([undone, discarded, gone].map { $0.uuidString }
                           + ["not-a-uuid-folder"]))
    }

    func testCanUndoWithPreDecodedItems() {
        let record = ActionPlanRecord(
            conversationID: UUID(), status: .executed,
            items: [renameItem()])
        XCTAssertTrue(record.canUndo(items: record.items))
        XCTAssertTrue(record.canUndo) // property form agrees
        record.undoneAt = Date()
        XCTAssertFalse(record.canUndo(items: record.items))
        let discarded = ActionPlanRecord(
            conversationID: UUID(), status: .discarded,
            items: [renameItem()])
        XCTAssertFalse(discarded.canUndo(items: discarded.items))
    }

    // MARK: - E-14: rotation against a real in-memory store

    @MainActor
    func testAccessLogRotationAgainstARealStore() throws {
        let container = try ModelContainer(
            for: ToolActivityRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let conversationID = UUID()
        // Insert cap + 25 events through the same policy math the
        // engine's rotation applies, oldest first, then rotate the
        // way `recordToolEvent` does and verify the STORE (not the
        // arithmetic): exactly the newest 300 remain.
        let total = AccessLogPolicy.maxRecords + 25
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<total {
            context.insert(ToolActivityRecord(
                conversationID: conversationID,
                toolName: "lookup_\(index)", sourceRaw: "",
                querySummary: "q", resultSummary: "r",
                createdAt: base.addingTimeInterval(Double(index))))
        }
        try context.save()
        XCTAssertEqual(try context.fetchCount(
            FetchDescriptor<ToolActivityRecord>()), total)

        let excess = AccessLogPolicy.excessCount(totalRecords: total)
        var oldest = FetchDescriptor<ToolActivityRecord>(
            sortBy: [SortDescriptor(\.createdAt)])
        oldest.fetchLimit = excess
        for record in try context.fetch(oldest) {
            context.delete(record)
        }
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<
            ToolActivityRecord>(
            sortBy: [SortDescriptor(\.createdAt)]))
        XCTAssertEqual(remaining.count, AccessLogPolicy.maxRecords)
        XCTAssertEqual(remaining.first?.toolName, "lookup_25")
        XCTAssertEqual(remaining.last?.toolName, "lookup_\(total - 1)")
    }

    @MainActor
    func testPlanRecordsRoundTripThroughAContainer() throws {
        let container = try ModelContainer(
            for: ActionPlanRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let conversationID = UUID()
        let record = ActionPlanRecord(
            conversationID: conversationID, status: .executed,
            items: [renameItem()],
            id: UUID())
        context.insert(record)
        try context.save()

        let fetched = try XCTUnwrap(try ModelContext(container)
            .fetch(FetchDescriptor<ActionPlanRecord>()).first)
        XCTAssertEqual(fetched.id, record.id)
        XCTAssertEqual(fetched.conversationID, conversationID)
        XCTAssertEqual(fetched.status, .executed)
        XCTAssertEqual(fetched.items.count, 1)
        XCTAssertEqual(fetched.items.first?.action.kind, .rename)
        XCTAssertEqual(fetched.items.first?.resultNote, "Renamed.")
        // The E-05 folder mapping: the record's id IS its folder.
        XCTAssertEqual(
            ActionBackupRetention.folderName(recordID: fetched.id),
            fetched.id.uuidString)
    }

    @MainActor
    func testToolActivityRecordRoundTripsThroughAContainer() throws {
        let container = try ModelContainer(
            for: ToolActivityRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let event = ToolEvent(
            conversationID: UUID(), toolName: "search_files",
            source: .files, querySummary: "“invoice”",
            resultSummary: "3 files", date: Date())
        context.insert(ToolActivityRecord(event: event))
        try context.save()
        let fetched = try XCTUnwrap(try ModelContext(container)
            .fetch(FetchDescriptor<ToolActivityRecord>()).first)
        XCTAssertEqual(fetched.toolName, "search_files")
        XCTAssertEqual(fetched.sourceRaw, VisibilitySource.files.rawValue)
        XCTAssertEqual(fetched.querySummary, "“invoice”")
    }

    // MARK: - E-02: transcript merge (ChatView's builder)

    @MainActor
    func testTranscriptBuilderMergesInTimeOrderWithDivider() throws {
        let container = try ModelContainer(
            for: Conversation.self, Message.self,
            ToolActivityRecord.self, ActionPlanRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let conversation = Conversation()
        context.insert(conversation)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func message(_ offset: TimeInterval, _ text: String) -> Message {
            let message = Message(role: .user, text: text,
                                  conversation: conversation)
            message.createdAt = base.addingTimeInterval(offset)
            context.insert(message)
            return message
        }
        let first = message(0, "one")
        let second = message(20, "two")
        let tool = ToolActivityRecord(
            conversationID: conversation.id, toolName: "clock",
            sourceRaw: "", querySummary: "", resultSummary: "",
            createdAt: base.addingTimeInterval(10))
        context.insert(tool)
        try context.save()

        let items = ChatView.TranscriptBuilder.items(
            messages: [first, second], summarizedCount: 1,
            toolRecords: [tool], planRecords: [])
        // Order: message, tool (t=10), divider (before message at
        // index 1 — the summarized prefix is 1), message.
        XCTAssertEqual(items.map(\.id), [
            "message-\(first.id.uuidString)",
            "tool-\(tool.id.uuidString)",
            "summarized-divider",
            "message-\(second.id.uuidString)",
        ])
    }
}

/// A no-disk `FileSystemProbe` for proposal tests.
private struct TestProbe: FileSystemProbe {
    func exists(atPath path: String) -> Bool { false }
    func isDirectory(atPath path: String) -> Bool { false }
}
