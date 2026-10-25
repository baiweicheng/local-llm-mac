import Foundation
import XCTest
@testable import LocalLLM

/// Repository-review fix pass, batch 5 (FINAL — P2 remainder:
/// findings 12 remainder, 13, 17, 19, 20). The MLX reply-cap half
/// of finding 12 was already fixed in batch 1 and is not redone
/// here. Same ground rule as earlier batches: there is no Swift
/// toolchain in this workspace, and the live layers (a real
/// stalled MCP server, a real model classification, a packaged
/// app's streaming renders) are exercised on the Mac. What IS
/// proven here is the logic that caused each bug, at the seam
/// each fix exposes — the overhead a plan counts, the bound a
/// fallback summary respects, the size a request line may reach,
/// the metadata a count reads, and the cancellation a race
/// delivers — so a regression in any of them fails a test
/// instead of silently returning.
final class ReviewFixBatch5Tests: XCTestCase {

    private func turn(_ role: MessageRole, tokens: Int) -> ChatTurn {
        // Four characters per token, per PromptHistory's estimate.
        ChatTurn(role: role, text: String(repeating: "x", count: tokens * 4))
    }

    // MARK: - Finding 12 (remainder): complete-prompt budgeting

    /// Tool schemas, the tool-session allowance, the outcome note,
    /// the HUD prefix, and transcript framing are all counted —
    /// and scale with the tool count.
    func testPlanningOverheadCountsSchemasNotesAndFraming() {
        let overhead = ContextManager.planningOverheadTokens(
            toolCount: 3,
            outcomeNote: "abcd", // 1 token
            promptPrefix: "abcdefgh", // 2 tokens
            hasTools: true)
        // 64 framing + 3 × 220 schemas + 256 tool-session allowance
        // + 1 outcome note + 2 HUD prefix = 983.
        XCTAssertEqual(overhead, 983)

        let noTools = ContextManager.planningOverheadTokens(
            toolCount: 0, outcomeNote: nil, promptPrefix: nil,
            hasTools: false)
        XCTAssertEqual(noTools, ContextManager.transcriptFramingTokens)

        let twoMoreTools = ContextManager.planningOverheadTokens(
            toolCount: 2, outcomeNote: nil, promptPrefix: nil,
            hasTools: true)
        // The schema term is linear in the tool count: 2 tools add
        // exactly 2 × 220 over the no-tool framing figure, plus the
        // 256 allowance that applies whenever tools are bound.
        XCTAssertEqual(twoMoreTools - noTools, 2 * 220 + 256)
    }

    /// The review's scenario in miniature: a conversation that fits
    /// on instructions + turns + prompt alone, but not once its
    /// tool schemas and notes are counted. The old planner called
    /// this fitting while the real prompt overflowed.
    func testPlanWithOverheadFlagsOverflowThatFitsWithoutIt() {
        let turns = [turn(.user, tokens: 100), turn(.assistant, tokens: 100)]
        let plain = ContextManager.plan(
            budget: .onDevice, instructions: "Be brief.",
            existingSummary: nil, liveTurns: turns,
            newPrompt: turn(.user, tokens: 50))
        XCTAssertFalse(plain.overflowWarning)
        XCTAssertEqual(plain.projectedTokens, 252) // 2 + 200 + 50

        let withOverhead = ContextManager.plan(
            budget: .onDevice, instructions: "Be brief.",
            existingSummary: nil, liveTurns: turns,
            newPrompt: turn(.user, tokens: 50),
            overheadTokens: 3_400)
        XCTAssertTrue(withOverhead.overflowWarning)
        // 2 + 512 summary allowance + 200 recent + 50 prompt + 3400.
        XCTAssertEqual(withOverhead.projectedTokens, 4_164)
    }

    // MARK: - Finding 13: bounded fallback, capped summaries

