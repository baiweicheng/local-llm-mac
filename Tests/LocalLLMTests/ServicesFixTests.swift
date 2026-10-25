import XCTest
@testable import LocalLLM

/// Services & Concurrency fix-pass tests (audit B-40…B-59): the
/// pure / extractable logic behind the service-layer fixes —
/// download generation stamps (B-41), shell tail retention (B-49),
/// the intent-timeout race (B-50), session config digests (B-47),
/// and FileScopeStore's resolution decisions (B-57) — plus a
/// happy-path pass through the editText identity check (B-59).
/// The process/actor plumbing itself (MCP launch joins, shell
/// EOF finishing, plan-task cancellation) is exercised on the Mac.
final class ServicesFixTests: XCTestCase {

    // MARK: - B-41: download generation stamps

    func testGenerationTrackerInvalidatesOnAdvance() {
        var tracker = DownloadGenerationTracker()
        let first = tracker.advance(for: "repo-a")
        XCTAssertTrue(tracker.isCurrent(first, for: "repo-a"))
        // Cancel (or a restart) advances again: the old attempt is
        // stale from that moment, whatever it does while unwinding.
        let second = tracker.advance(for: "repo-a")
        XCTAssertFalse(tracker.isCurrent(first, for: "repo-a"))
        XCTAssertTrue(tracker.isCurrent(second, for: "repo-a"))
        // Generations are per repo: another model is unaffected.
        let other = tracker.advance(for: "repo-b")
        XCTAssertTrue(tracker.isCurrent(other, for: "repo-b"))
        XCTAssertTrue(tracker.isCurrent(second, for: "repo-a"))
        // An unknown repo has no current generation.
        XCTAssertFalse(tracker.isCurrent(1, for: "repo-c"))
    }

    func testGenerationTrackerCancelRestartSequence() {
        // The B-41 sequence: attempt 1 starts, is cancelled, and
        // attempt 2 starts immediately. Attempt 1's unwind must
        // find itself stale at every checkpoint; attempt 2 owns
        // the state throughout.
        var tracker = DownloadGenerationTracker()
        let attempt1 = tracker.advance(for: "m")   // startDownload #1
        tracker.advance(for: "m")                  // cancelDownload
        let attempt2 = tracker.advance(for: "m")   // startDownload #2
        XCTAssertFalse(tracker.isCurrent(attempt1, for: "m"))
        XCTAssertTrue(tracker.isCurrent(attempt2, for: "m"))
    }

    // MARK: - B-49: shell retention is a true tail

    func testShellOutputRetainedTailKeepsTheEnd() {
        let long = String(repeating: "a", count: 100)
            + String(repeating: "b", count: 100)
        let tail = ShellOutput.retainedTail(long, cap: 50)
        XCTAssertEqual(tail, String(repeating: "b", count: 50))
        // Under the cap, retention is the whole string.
        XCTAssertEqual(ShellOutput.retainedTail("short", cap: 50), "short")
        // The prefix helper is unchanged for its own callers.
        XCTAssertEqual(ShellOutput.retainedPrefix(long, cap: 50),
                       String(repeating: "a", count: 50))
        // And the model-facing shaping still shows the tail of
        // whatever was retained — now genuinely the end of the
        // output, not the end of the beginning.
        let retained = ShellOutput.retainedTail(
            long, cap: ShellOutput.modelCharacterCap)
        XCTAssertTrue(ShellOutput.forModel(retained).hasSuffix("b"))
    }

    // MARK: - B-50: the timeout race is a hard bound

    func testTimeoutRaceReturnsTheOperationsValueWhenFast() async {
        let value = await TimeoutRace.run(timeoutSeconds: 5) {
            try? await Task.sleep(for: .milliseconds(10))
            return PromptIntent.localHeavy
        }
        XCTAssertEqual(value, .localHeavy)
    }

    func testTimeoutRaceReturnsNilForANilVerdict() async {
        let value = await TimeoutRace.run(timeoutSeconds: 5) {
            PromptIntent?.none
        }
        XCTAssertNil(value)
    }

    func testTimeoutRaceDoesNotAwaitTheLoser() async {
        // The operation would take 10 seconds; the race must
        // return at the 0.2-second deadline WITHOUT waiting for it
        // (the task-group shape this replaces blocked for the full
        // operation — the B-50 bug).
        let started = Date()
        let value = await TimeoutRace.run(timeoutSeconds: 0.2) {
            try? await Task.sleep(for: .seconds(10))
            return PromptIntent.frontierCloud
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                          "the race must return at its deadline, not when the operation finishes")
    }

    // MARK: - B-47: session config digests

    func testEndpointDigestTracksURLAndModel() {
        let base = SessionConfigDigest.endpoint(
            baseURL: "http://localhost:11434/v1", modelName: "llama3.1")
        XCTAssertEqual(base, SessionConfigDigest.endpoint(
            baseURL: "http://localhost:11434/v1", modelName: "llama3.1"))
        XCTAssertNotEqual(base, SessionConfigDigest.endpoint(
            baseURL: "http://localhost:9999/v1", modelName: "llama3.1"))
        XCTAssertNotEqual(base, SessionConfigDigest.endpoint(
            baseURL: "http://localhost:11434/v1", modelName: "qwen2.5"))
        // Surrounding whitespace is presentation, not identity.
        XCTAssertEqual(base, SessionConfigDigest.endpoint(
            baseURL: "  http://localhost:11434/v1 ", modelName: "llama3.1"))
    }

