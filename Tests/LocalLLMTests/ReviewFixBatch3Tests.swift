import XCTest
@testable import LocalLLM

/// Repository-review fix pass, batch 3 (privacy/lifecycle P1s:
/// findings 6, 7, 8, 9, 11). Every test below targets the pure or
/// extractable layer of its fix, for the same reason the earlier
/// fix passes did: there is no Swift toolchain in this workspace,
/// and the live layers (HTTP round trips, real MCP server
/// processes, real shell children, Hugging Face downloads) are
/// exercised on the Mac. What IS proven here is the logic that
/// caused each bug — the payload scrub, the snapshot/signature
/// pairing, the toggle-to-termination rule, the process-tree
/// enumeration, and the download-state merge — so a regression in
/// any of them fails a test instead of silently returning.
final class ReviewFixBatch3Tests: XCTestCase {

    // MARK: - Finding 6: HTTP sessions scrub the complete payload

    /// The review's scenario: a turn sent BEFORE a term existed in
    /// Settings, then the term is added, then another message is
    /// sent. The reused session's cached history must be scrubbed
    /// at transport time — the old turn's project name and the
    /// assistant's email must not survive into the wire payload,
    /// even though the session's stored history is untouched.
    func testScrubbedMessagesMaskOldTurnWithLaterAddedTerm() {
        let history = [
            ChatMessagePayload(role: "user",
                               content: "Project Falcon launches Tuesday"),
            ChatMessagePayload(role: "assistant",
                               content: "Noted Project Falcon — ping alice@example.com"),
        ]
        let scrubbed = OpenAIRequestBuilder.scrubbedMessages(
            instructions: "Be brief.",
            history: history,
            newUserMessage: "Go",
            customTerms: ["Project Falcon"])
        let joined = scrubbed.map(\.content).joined(separator: "\n")
        XCTAssertFalse(joined.contains("Project Falcon"))
        XCTAssertFalse(joined.contains("alice@example.com"))
        XCTAssertTrue(joined.contains("[redacted]"))
        // The STORED history is untouched — only the sent copy is
        // edited, exactly like the engine's firewall.
        let unscrubbed = OpenAIRequestBuilder.messages(
            instructions: "Be brief.", history: history, newUserMessage: "Go")
        XCTAssertTrue(unscrubbed.map(\.content).joined(separator: "\n")
            .contains("Project Falcon"))
    }

