import XCTest
@testable import LocalLLM

/// Phase 8 tests: the cloud tier's testable core — the new model
/// selections and their codec, the curated OpenRouter catalog,
/// usage-report parsing and the SSE accumulator's capture of it,
/// usage accounting in request building, live frontier routing
/// (key → OpenRouter, else PCC, else an honest stand-in; Local Only
/// refuses all of it), factory enforcement (no key / Local Only),
/// key-presence gating behind the key-store protocol (never a real
/// Keychain), the picker's cloud rows, honest cost formatting, the
/// cloud error wording, compare seeding, and the tool-result
/// redaction choke point running in its cloud configuration. The
/// Keychain calls, the PCC model value, and the OpenRouter HTTP
/// round trip are thin wrappers exercised on the Mac.
final class CloudTests: XCTestCase {

    // MARK: - Selection codec

    func testPrivateCloudComputeSelectionRoundTrips() {
        let selection = ModelSelection.privateCloudCompute
        XCTAssertEqual(selection.storageKey, "privateCloudCompute")
        XCTAssertEqual(ModelSelection(storageKey: "privateCloudCompute"),
                       .privateCloudCompute)
        XCTAssertTrue(selection.isCloud)
        XCTAssertEqual(selection.budgetKind, .privateCloudCompute)
        XCTAssertEqual(selection.budget.windowTokens, 32_768)
    }

    func testOpenRouterSelectionRoundTrips() {
        let selection = ModelSelection.openRouter(
            modelID: "anthropic/claude-opus-5.5")
        XCTAssertEqual(selection.storageKey,
                       "openRouter:anthropic/claude-opus-5.5")
        XCTAssertEqual(
            ModelSelection(storageKey: "openRouter:anthropic/claude-opus-5.5"),
            selection)
        XCTAssertTrue(selection.isCloud)
        XCTAssertEqual(selection.budgetKind, .openRouterCloud)
        XCTAssertEqual(selection.budget.windowTokens, 128_000)
    }

    func testOpenRouterCustomIDWithColonRoundTrips() {
        // OpenRouter variant ids contain their own ":" — the codec
        // strips only its prefix.
        let selection = ModelSelection.openRouter(
            modelID: "deepseek/deepseek-chat:free")
        XCTAssertEqual(ModelSelection(storageKey: selection.storageKey),
                       selection)
    }

    func testOpenRouterEmptyIDFallsBackToOnDevice() {
        XCTAssertEqual(ModelSelection(storageKey: "openRouter:"), .onDevice)
        // The PCC key must not swallow lookalike values.
        XCTAssertEqual(ModelSelection(storageKey: "privateCloudComputeX"),
                       .onDevice)
    }

    func testLocalSelectionsAreNotCloud() {
        XCTAssertFalse(ModelSelection.auto.isCloud)
        XCTAssertFalse(ModelSelection.onDevice.isCloud)
        XCTAssertFalse(ModelSelection.mlx(repoID: "x").isCloud)
        XCTAssertFalse(ModelSelection.endpoint(id: UUID()).isCloud)
    }

    // MARK: - OpenRouter catalog

    func testCatalogIsTheVerifiedShortlist() {
        // Ids checked against openrouter.ai's live model list on
        // 2026-10-23 (see Core/CloudModels.swift). If this test is
        // updated, the landscape was re-checked — that's the rule.
        XCTAssertEqual(OpenRouterCatalog.models.map(\.modelID), [
            "anthropic/claude-opus-5.5",
            "anthropic/claude-sonnet-5.5",
            "openai/gpt-6-astra",
            "openai/gpt-6.1-sol",
            "google/gemini-3.8-flash",
            "moonshotai/kimi-k3.1-pro",
        ])
        for info in OpenRouterCatalog.models {
            XCTAssertFalse(info.displayName.isEmpty)
            XCTAssertFalse(info.note.isEmpty)
        }
    }

    func testCatalogBestIsTheHeadOfTheList() {
        XCTAssertEqual(OpenRouterCatalog.best.modelID,
                       "anthropic/claude-opus-5.5")
        XCTAssertEqual(OpenRouterCatalog.best.displayName, "Claude Opus 5.5")
    }