    func testOpenRouterDigestTracksTheKeyWithoutContainingIt() {
        let key = "sk-or-v1-a-real-looking-key-0123456789"
        let digest = SessionConfigDigest.openRouter(apiKey: key)
        XCTAssertEqual(digest, SessionConfigDigest.openRouter(apiKey: key))
        XCTAssertNotEqual(digest, SessionConfigDigest.openRouter(
            apiKey: "sk-or-v1-a-different-key-9876543210"))
        // The digest is one-way: the key value appears nowhere in
        // it, in whole or in part.
        XCTAssertFalse(digest.contains(key))
        XCTAssertFalse(digest.contains("a-real-looking-key"))
    }

    func testFactoryStampsDigestsOnResolvedBackends() {
        let config = EndpointConfig(
            id: UUID(), name: "Ollama",
            baseURL: "http://localhost:11434/v1", modelName: "llama3.1")
        let resolved = BackendFactory.resolve(
            selection: .endpoint(id: config.id),
            downloadedMLXRepoIDs: [], endpoints: [config])
        XCTAssertEqual(resolved.configDigest, SessionConfigDigest.endpoint(
            baseURL: config.baseURL, modelName: config.modelName))

        var edited = config
        edited.modelName = "qwen2.5"
        let reResolved = BackendFactory.resolve(
            selection: .endpoint(id: config.id),
            downloadedMLXRepoIDs: [], endpoints: [edited])
        XCTAssertNotEqual(reResolved.configDigest, resolved.configDigest)

        let keyA = BackendFactory.resolve(
            selection: .openRouter(modelID: OpenRouterCatalog.best.modelID),
            downloadedMLXRepoIDs: [], endpoints: [],
            openRouterAPIKey: "sk-or-key-a")
        let keyB = BackendFactory.resolve(
            selection: .openRouter(modelID: OpenRouterCatalog.best.modelID),
            downloadedMLXRepoIDs: [], endpoints: [],
            openRouterAPIKey: "sk-or-key-b")
        XCTAssertNotEqual(keyA.configDigest, keyB.configDigest)
        XCTAssertFalse(keyA.configDigest.contains("sk-or-key-a"))
        // Selection-only backends carry the empty digest: their
        // identity is the selection itself.
        let onDevice = BackendFactory.resolve(
            selection: .onDevice, downloadedMLXRepoIDs: [], endpoints: [])
        XCTAssertEqual(onDevice.configDigest, "")
    }

    // MARK: - B-57: FileScopeStore resolution decisions

    @MainActor
    func testUnresolvableFolderContributesNoScopeRoot() throws {
        let suite = "LocalLLMTests.fileScope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A saved folder whose bookmark is garbage: it shows in
        // the list (so the user can remove it) but contributes NO
        // root path — the old fallback returned its picked path,
        // putting an unshared path in tool scope.
        let folder = FileScopeStore.DesignatedFolder(
            id: UUID(), path: "/tmp/definitely-not-shared",
            bookmark: Data("not a bookmark".utf8))
        let data = try JSONEncoder().encode([folder])
        defaults.set(data, forKey: "LocalLLM.fileScope.v1")

        let store = FileScopeStore(defaults: defaults)
        XCTAssertEqual(store.folders.count, 1)
        XCTAssertEqual(store.rootPaths, [])
        XCTAssertFalse(store.isAvailable(folder))
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testAddedFolderResolvesIntoScope() throws {
        let suite = "LocalLLMTests.fileScope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalLLMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = FileScopeStore(defaults: defaults)
        store.addFolder(url: base)
        XCTAssertEqual(store.folders.count, 1)
        XCTAssertNil(store.lastError)
        let folder = try XCTUnwrap(store.folders.first)
        XCTAssertTrue(store.isAvailable(folder))
        XCTAssertEqual(store.rootPaths, [
            base.resolvingSymlinksInPath().standardizedFileURL.path,
        ])
    }

    // MARK: - B-59: editText happy path through the identity check

    func testEditTextExecutesWhenTheFileIsUntouched() async throws {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalLLMTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        let target = base.appendingPathComponent("notes.txt")
        try Data("old contents".utf8).write(to: target)
        let resolvedRoot = FileAccessService.resolvedPath(base.path)!
        let resolvedTarget = FileAccessService.resolvedPath(target.path)!

        guard case .proposed(let action) = ActionProposal.make(
            kind: .editText,
            inputs: ActionInputs(sourcePath: resolvedTarget,
                                 editText: "new contents"),
            roots: [resolvedRoot], probe: FileActionService.probe,
            home: NSHomeDirectory()) else {
            return XCTFail("expected a proposal")
        }
        let backups = base.appendingPathComponent("backups")
        let item = await FileActionService.execute(
            action, roots: [resolvedRoot], backupDirectory: backups)
        guard case .done = item.outcome else {
            return XCTFail("an untouched file must edit cleanly, got \(item.resultNote)")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8),
                       "new contents")
        // The backup of the old version exists for undo.
        let backupPath = try XCTUnwrap(item.backupPath)
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8),
                       "old contents")
    }
}