    /// Even with NO custom terms, a cached assistant turn's
    /// sensitive-shaped text (here, an email the model itself
    /// produced) is scrubbed from the serialized body.
    func testScrubbedBodyDataMasksAssistantTurnWithoutCustomTerms() {
        let body = OpenAIRequestBuilder.scrubbedBodyData(
            model: "test-model",
            instructions: "",
            history: [ChatMessagePayload(
                role: "assistant",
                content: "Reach me at bob@example.com for details")],
            newUserMessage: "Thanks",
            customTerms: [])
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("bob@example.com"))
        XCTAssertTrue(text.contains("[redacted]"))
    }

    /// The unscrubbed path is unchanged: a localhost server still
    /// receives text exactly as written (the scrub is opt-in per
    /// send, gated on the remote flag in the sessions).
    func testUnscrubbedBodyDataLeavesHistoryIntact() {
        let body = OpenAIRequestBuilder.bodyData(
            model: "test-model",
            instructions: "",
            history: [ChatMessagePayload(
                role: "user", content: "Project Falcon launches Tuesday")],
            newUserMessage: "Go")
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Project Falcon"))
    }

    // MARK: - Finding 7: runtime and signature from ONE snapshot

    /// The review's scenario, at the factory level: a source is
    /// enabled and a folder shared when the send starts, then both
    /// are disabled DURING MCP discovery. A runtime built from the
    /// post-discovery snapshot must carry the restricted grants —
    /// not the pre-discovery ones — and its signature must be the
    /// restricted snapshot's, so the next send cannot re-bless a
    /// stale runtime through a signature describing new settings.
    func testPostDiscoveryFactoryUsesPostDiscoverySnapshot() {
        let before = ToolAvailability(
            enabledSources: [.files],
            folderRootPaths: ["/Users/tester/Shared"],
            fileWritingEnabled: true,
            powerToolsEnabled: true,
            customRedactionTerms: [])
        let after = ToolAvailability(
            enabledSources: [],
            folderRootPaths: [],
            fileWritingEnabled: false,
            powerToolsEnabled: false,
            customRedactionTerms: ["Project Falcon"])
        let config = ToolRuntime.Configuration.fromPostDiscovery(
            availability: after,
            conversationID: UUID(),
            mcpTools: [],
            redactResults: false,
            proposalSink: { _, _ in false })
        XCTAssertEqual(config.enabledSources, [])
        XCTAssertEqual(config.folderRootPaths, [])
        XCTAssertFalse(config.fileWritingEnabled)
        XCTAssertFalse(config.powerToolsEnabled)
        XCTAssertEqual(config.redactionTerms, ["Project Falcon"])
        // And the two snapshots are distinguishable at all: a
        // session stored under `after`'s signature can never match
        // a runtime built from `before`.
        XCTAssertNotEqual(before.signature, after.signature)
    }

    /// End to end through the runtime: a runtime built from the
    /// post-discovery snapshot (source disabled during discovery)
    /// refuses the tool that source used to grant.
    func testRuntimeFromPostDiscoverySnapshotRefusesDisabledSource() async {
        let after = ToolAvailability(
            enabledSources: [],
            folderRootPaths: [],
            fileWritingEnabled: false,
            powerToolsEnabled: false)
        let runtime = ToolRuntime(
            configuration: ToolRuntime.Configuration.fromPostDiscovery(
                availability: after,
                conversationID: UUID(),
                mcpTools: [],
                redactResults: false,
                proposalSink: { _, _ in false }),
            sink: { _ in },
            permissionProvider: { _ in .authorized })
        let result = await runtime.execute(
            toolName: "list_folder",
            arguments: ToolArguments(path: "/Users/tester/Shared"))
        XCTAssertTrue(result.contains("turned off"))
    }

    /// The execution-time gate: power items refuse under the lock
    /// and with the master switch off; file items refuse with file
    /// writing off; everything passes when its grants are present.
    func testPlanExecutionGateRefusesPowerAndFileItemsWithoutGrants() {
        let command = PlannedAction(
            kind: .runCommand, commandText: "ls",
            workingDirectory: "/Users/tester/Shared",
            summary: "Run ls")
        let rename = PlannedAction(
            kind: .rename, sourcePath: "/Users/tester/Shared/a.txt",
            destinationPath: "/Users/tester/Shared/b.txt",
            summary: "Rename a.txt")
        XCTAssertNotNil(PlanExecutionGate.refusal(
            for: command, localOnly: true,
            powerToolsEnabled: true, fileWritingEnabled: true))
        XCTAssertNotNil(PlanExecutionGate.refusal(
            for: command, localOnly: false,
            powerToolsEnabled: false, fileWritingEnabled: true))
        XCTAssertNil(PlanExecutionGate.refusal(
            for: command, localOnly: false,
            powerToolsEnabled: true, fileWritingEnabled: true))
        XCTAssertNotNil(PlanExecutionGate.refusal(
            for: rename, localOnly: false,
            powerToolsEnabled: true, fileWritingEnabled: false))
        XCTAssertNil(PlanExecutionGate.refusal(
            for: rename, localOnly: false,
            powerToolsEnabled: true, fileWritingEnabled: true))
    }

    // MARK: - Finding 8: Local Only / power switch stop live servers

    /// The toggle rule, through the manager's seam (no real
    /// processes): termination fires exactly when power tools are
    /// NOT available — lock on, or master switch off — and never
    /// while both allow them.
    func testStopServersWhenPowerUnavailableFiresOnlyWhenUnavailable() {
        let manager = MCPServerManager()
        XCTAssertEqual(manager.terminateAllCallCount, 0)
        manager.stopServersWhenPowerUnavailable(
            localOnly: false, powerToolsEnabled: true)
        XCTAssertEqual(manager.terminateAllCallCount, 0)
        manager.stopServersWhenPowerUnavailable(
            localOnly: true, powerToolsEnabled: true)
        XCTAssertEqual(manager.terminateAllCallCount, 1)
        manager.stopServersWhenPowerUnavailable(
            localOnly: false, powerToolsEnabled: false)
        XCTAssertEqual(manager.terminateAllCallCount, 2)
        manager.stopServersWhenPowerUnavailable(
            localOnly: true, powerToolsEnabled: false)
        XCTAssertEqual(manager.terminateAllCallCount, 3)
    }

    /// `terminateAll` itself is observable through the seam, so a
    /// future wiring change that drops the call is caught.
    func testTerminateAllIncrementsCallCount() {
        let manager = MCPServerManager()
        manager.terminateAll()
        XCTAssertEqual(manager.terminateAllCallCount, 1)
        manager.terminateAll()
        XCTAssertEqual(manager.terminateAllCallCount, 2)
    }

    // MARK: - Finding 9: shell descendant cleanup

    /// Descendants come out parents-before-children, so signalling
    /// the reversed list kills deepest-first (no child is orphaned
    /// before its own signal).
    func testProcessTreeDescendantsAreParentsBeforeChildren() {
        let map: [Int32: Int32] = [
            101: 100, 102: 100, 201: 101, 202: 201,
        ]
        let found = ShellProcessTree.descendantPIDs(of: 100, parentByPID: map)
        XCTAssertEqual(Set(found), Set([101, 102, 201, 202]))
        XCTAssertLessThan(found.firstIndex(of: 101)!,
                          found.firstIndex(of: 201)!)
        XCTAssertLessThan(found.firstIndex(of: 201)!,
                          found.firstIndex(of: 202)!)
    }

    /// A corrupt map (a cycle, and the root appearing as someone's
    /// child) terminates: the root is never listed as its own
    /// descendant, and no PID repeats.
    func testProcessTreeDescendantsSurviveCyclesAndExcludeRoot() {
        let map: [Int32: Int32] = [
            101: 100, 102: 101, 100: 102,
        ]
        let found = ShellProcessTree.descendantPIDs(of: 100, parentByPID: map)
        XCTAssertEqual(Set(found), Set([101, 102]))
        XCTAssertEqual(found.count, 2)
    }

    /// `ps` output parsing: real pairs map, malformed lines are
    /// skipped rather than fatal.
    func testProcessTreeParentMapParsesPsOutput() {
        let output = "  123   456\nbad line\n  789   123\n"
        let map = ShellProcessTree.parentMap(from: output)
        XCTAssertEqual(map, [123: 456, 789: 123])
    }

    // NOTE (finding 9, live-process limit): a test that actually
    // spawns a shell with a background child and asserts the child
    // dies on timeout/cancellation is not possible here — there is
    // no Swift toolchain in this workspace to run anything, and
    // `ShellRunner` is private to its file, so even on a Mac the
    // seam for such a test would be the (private) runner itself.
    // The pure tree layer above is the testable part; the
    // timeout/cancellation wiring through it is Mac-verified.

    // MARK: - Finding 11: completed downloads become ready

    /// The review's exact sequence, through the merge: (1) the
    /// download completes and `refresh()` runs while the task is
    /// STILL registered; (2) the defer removes the task; (3) a
    /// later refresh runs. The state must end `.downloaded`, and
    /// the model must appear in the downloaded set — the old code
    /// left it at `.downloading(fraction: 1.0)` after both
    /// refreshes, and `downloadedRepoIDs` never contained it.
    func testMergedStatesCompletionRefreshDeferSequence() {
        let model = "mlx-community/test-model"
        // Step 1: completion refresh, task still registered.
        var states = MLXModelStore.mergedStates(
            scanned: [model: .downloaded],
            previous: [model: .downloading(fraction: 1.0)],
            inFlightRepoIDs: [model])
        XCTAssertEqual(states[model], .downloaded)
        // Step 2 + 3: defer removed the task; a later refresh.
        states = MLXModelStore.mergedStates(
            scanned: [model: .downloaded],
            previous: states,
            inFlightRepoIDs: [])
        XCTAssertEqual(states[model], .downloaded)
        let downloaded = Set(states.filter { $0.value == .downloaded }
            .map(\.key))
        XCTAssertTrue(downloaded.contains(model))
    }

    /// The merge's other rules stay intact: an active download is
    /// preserved (its folder doesn't exist yet, so the scan can't
    /// know), and a failed attempt survives a refresh while the
    /// model isn't on disk.
    func testMergedStatesPreservesActiveDownloadAndFailure() {
        let model = "mlx-community/test-model"
        let active = MLXModelStore.mergedStates(
            scanned: [model: .notDownloaded],
            previous: [model: .downloading(fraction: 0.5)],
            inFlightRepoIDs: [model])
        XCTAssertEqual(active[model], .downloading(fraction: 0.5))
        let failed = MLXModelStore.mergedStates(
            scanned: [model: .notDownloaded],
            previous: [model: .failed(message: "No network")],
            inFlightRepoIDs: [])
        XCTAssertEqual(failed[model], .failed(message: "No network"))
    }

    /// The second half of the bug: a `.downloading` state whose
    /// task is GONE is stale and must fall back to the scan — the
    /// old code preserved it unconditionally, so a finished model
    /// could read as downloading forever. Disk truth also beats a
    /// stale failure record.
    func testMergedStatesDropsStaleDownloadingWithoutTask() {
        let model = "mlx-community/test-model"
        let stale = MLXModelStore.mergedStates(
            scanned: [model: .notDownloaded],
            previous: [model: .downloading(fraction: 1.0)],
            inFlightRepoIDs: [])
        XCTAssertEqual(stale[model], .notDownloaded)
        let diskWins = MLXModelStore.mergedStates(
            scanned: [model: .downloaded],
            previous: [model: .failed(message: "No network")],
            inFlightRepoIDs: [])
        XCTAssertEqual(diskWins[model], .downloaded)
    }
}