    /// The review's failure spiral, at the fallback seam: a huge
    /// existing summary plus another failed pass must NOT grow
    /// the summary — it must stay within the cap, keep the new
    /// note whole, and say it trimmed.
    func testMechanicalFallbackIsBounded() {
        let existing = String(repeating: "word ", count: 3_000)
        let dropped = [ChatTurn(role: .user, text: "Hello world"),
                       ChatTurn(role: .assistant, text: "Hi.")]
        let fallback = ContextManager.mechanicalFallbackSummary(
            existing: existing, droppedTurns: dropped, maxTokens: 512)
        XCTAssertLessThanOrEqual(
            PromptHistory.approximateTokenCount(for: fallback), 512)
        XCTAssertLessThan(fallback.count, existing.count)
        XCTAssertTrue(fallback.contains("trimmed to fit"))
        XCTAssertTrue(fallback.contains("\"Hello world\""))
    }

    /// When the cap leaves no room for any existing summary at
    /// all, the fallback is just the note — never a truncated
    /// note, and never an over-cap merge.
    func testMechanicalFallbackKeepsNoteWholeWhenCapIsTiny() {
        let dropped = [ChatTurn(role: .user, text: "Hello world")]
        let fallback = ContextManager.mechanicalFallbackSummary(
            existing: String(repeating: "word ", count: 3_000),
            droppedTurns: dropped, maxTokens: 10)
        XCTAssertEqual(fallback,
                       "Some earlier messages were trimmed to make room; "
                       + "they covered: \"Hello world\".")
    }

    /// The model-produced half of the same fix: an over-long
    /// summarizer reply is hard-capped at a word boundary and
    /// marked, while a fitting summary passes through untouched.
    func testCappedSummaryTruncatesOverlongOutput() {
        let long = String(repeating: "word ", count: 1_000)
        let capped = ContextManager.cappedSummary(long, maxTokens: 512)
        XCTAssertLessThanOrEqual(
            PromptHistory.approximateTokenCount(for: capped), 512)
        XCTAssertTrue(capped.hasSuffix("… [summary trimmed to fit]"))
        XCTAssertTrue(capped.hasPrefix("word word"))

        let short = "They planned a trip to Lisbon."
        XCTAssertEqual(ContextManager.cappedSummary(short, maxTokens: 512),
                       short)
    }

    // MARK: - Finding 17: MCP stdin backpressure

    /// The size gate, at the seam the client actually enforces:
    /// a request line larger than a macOS pipe (64 KiB) is refused
    /// instead of being written to a server that may never drain
    /// it — the write that used to block under the state lock.
    func testOutboundSizeGateRefusesOverPipeCapacity() {
        XCTAssertEqual(MCPServerConnection.maxOutboundRequestBytes, 64 * 1024)
        XCTAssertFalse(MCPServerConnection.outboundRequestTooLarge(
            Data(repeating: 0, count: 64 * 1024)))
        XCTAssertTrue(MCPServerConnection.outboundRequestTooLarge(
            Data(repeating: 0, count: 64 * 1024 + 1)))
        XCTAssertFalse(MCPServerConnection.outboundRequestTooLarge(
            Data("{\"jsonrpc\":\"2.0\"}".utf8)))
    }

    /// The oversize failure is user-facing, not a bare transport
    /// error: the manager surfaces this description for the plan
    /// item instead of a 30-second timeout.
    func testRequestTooLargeErrorIsUserFacing() {
        let message = MCPClientError.requestTooLarge.errorDescription ?? ""
        XCTAssertTrue(message.contains("too large"))
        XCTAssertTrue(message.contains("smaller arguments"))
    }

    // MARK: - Finding 19: cached attachment counts

    /// The codec's stored-count rule matches what `encode` would
    /// store: invalid images dropped, count capped at four.
    func testStoredCountAppliesValidityFilterAndCap() {
        let valid = ImageAttachment(data: Data(repeating: 7, count: 64))
        let invalid = ImageAttachment(data: Data())
        XCTAssertEqual(ImageAttachmentCodec.storedCount(
            for: [valid, valid, valid, valid, valid]), 4)
        XCTAssertEqual(ImageAttachmentCodec.storedCount(
            for: [valid, invalid, valid]), 2)
        XCTAssertEqual(ImageAttachmentCodec.storedCount(for: []), 0)
    }