    func testCatalogDisplayNameFallsBackToTheID() {
        XCTAssertEqual(
            OpenRouterCatalog.displayName(forModelID: "x-ai/grok-4.7"),
            "x-ai/grok-4.7")
        XCTAssertEqual(
            OpenRouterCatalog.displayName(forModelID: "openai/gpt-6-astra"),
            "GPT-6 Astra")
        XCTAssertNil(OpenRouterCatalog.info(forModelID: "x-ai/grok-4.7"))
    }

    // MARK: - Usage reports

    func testUsageReportParsesAFullChunk() {
        let payload = #"{"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":40,"total_tokens":160,"cost":0.00214}}"#
        let report = UsageReport.parse(payload: payload)
        XCTAssertEqual(report?.promptTokens, 120)
        XCTAssertEqual(report?.completionTokens, 40)
        XCTAssertEqual(report?.totalTokens, 160)
        XCTAssertEqual(report?.costUSD ?? -1, 0.00214, accuracy: 0.000001)
    }

    func testUsageReportParsesTokensWithoutCost() {
        let payload = #"{"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
        let report = UsageReport.parse(payload: payload)
        XCTAssertEqual(report?.totalTokens, 15)
        XCTAssertNil(report?.costUSD)
    }

    func testUsageReportRejectsNonReports() {
        // A content chunk, an empty usage object, and garbage are
        // all "no report" — never a zero-cost invention.
        XCTAssertNil(UsageReport.parse(
            payload: #"{"choices":[{"delta":{"content":"hi"}}]}"#))
        XCTAssertNil(UsageReport.parse(payload: #"{"usage":{}}"#))
        XCTAssertNil(UsageReport.parse(payload: "not json"))
        XCTAssertNil(UsageReport.parse(payload: ""))
    }

    func testUsageReportZeroCostIsARealReport() {
        // A free model reports cost 0 — that's information, not
        // absence, and the pill may honestly show $0.00 for it.
        let report = UsageReport.parse(
            payload: #"{"usage":{"total_tokens":9,"cost":0}}"#)
        XCTAssertEqual(report?.costUSD ?? -1, 0)
    }

    func testSSEAccumulatorCapturesUsageFromTheFinalChunk() {
        var accumulator = SSEAccumulator()
        let content = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        let usage = #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4,"cost":0.0004}}"#
        XCTAssertEqual(accumulator.consume(line: content), "Hello")
        // The usage chunk carries no content — text is untouched,
        // but the report is captured.
        XCTAssertNil(accumulator.consume(line: usage))
        XCTAssertEqual(accumulator.text, "Hello")
        XCTAssertEqual(accumulator.usage?.totalTokens, 4)
        XCTAssertEqual(accumulator.usage?.costUSD ?? -1, 0.0004,
                       accuracy: 0.000001)
        XCTAssertNil(accumulator.consume(line: "data: [DONE]"))
        XCTAssertTrue(accumulator.isDone)
    }

    func testSSEAccumulatorCapturesStreamErrors() {
        // Audit B-08, on the OpenRouter route: an in-stream error
        // payload sets the error state the session throws on,
        // instead of passing off a truncated reply as finished.
        var accumulator = SSEAccumulator()
        XCTAssertEqual(accumulator.consume(
            line: #"data: {"choices":[{"delta":{"content":"Part"}}]}"#),
            "Part")
        XCTAssertNil(accumulator.consume(
            line: #"data: {"error":{"message":"This model is unavailable right now","code":404}}"#))
        XCTAssertEqual(accumulator.errorMessage,
                       "This model is unavailable right now")
        XCTAssertEqual(accumulator.text, "Part")
        XCTAssertNil(SSEAccumulator.errorMessage(
            fromPayload: #"{"choices":[{"delta":{"content":"x"}}]}"#))
    }

    // MARK: - Request building

    func testRequestBuilderAddsUsageAccountingOnlyWhenAsked() throws {
        let withUsage = OpenAIRequestBuilder.bodyData(
            model: "anthropic/claude-opus-5.5", instructions: "",
            history: [], newUserMessage: "hi", includeUsage: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: withUsage) as? [String: Any])
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["include"] as? Bool, true)

        let without = OpenAIRequestBuilder.bodyData(
            model: "llama3.1", instructions: "", history: [],
            newUserMessage: "hi")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(
            with: without) as? [String: Any])
        XCTAssertNil(plain["usage"])
    }

    // MARK: - Routing goes live

    private func inputs(key: Bool = false, pcc: Bool = false,
                        localOnly: Bool = false,
                        endpoints: [EndpointConfig] = []) -> RoutingInputs {
        RoutingInputs(downloadedMLX: [], endpoints: endpoints,
                      localOnly: localOnly, openRouterKeyPresent: key,
                      pccReady: pcc, onDeviceReady: true)
    }

    func testRoutingFrontierPrefersOpenRouterWithKey() {
        let decision = RoutingPolicy.decide(
            intent: .frontierCloud, inputs: inputs(key: true, pcc: true))
        XCTAssertEqual(decision.selection,
                       .openRouter(modelID: OpenRouterCatalog.best.modelID))
        XCTAssertTrue(decision.reason.contains("Claude Opus 5.5"))
        XCTAssertTrue(decision.reason.contains("privacy check"))
        XCTAssertNil(decision.note)
    }

    func testRoutingFrontierFallsToPCCWithoutKey() {
        let decision = RoutingPolicy.decide(
            intent: .frontierCloud, inputs: inputs(pcc: true))
        XCTAssertEqual(decision.selection, .privateCloudCompute)
        XCTAssertTrue(decision.reason.contains("Apple Private Cloud"))
    }

    func testRoutingFrontierStandsInWhenNoCloudRoute() {
        let decision = RoutingPolicy.decide(
            intent: .frontierCloud, inputs: inputs())
        XCTAssertEqual(decision.selection, .onDevice)
        XCTAssertTrue(decision.reason.contains("no cloud route is ready"))
        XCTAssertTrue(decision.note?.contains("OpenRouter key") == true)
    }

    func testRoutingFrontierLocalOnlyNeverRoutesToCloud() {
        // Key saved AND PCC offered — the lock still wins, for both
        // the cloud routes and a configured server.
        let locked = RoutingPolicy.decide(
            intent: .frontierCloud,
            inputs: inputs(key: true, pcc: true, localOnly: true,
                           endpoints: EndpointConfig.defaultConfigs))
        XCTAssertEqual(locked.selection, .onDevice)
        XCTAssertTrue(locked.note?.contains("Local Only") == true)
    }

    func testRoutingCloudAvailabilityIsDerived() {
        XCTAssertFalse(inputs().cloudAvailable)
        XCTAssertTrue(inputs(key: true).cloudAvailable)
        XCTAssertTrue(inputs(pcc: true).cloudAvailable)
    }

    func testRoutingOtherIntentsIgnoreTheCloud() {
        let withKey = inputs(key: true, pcc: true)
        XCTAssertEqual(RoutingPolicy.decide(
            intent: .quickTransform, inputs: withKey).selection, .onDevice)
        XCTAssertEqual(RoutingPolicy.decide(
            intent: .osAction, inputs: withKey).selection, .onDevice)
    }

    // MARK: - Factory enforcement

    func testFactoryBuildsOpenRouterBackendWithKey() {
        let resolved = BackendFactory.resolve(
            selection: .openRouter(modelID: "anthropic/claude-opus-5.5"),
            downloadedMLXRepoIDs: [], endpoints: [],
            openRouterAPIKey: "sk-or-test-key")
        XCTAssertEqual(resolved.effectiveSelection,
                       .openRouter(modelID: "anthropic/claude-opus-5.5"))
        XCTAssertEqual(resolved.backend.displayName, "Claude Opus 5.5")
        XCTAssertEqual(resolved.backend.budget.windowTokens, 128_000)
        XCTAssertFalse(resolved.backend.supportsTools)
    }

    func testFactoryRefusesOpenRouterWithoutKey() {
        for key: String? in [nil, "", "   "] {
            let resolved = BackendFactory.resolve(
                selection: .openRouter(modelID: "openai/gpt-6-astra"),
                downloadedMLXRepoIDs: [], endpoints: [],
                openRouterAPIKey: key)
            XCTAssertEqual(resolved.effectiveSelection, .onDevice)
        }
    }

    func testFactoryRefusesCloudUnderLocalOnly() {
        let openRouter = BackendFactory.resolve(
            selection: .openRouter(modelID: "openai/gpt-6-astra"),
            downloadedMLXRepoIDs: [], endpoints: [], localOnly: true,
            openRouterAPIKey: "sk-or-test-key")
        XCTAssertEqual(openRouter.effectiveSelection, .onDevice)

        let pcc = BackendFactory.resolve(
            selection: .privateCloudCompute,
            downloadedMLXRepoIDs: [], endpoints: [], localOnly: true)
        XCTAssertEqual(pcc.effectiveSelection, .onDevice)
    }

    func testFactoryBuildsPCCBackend() {
        let resolved = BackendFactory.resolve(
            selection: .privateCloudCompute,
            downloadedMLXRepoIDs: [], endpoints: [])
        XCTAssertEqual(resolved.effectiveSelection, .privateCloudCompute)
        XCTAssertEqual(resolved.backend.displayName, "Apple Private Cloud")
        XCTAssertEqual(resolved.backend.budget.windowTokens, 32_768)
        // PCC is a framework backend: tools yes (the engine redacts
        // their results — see the choke-point test below).
        XCTAssertTrue(resolved.backend.supportsTools)
    }

    // MARK: - Key gating (protocol, never the real Keychain)

    func testInMemoryKeyStoreRoundTrips() {
        let store = InMemoryAPIKeyStore()
        XCTAssertNil(store.readKey())
        store.saveKey("sk-or-abc")
        XCTAssertEqual(store.readKey(), "sk-or-abc")
        store.deleteKey()
        XCTAssertNil(store.readKey())
    }

    @MainActor
    func testKeyStorePresenceLifecycle() {
        let keyStore = OpenRouterKeyStore(store: InMemoryAPIKeyStore())
        XCTAssertFalse(keyStore.hasKey)
        XCTAssertNil(keyStore.currentKey())

        keyStore.setKey("  sk-or-trimmed  ")
        XCTAssertTrue(keyStore.hasKey)
        XCTAssertEqual(keyStore.currentKey(), "sk-or-trimmed")

        // A blank paste is a removal, not a saved empty key.
        keyStore.setKey("   ")
        XCTAssertFalse(keyStore.hasKey)

        keyStore.setKey("sk-or-again")
        XCTAssertTrue(keyStore.hasKey)
        keyStore.removeKey()
        XCTAssertFalse(keyStore.hasKey)
        XCTAssertNil(keyStore.currentKey())
    }

    @MainActor
    func testCustomModelIDPersists() {
        let suite = "LocalLLMTests.cloud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.openRouterCustomModelID, "")
        settings.openRouterCustomModelID = "x-ai/grok-4.7"
        let reread = AppSettings(defaults: defaults)
        XCTAssertEqual(reread.openRouterCustomModelID, "x-ai/grok-4.7")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Picker rows for the cloud

    func testRegistryCloudRowsWithKeyAndPCC() {
        let rows = BackendRegistry.descriptors(
            downloadedMLX: [], endpoints: [], onDeviceReady: true,
            cloud: CloudPickerInputs(pccReady: true,
                                     openRouterKeyPresent: true,
                                     customOpenRouterModelID: "x-ai/grok-4.7"))
        let pcc = rows.first { $0.selection == .privateCloudCompute }
        XCTAssertEqual(pcc?.isReady, true)
        XCTAssertEqual(pcc?.budget.windowTokens, 32_768)
        let opus = rows.first {
            $0.selection == .openRouter(modelID: "anthropic/claude-opus-5.5")
        }
        XCTAssertEqual(opus?.displayName, "Claude Opus 5.5")
        XCTAssertEqual(opus?.isReady, true)
        let custom = rows.first {
            $0.selection == .openRouter(modelID: "x-ai/grok-4.7")
        }
        XCTAssertEqual(custom?.displayName, "x-ai/grok-4.7")
        XCTAssertTrue(custom?.detail.contains("custom model") == true)
        // Auto, on-device, PCC, 6 curated, 1 custom.
        XCTAssertEqual(rows.count, 3 + OpenRouterCatalog.models.count + 1)
    }

    func testRegistryCloudRowsWithoutKeySaySo() {
        let rows = BackendRegistry.descriptors(
            downloadedMLX: [], endpoints: [], onDeviceReady: true,
            cloud: CloudPickerInputs(
                pccReady: false, openRouterKeyPresent: false,
                customOpenRouterModelID: ""))
        let openRouterRows = rows.filter { $0.selection.isCloud
            && $0.selection != .privateCloudCompute }
        XCTAssertEqual(openRouterRows.count, OpenRouterCatalog.models.count)
        for row in openRouterRows {
            XCTAssertFalse(row.isReady)
            XCTAssertTrue(row.detail.contains("needs your key"))
        }
    }

    func testRegistryCustomIDDeduplicatesCurated() {
        // A custom id that IS a curated model must not add a row.
        let rows = BackendRegistry.descriptors(
            downloadedMLX: [], endpoints: [], onDeviceReady: true,
            cloud: CloudPickerInputs(
                pccReady: false, openRouterKeyPresent: true,
                customOpenRouterModelID: " openai/gpt-6-astra "))
        let astra = rows.filter {
            $0.selection == .openRouter(modelID: "openai/gpt-6-astra")
        }
        XCTAssertEqual(astra.count, 1)
        XCTAssertEqual(astra.first?.displayName, "GPT-6 Astra")
    }

    // MARK: - Cost honesty

    func testCostTextPrecision() {
        XCTAssertEqual(TelemetryFormat.costText(0), "$0.00")
        XCTAssertEqual(TelemetryFormat.costText(0.5), "$0.50")
        XCTAssertEqual(TelemetryFormat.costText(0.0214), "$0.02")
        // Fractions of a cent keep their digits — a real charge
        // never rounds down to a fake "$0.00".
        XCTAssertEqual(TelemetryFormat.costText(0.0042), "$0.0042")
        XCTAssertEqual(TelemetryFormat.costText(-1), "$0.00")
    }

    func testTelemetryLabelsNameTheCloud() {
        XCTAssertEqual(
            TelemetryFormat.label(for: .privateCloudCompute,
                                  displayName: "ignored"),
            "Cloud · Apple Private Cloud")
        XCTAssertEqual(
            TelemetryFormat.label(
                for: .openRouter(modelID: "anthropic/claude-opus-5.5"),
                displayName: "Claude Opus 5.5"),
            "Cloud · OpenRouter · Claude Opus 5.5")
    }

    func testTelemetryLineShowsRealCostOrUnknown() {
        let known = MessageTelemetry(
            backendLabel: "Cloud · OpenRouter · Claude Opus 5.5",
            seconds: 4.12, estimatedTokens: 512,
            costUSD: 0.0042, costKnown: true)
        XCTAssertEqual(TelemetryFormat.line(for: known),
                       "Cloud · OpenRouter · Claude Opus 5.5 · 4.1s "
                        + "· ≈512 tokens · $0.0042")

        let unknown = MessageTelemetry(
            backendLabel: "Cloud · OpenRouter · GPT-6 Astra",
            seconds: 2.0, estimatedTokens: 100,
            costUSD: 0, costKnown: false)
        let line = TelemetryFormat.line(for: unknown)
        XCTAssertTrue(line.hasSuffix("cost unknown"))
        XCTAssertFalse(line.contains("$"))
    }

    func testMessageTelemetryRoundTripsCost() {
        let message = Message(role: .assistant, text: "hi")
        message.telemetry = MessageTelemetry(
            backendLabel: "Cloud · OpenRouter · Claude Opus 5.5",
            seconds: 1.5, estimatedTokens: 42,
            costUSD: 0.0042, costKnown: true)
        XCTAssertEqual(message.telemetry?.costUSD ?? -1, 0.0042,
                       accuracy: 0.000001)
        XCTAssertEqual(message.telemetry?.costKnown, true)

        message.telemetry = MessageTelemetry(
            backendLabel: "Cloud · OpenRouter · GPT-6 Astra",
            seconds: 1.5, estimatedTokens: 42,
            costUSD: 0, costKnown: false)
        XCTAssertEqual(message.telemetry?.costKnown, false)

        // A pre-Phase-8 local reply: no cost fields stored, reads
        // back as a known $0.00.
        let legacy = Message(role: .assistant, text: "old")
        legacy.telemetryBackendLabel = "Apple On-Device"
        legacy.telemetrySeconds = 1.0
        legacy.telemetryTokens = 10
        XCTAssertEqual(legacy.telemetry?.costUSD, 0)
        XCTAssertEqual(legacy.telemetry?.costKnown, true)
    }

    // MARK: - Cloud error wording

    func testOpenRouterErrorMapping() {
        XCTAssertTrue(BackendError.openRouterHTTP(status: 401)
            .localizedDescription.contains("didn't accept"))
        XCTAssertTrue(BackendError.openRouterHTTP(status: 403)
            .localizedDescription.contains("didn't accept"))
        XCTAssertTrue(BackendError.openRouterHTTP(status: 402)
            .localizedDescription.contains("out of credit"))
        XCTAssertTrue(BackendError.openRouterHTTP(status: 429)
            .localizedDescription.contains("rate-limiting"))
        XCTAssertTrue(BackendError.openRouterHTTP(status: 500)
            .localizedDescription.contains("HTTP 500"))
        XCTAssertTrue(BackendError.openRouterUnreachable
            .localizedDescription.contains("Couldn't reach OpenRouter"))
    }

    // MARK: - Compare seeding

    func testCompareSeedBuildsTheConversationShape() {
        let seed = CompareSeeding.seed(
            prompt: "  Explain tides simply  ",
            answer: " The Moon pulls… ",
            selection: .privateCloudCompute)
        XCTAssertEqual(seed.title, "Explain tides simply")
        XCTAssertEqual(seed.userText, "Explain tides simply")
        XCTAssertEqual(seed.assistantText, "The Moon pulls…")
        XCTAssertEqual(seed.selection, .privateCloudCompute)
    }

    func testCompareSeedEdgeCases() {
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(CompareSeeding.seed(
            prompt: long, answer: "x", selection: .onDevice).title.count, 48)
        XCTAssertEqual(CompareSeeding.seed(
            prompt: "   ", answer: "x", selection: .onDevice).title,
            "Comparison")
        XCTAssertFalse(CompareSeeding.canContinue(answer: ""))
        XCTAssertFalse(CompareSeeding.canContinue(answer: "  \n "))
        XCTAssertTrue(CompareSeeding.canContinue(answer: "an answer"))
    }

    // MARK: - Compare honesty (UAT-01)

    func testCompareFallbackNoticeNamesTheBackendThatAnswered() {
        // A cloud pick resolved to the built-in model: the notice
        // must name BOTH, so the answer is never read as the
        // cloud model's work.
        let notice = CompareNotices.fallbackNotice(
            pickedSelection: .openRouter(
                modelID: "anthropic/claude-opus-5.5"),
            effectiveSelection: .onDevice,
            pickedName: "Claude Opus 5.5",
            effectiveName: "Apple On-Device")
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("Claude Opus 5.5"))
        XCTAssertTrue(notice!.contains("Apple On-Device"))
        XCTAssertTrue(notice!.contains("answered"))
    }

    func testCompareFallbackNoticeSilentWhenPickRan() {
        XCTAssertNil(CompareNotices.fallbackNotice(
            pickedSelection: .privateCloudCompute,
            effectiveSelection: .privateCloudCompute,
            pickedName: "Apple Private Cloud",
            effectiveName: "Apple Private Cloud"))
        XCTAssertNil(CompareNotices.fallbackNotice(
            pickedSelection: .onDevice,
            effectiveSelection: .onDevice,
            pickedName: "Apple On-Device",
            effectiveName: "Apple On-Device"))
    }

    func testCompareUnavailableNotesNameTheRemedy() {
        XCTAssertTrue(CompareNotices.unavailableNote(
            for: .openRouter(modelID: "x/y")).contains("OpenRouter key"))
        XCTAssertTrue(CompareNotices.unavailableNote(
            for: .privateCloudCompute).contains("isn't available"))
        XCTAssertTrue(CompareNotices.unavailableNote(
            for: .onDevice).contains("isn't ready"))
    }

    // MARK: - Tool-result redaction, in its cloud configuration

    private actor EventBox {
        var events: [ToolEvent] = []
        func add(_ event: ToolEvent) { events.append(event) }
    }

    func testRuntimeRedactsBuiltinPatternsForCloudHosts() async {
        // The Phase 8 activation: a cloud host's runtime (PCC) is
        // built with redactResults on. Even with NO custom terms, a
        // built-in pattern (an email address) in a lookup result
        // never comes back out — so it can never enter the cloud
        // session's history unscrubbed.
        let box = EventBox()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("reach sam@example.com about it",
                             forType: .string)
        let runtime = ToolRuntime(
            configuration: ToolRuntime.Configuration(
                conversationID: UUID(),
                enabledSources: [.clipboard],
                folderRootPaths: [],
                redactResults: true,
                redactionTerms: []),
            sink: { event in await box.add(event) },
            permissionProvider: { _ in .authorized })
        let result = await runtime.execute(
            toolName: "read_clipboard", arguments: ToolArguments())
        XCTAssertFalse(result.contains("sam@example.com"))
        XCTAssertTrue(result.contains("[redacted]"))
    }

    // MARK: - Remote destination test (audit S-01 / S-08 / S-09)

    private func endpoint(_ url: String, id: UUID = UUID()) -> EndpointConfig {
        EndpointConfig(id: id, name: "Server", baseURL: url,
                       modelName: "llama3.1")
    }

    func testRemoteDestinationClassification() {
        let local = endpoint("http://localhost:11434/v1")
        let remote = endpoint("http://192.168.1.20:11434/v1")
        let endpoints = [local, remote]
        XCTAssertTrue(RemoteDestination.isRemote(
            selection: .privateCloudCompute, endpoints: endpoints))
        XCTAssertTrue(RemoteDestination.isRemote(
            selection: .openRouter(modelID: "x/y"), endpoints: endpoints))
        XCTAssertFalse(RemoteDestination.isRemote(
            selection: .endpoint(id: local.id), endpoints: endpoints))
        XCTAssertTrue(RemoteDestination.isRemote(
            selection: .endpoint(id: remote.id), endpoints: endpoints))
        XCTAssertFalse(RemoteDestination.isRemote(
            selection: .onDevice, endpoints: endpoints))
        XCTAssertFalse(RemoteDestination.isRemote(
            selection: .mlx(repoID: "x"), endpoints: endpoints))
        XCTAssertFalse(RemoteDestination.isRemote(
            selection: .auto, endpoints: endpoints))
    }

    func testRemoteDestinationMissingConfigFailsClosed() {
        // Audit S-08: an endpoint selection with no matching config
        // used to count as LOCAL (no scrub). It must count remote.
        XCTAssertTrue(RemoteDestination.isRemote(
            selection: .endpoint(id: UUID()), endpoints: []))
    }

    func testCompareScrubAppliesOnlyToRemoteDestinations() {
        // The exact helper CompareColumn.run sends through (S-01).
        let secret = "mail me at sam@example.com please"
        let cloud = RemoteDestination.scrubbed(
            secret, selection: .privateCloudCompute, endpoints: [],
            customTerms: [])
        XCTAssertFalse(cloud.text.contains("sam@example.com"))
        XCTAssertTrue(cloud.didRedact)

        let local = RemoteDestination.scrubbed(
            secret, selection: .onDevice, endpoints: [], customTerms: [])
        XCTAssertEqual(local.text, secret)
        XCTAssertEqual(local.replacementCount, 0)

        // Custom terms apply in compare too.
        let termed = RemoteDestination.scrubbed(
            "the Falcon plan", selection: .openRouter(modelID: "x/y"),
            endpoints: [], customTerms: ["Falcon"])
        XCTAssertFalse(termed.text.contains("Falcon"))
    }

    func testRemoteNoticeAlwaysShownForRemoteSends() {
        // Audit S-09: zero redactions still earns a notice.
        let quiet = RemoteDestination.noticeText(
            redactions: 0, backendDisplayName: "Apple Private Cloud",
            selection: .privateCloudCompute)
        XCTAssertTrue(quiet.contains("Sent to"))
        XCTAssertTrue(quiet.contains("privacy check ran"))

        let hidden = RemoteDestination.noticeText(
            redactions: 2, backendDisplayName: "Apple Private Cloud",
            selection: .privateCloudCompute)
        XCTAssertTrue(hidden.contains("Privacy check: 2 items"))
        XCTAssertTrue(hidden.contains("were hidden"))

        let one = RemoteDestination.noticeText(
            redactions: 1, backendDisplayName: "My Server",
            selection: .endpoint(id: UUID()))
        XCTAssertTrue(one.contains("1 item"))
        XCTAssertTrue(one.contains("isn't on this Mac"))
    }

    func testImagesAreStrippedOnlyForRemoteDestinations() {
        // Audit S-03.
        XCTAssertTrue(RemoteDestination.shouldStripImages(
            isRemote: true, imageCount: 1))
        XCTAssertFalse(RemoteDestination.shouldStripImages(
            isRemote: false, imageCount: 2))
        XCTAssertFalse(RemoteDestination.shouldStripImages(
            isRemote: true, imageCount: 0))
        let notice = RemoteDestination.imageStripNoticeText(
            backendDisplayName: "Apple Private Cloud",
            selection: .privateCloudCompute)
        XCTAssertTrue(notice.contains("Images weren't sent"))
        XCTAssertTrue(notice.contains("cloud"))
    }

    func testEndpointRemoteHTTPWarning() {
        // Audit S-09 (a): only the non-local + http:// combination.
        XCTAssertNotNil(endpoint("http://192.168.1.20:11434/v1")
            .remoteHTTPWarning)
        XCTAssertNil(endpoint("https://192.168.1.20:11434/v1")
            .remoteHTTPWarning)
        XCTAssertNil(endpoint("http://localhost:11434/v1")
            .remoteHTTPWarning)
        XCTAssertTrue(endpoint("http://example.com/v1").usesPlainHTTP)
        XCTAssertFalse(endpoint("https://example.com/v1").usesPlainHTTP)
    }

    // MARK: - Key save reporting (audit S-10)

    private struct FailingKeyStore: APIKeyStoring {
        func readKey() -> String? { nil }
        func saveKey(_ key: String) -> Bool { false }
        func deleteKey() {}
    }

    func testKeySaveReportsSuccess() {
        let store = InMemoryAPIKeyStore()
        XCTAssertTrue(store.saveKey("sk-or-abc"))
        XCTAssertEqual(store.readKey(), "sk-or-abc")
    }

    @MainActor
    func testKeyStoreSurfacesASaveFailure() {
        let keyStore = OpenRouterKeyStore(store: FailingKeyStore())
        XCTAssertFalse(keyStore.setKey("sk-or-nope"))
        XCTAssertFalse(keyStore.hasKey)
        XCTAssertNil(keyStore.currentKey())
    }

    @MainActor
    func testKeyStoreSetKeyReturnsTrueOnSuccess() {
        let keyStore = OpenRouterKeyStore(store: InMemoryAPIKeyStore())
        XCTAssertTrue(keyStore.setKey("sk-or-fine"))
        XCTAssertTrue(keyStore.hasKey)
    }
}