    /// The review's scenario, at the counting seam: a message whose
    /// stored count says 2 must still say 2 after its blob is
    /// replaced with a blob holding a different number of images.
    /// If the count still scanned the blob, this would read 1.
    func testMessageAttachmentCountComesFromStoredMetadataNotBlob() {
        let message = Message(role: .user, text: "look")
        message.attachmentsData = ImageAttachmentCodec.encode([
            ImageAttachment(data: Data(repeating: 7, count: 64)),
            ImageAttachment(data: Data(repeating: 9, count: 64)),
        ])
        message.storedAttachmentCount = 2
        // Swap the blob for one holding a single, different image.
        message.attachmentsData = ImageAttachmentCodec.encode([
            ImageAttachment(data: Data(repeating: 3, count: 64)),
        ])
        XCTAssertEqual(message.attachmentCount, 2)
        XCTAssertEqual(message.chatTurn.attachmentCount, 2)
    }

    /// Messages written before the cached field existed still
    /// count correctly — with one header-only scan that is then
    /// cached, so later renders read the stored number.
    func testLegacyMessageBackfillsStoredCountOnFirstUse() {
        let message = Message(role: .user, text: "look")
        message.attachmentsData = ImageAttachmentCodec.encode([
            ImageAttachment(data: Data(repeating: 7, count: 64)),
            ImageAttachment(data: Data(repeating: 9, count: 64)),
        ])
        XCTAssertEqual(message.storedAttachmentCount, 0)
        XCTAssertEqual(message.attachmentCount, 2)
        XCTAssertEqual(message.storedAttachmentCount, 2)
        XCTAssertEqual(message.attachmentCount, 2)
    }

    // MARK: - Finding 20: timeout-race cancellation

    /// A cooperative operation that would run past the deadline
    /// must OBSERVE cancellation once the timer wins — the race
    /// returns at the deadline without awaiting the loser, and the
    /// loser then stops instead of using the model afterwards.
    /// (The race does not await the loser, so the test polls for
    /// the cancellation flag rather than assuming it is set on
    /// return.)
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() {
            lock.lock()
            _value = true
            lock.unlock()
        }
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
    }

    private func cooperativeOperation(flag: CancellationFlag)
        -> @Sendable () async -> PromptIntent? {
        {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            flag.set()
            return nil
        }
    }

    private func waitForFlag(_ flag: CancellationFlag) async {
        for _ in 0..<200 where !flag.value {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTimeoutRaceCancelsSlowOperationWhenTimerWins() async {
        let flag = CancellationFlag()
        let value = await TimeoutRace.run(timeoutSeconds: 0.05,
                                          operation: cooperativeOperation(flag: flag))
        XCTAssertNil(value)
        await waitForFlag(flag)
        XCTAssertTrue(flag.value,
                      "the timer-winning race must cancel the slow operation")
    }

    /// Cancelling the parent (a stopped send) cancels the
    /// classification too, and the race returns nil instead of
    /// hanging on either child.
    func testTimeoutRacePropagatesParentCancellation() async {
        let flag = CancellationFlag()
        let task = Task {
            await TimeoutRace.run(timeoutSeconds: 30,
                                  operation: cooperativeOperation(flag: flag))
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        await waitForFlag(flag)
        XCTAssertTrue(flag.value,
                      "a cancelled parent must cancel the classification")
    }

    /// The fast path is unchanged by the cancellation plumbing: a
    /// prompt verdict still wins the race and returns promptly.
    func testTimeoutRaceFastOperationStillWins() async {
        let started = Date()
        let value = await TimeoutRace.run(timeoutSeconds: 5) {
            try? await Task.sleep(for: .milliseconds(10))
            return PromptIntent.localHeavy
        }
        XCTAssertEqual(value, .localHeavy)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
