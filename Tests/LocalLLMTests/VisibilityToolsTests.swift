import AppKit
import XCTest
@testable import LocalLLM

/// Phase 5 tests: the visibility layer's pure logic — the calculator
/// parser, the shared-folder scope check (security-critical), the
/// tool catalog and argument shaping, result clamping, the Spotlight
/// query builder, permission guidance, and the tool runtime's gating
/// (enabled / permission / unknown) with services kept out of the way.
/// The framework-facing services (EventKit, PhotoKit, …) are thin
/// wrappers over these pieces and are exercised on the Mac.
final class VisibilityToolsTests: XCTestCase {

    // MARK: - Calculator

    func testCalculatorRespectsPrecedenceAndParentheses() {
        XCTAssertEqual(Calculator.evaluate("2 + 3 * 4"), "14")
        XCTAssertEqual(Calculator.evaluate("(2 + 3) * 4"), "20")
        XCTAssertEqual(Calculator.evaluate("10 / 4"), "2.5")
        XCTAssertEqual(Calculator.evaluate("10 % 3"), "1")
    }

    func testCalculatorPowerIsRightAssociative() {
        XCTAssertEqual(Calculator.evaluate("2 ^ 10"), "1024")
        XCTAssertEqual(Calculator.evaluate("2 ^ 3 ^ 2"), "512") // 2^(3^2)
    }

    func testCalculatorUnaryMinusAndFunctions() {
        XCTAssertEqual(Calculator.evaluate("-3 + 5"), "2")
        XCTAssertEqual(Calculator.evaluate("-(2 + 3)"), "-5")
        XCTAssertEqual(Calculator.evaluate("sqrt(9) + abs(-2)"), "5")
    }

    func testCalculatorFormatsResultsCleanly() {
        XCTAssertEqual(Calculator.evaluate("0.1 + 0.2"), "0.3")
        XCTAssertEqual(Calculator.evaluate("0 * -1"), "0") // no "-0"
        XCTAssertEqual(Calculator.evaluate("50 * 1.08"), "54")
        XCTAssertEqual(Calculator.evaluate("1 / 3"), "0.333333")
    }

    func testCalculatorErrorsArePlainEnglish() {
        XCTAssertTrue(Calculator.evaluate("1 / 0").contains("division by zero"))
        XCTAssertTrue(Calculator.evaluate("1 % 0").contains("remainder by zero"))
        XCTAssertTrue(Calculator.evaluate("2 +").hasPrefix("Couldn't calculate"))
        XCTAssertTrue(Calculator.evaluate("hello").hasPrefix("Couldn't calculate"))
        XCTAssertTrue(Calculator.evaluate("sin(1)").hasPrefix("Couldn't calculate"))
        XCTAssertTrue(Calculator.evaluate("").contains("no expression"))
        XCTAssertTrue(Calculator.evaluate("sqrt(-1)").hasPrefix("Couldn't calculate"))
        XCTAssertTrue(Calculator.evaluate("2 2").hasPrefix("Couldn't calculate"))
    }

    // MARK: - File scope (the security boundary — test it hard)

    private let root = "/Users/test/Documents"

    func testScopeAdmitsTheRootItselfAndChildren() {
        XCTAssertTrue(FileScope.isPath(root, insideAnyRoot: [root]))
        XCTAssertTrue(FileScope.isPath(root + "/notes.txt", insideAnyRoot: [root]))
        XCTAssertTrue(FileScope.isPath(root + "/a/b/c/deep.txt", insideAnyRoot: [root]))
    }

    func testScopeRefusesDotDotEscapes() {
        XCTAssertFalse(FileScope.isPath(root + "/../Secrets/x.txt", insideAnyRoot: [root]))
        XCTAssertFalse(FileScope.isPath(root + "/sub/../../Secrets", insideAnyRoot: [root]))
        XCTAssertFalse(FileScope.isPath("/Users/test", insideAnyRoot: [root]))
        XCTAssertFalse(FileScope.isPath("/etc/passwd", insideAnyRoot: [root]))
    }

    func testScopeRefusesPrefixSiblingTricks() {
        // "Documents2" merely starts with "Documents" — not inside it.
        XCTAssertFalse(FileScope.isPath("/Users/test/Documents2/x.txt", insideAnyRoot: [root]))
        XCTAssertFalse(FileScope.isPath("/Users/test/Documents-old", insideAnyRoot: [root]))
    }

    func testScopeHandlesSlashesDotsAndCase() {
        XCTAssertTrue(FileScope.isPath(root + "/f.txt", insideAnyRoot: [root + "/"]))
        XCTAssertTrue(FileScope.isPath(root + "/./sub/../f.txt", insideAnyRoot: [root]))
        XCTAssertTrue(FileScope.isPath("/users/TEST/documents/F.TXT", insideAnyRoot: [root]))
    }

    func testScopeEmptyRootsAndRelativePathsAdmitNothing() {
        XCTAssertFalse(FileScope.isPath(root + "/f.txt", insideAnyRoot: []))
        XCTAssertFalse(FileScope.isPath("Documents/f.txt", insideAnyRoot: [root]))
        XCTAssertFalse(FileScope.isPath(root + "/f.txt", insideAnyRoot: ["relative/root"]))
    }

    func testScopeFilesystemRootAdmitsEverything() {
        XCTAssertTrue(FileScope.isPath("/anything/at/all", insideAnyRoot: ["/"]))
    }

    func testNormalizedPath() {
        XCTAssertEqual(FileScope.normalizedPath("/a/b/"), "/a/b")
        XCTAssertEqual(FileScope.normalizedPath("/"), "/")
        XCTAssertEqual(FileScope.normalizedPath("/a/./b/../c"), "/a/c")
    }

    // MARK: - Tool catalog

    func testCatalogNamesAreUniqueAndComplete() {
        let names = ToolCatalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 15)
        for descriptor in ToolCatalog.all {
            XCTAssertFalse(descriptor.modelDescription.isEmpty, descriptor.name)
            XCTAssertFalse(descriptor.displayName.isEmpty, descriptor.name)
        }
    }

    func testEverySourceHasAtLeastOneTool() {
        for source in VisibilitySource.allCases {
            XCTAssertTrue(
                ToolCatalog.all.contains { $0.source == source },
                "no tool for \(source.rawValue)")
        }
    }

    func testNoSourcesEnabledMeansNoToolsAtAll() {
        XCTAssertTrue(ToolCatalog.descriptors(enabledSources: []).isEmpty)
    }

    func testUtilitiesRideAlongWithAnyEnabledSource() {
        let names = Set(ToolCatalog.descriptors(enabledSources: [.calendar]).map(\.name))
        XCTAssertEqual(names, ["calendar_events", "calculate", "current_time"])
    }

    func testAllSourcesEnabledMeansTheWholeCatalog() {
        // "The whole catalog" now means every gate open: the action
        // tools (Phase 6) and the power tools (Phase 9) sit behind
        // their own toggles, so both are enabled here on purpose.
        let descriptors = ToolCatalog.descriptors(
            enabledSources: Set(VisibilitySource.allCases),
            fileWritingEnabled: true,
            powerToolsEnabled: true)
        XCTAssertEqual(descriptors.count, ToolCatalog.all.count)
    }

    // MARK: - Tool arguments

    func testArgumentClampsAndDefaults() {
        let empty = ToolArguments()
        XCTAssertEqual(empty.limitClamped, 8)
        XCTAssertEqual(empty.daysClamped, 7)
        XCTAssertEqual(empty.indexClamped, 0)
        XCTAssertEqual(ToolArguments(limit: 0).limitClamped, 1)
        XCTAssertEqual(ToolArguments(limit: 999).limitClamped, 25)
        XCTAssertEqual(ToolArguments(days: 0).daysClamped, 1)
        XCTAssertEqual(ToolArguments(days: 999).daysClamped, 60)
        XCTAssertEqual(ToolArguments(index: -5).indexClamped, 0)
    }

    func testArgumentConversionFromBackendValues() {
        let arguments = ToolArguments(values: [
            "query": .string("roof"),
            "limit": .string("5"),   // models are loose with JSON types
            "days": .double(3),
            "index": .int(2)
        ])
        XCTAssertEqual(arguments.query, "roof")
        XCTAssertEqual(arguments.limit, 5)
        XCTAssertEqual(arguments.days, 3)
        XCTAssertEqual(arguments.index, 2)
    }

    func testArgumentConversionRejectsOutOfRangeDoubles() {
        // Audit B-02: Int(Double) traps on out-of-range, NaN, and
        // infinite values — all emittable by a model. They must
        // read as "no value", so the clamped accessors fall back
        // to their defaults instead of crashing the app.
        XCTAssertNil(ToolArguments(values: ["limit": .double(1e30)]).limit)
        XCTAssertNil(ToolArguments(values: ["limit": .double(.infinity)]).limit)
        XCTAssertNil(ToolArguments(values: ["limit": .double(.nan)]).limit)
        XCTAssertNil(ToolArguments(values: ["days": .double(-1e30)]).days)
        XCTAssertEqual(
            ToolArguments(values: ["limit": .double(1e30)]).limitClamped, 8)
        // An ordinary fractional double still converts (truncating),
        // exactly as before.
        XCTAssertEqual(ToolArguments(values: ["days": .double(3.9)]).days, 3)
    }

    func testArgumentSummariesForTheLog() {
        XCTAssertEqual(
            ToolArguments(query: "roof").summary(for: "search_files"), "“roof”")
        XCTAssertEqual(
            ToolArguments(path: "/a/b").summary(for: "read_file"), "/a/b")
        XCTAssertEqual(
            ToolArguments().summary(for: "calendar_events"), "next 7 days")
        XCTAssertEqual(
            ToolArguments(expression: "2+2").summary(for: "calculate"), "2+2")
    }

    // MARK: - Result sizing

    func testResultClampLeavesShortResultsAlone() {
        XCTAssertEqual(ToolResultText.clamp("short"), "short")
    }

    func testResultClampTrimsLongResultsWithANote() {
        let long = String(repeating: "x", count: ToolResultText.maxCharacters + 500)
        let clamped = ToolResultText.clamp(long)
        XCTAssertTrue(clamped.hasPrefix(String(repeating: "x", count: ToolResultText.maxCharacters)))
        XCTAssertTrue(clamped.contains("trimmed"))
        XCTAssertLessThan(clamped.count, long.count)
    }

    func testResultSummaryIsTheFirstLineCapped() {
        XCTAssertEqual(ToolResultText.summary(of: "first\nsecond"), "first")
        let longLine = String(repeating: "y", count: 150)
        XCTAssertEqual(ToolResultText.summary(of: longLine).count, 101) // 100 + "…"
    }

    func testAccessLogRotationMath() {
        XCTAssertEqual(AccessLogPolicy.excessCount(totalRecords: 0), 0)
        XCTAssertEqual(AccessLogPolicy.excessCount(totalRecords: AccessLogPolicy.maxRecords), 0)
        XCTAssertEqual(AccessLogPolicy.excessCount(totalRecords: AccessLogPolicy.maxRecords + 1), 1)
        XCTAssertEqual(AccessLogPolicy.excessCount(totalRecords: 1000), 700)
    }

    func testAvailabilitySignatureTracksSourcesAndFolders() {
        let a = ToolAvailability(enabledSources: [.calendar], folderRootPaths: [])
        let b = ToolAvailability(enabledSources: [.calendar, .photos], folderRootPaths: [])
        let c = ToolAvailability(enabledSources: [.calendar], folderRootPaths: ["/x"])
        XCTAssertNotEqual(a.signature, b.signature)
        XCTAssertNotEqual(a.signature, c.signature)
        XCTAssertEqual(a.signature,
                       ToolAvailability(enabledSources: [.calendar], folderRootPaths: []).signature)
        XCTAssertFalse(ToolAvailability.none.hasTools)
        XCTAssertTrue(a.hasTools)
    }

    // MARK: - Spotlight query building

    func testSpotlightEscapesQuotesAndBackslashes() {
        XCTAssertEqual(SpotlightQueryBuilder.escape("a\"b\\c"), "a\\\"b\\\\c")
    }

    func testSpotlightEscapesPercentForThePredicateFormat() {
        // Audit B-04: the built string is handed to
        // NSPredicate(format:), where a raw % is a format
        // specifier — an ordinary phrase like "100%" must reach
        // the predicate as a literal percent.
        XCTAssertEqual(SpotlightQueryBuilder.escape("100%"), "100%%")
        let format = SpotlightQueryBuilder.predicateFormat(
            forPhrase: "50% off")
        XCTAssertTrue(try! XCTUnwrap(format).contains("50%%"))
    }

    func testSpotlightPredicateShape() {
        let format = SpotlightQueryBuilder.predicateFormat(forPhrase: "roof invoice")
        let predicate = try! XCTUnwrap(format)
        XCTAssertTrue(predicate.contains("kMDItemDisplayName"))
        XCTAssertTrue(predicate.contains("kMDItemTextContent"))
        XCTAssertTrue(predicate.contains("\"roof\""))
        XCTAssertTrue(predicate.contains("\"invoice\""))
        XCTAssertTrue(predicate.contains("&&")) // every keyword must match
    }

    func testSpotlightPredicateRejectsEmptyPhrases() {
        XCTAssertNil(SpotlightQueryBuilder.predicateFormat(forPhrase: ""))
        XCTAssertNil(SpotlightQueryBuilder.predicateFormat(forPhrase: "   "))
    }

    func testSpotlightPredicateEscapesInjectionAttempts() {
        let format = SpotlightQueryBuilder.predicateFormat(
            forPhrase: "x\" || kMDItemFSName == \"y")
        let predicate = try! XCTUnwrap(format)
        XCTAssertTrue(predicate.contains("\\\"")) // the quote stayed a literal
    }

    func testSpotlightResultFormatting() {
        XCTAssertEqual(
            SpotlightQueryBuilder.formatResults([], totalCount: 0),
            "No files matched that search.")
        let text = SpotlightQueryBuilder.formatResults(
            [(name: "a.pdf", path: "/x/a.pdf", modified: nil),
             (name: "b.pdf", path: "/x/b.pdf", modified: nil)],
            totalCount: 5)
        XCTAssertTrue(text.hasPrefix("Found 5 files:"))
        XCTAssertTrue(text.contains("Showing the first 2"))
    }

    // MARK: - Permission guidance

    func testPermissionGuidanceNamesTheRightPane() {
        let text = PermissionGuidance.text(source: .calendar, state: .denied)
        XCTAssertTrue(try! XCTUnwrap(text).contains("Calendars"))
        let music = PermissionGuidance.text(source: .music, state: .denied)
        XCTAssertTrue(try! XCTUnwrap(music).contains("Media & Apple Music"))
    }

    func testPermissionGuidanceIsSilentWhenAuthorized() {
        for source in VisibilitySource.allCases {
            XCTAssertNil(PermissionGuidance.text(source: source, state: .authorized))
        }
        // Sources with no system permission need no "not asked" text.
        XCTAssertNil(PermissionGuidance.text(source: .system, state: .notDetermined))
        XCTAssertNotNil(PermissionGuidance.text(source: .photos, state: .notDetermined))
    }

    // MARK: - Date display

    func testFullTimeDescription() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 23
        components.hour = 14; components.minute = 30
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try! XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        let text = DateDisplay.fullDescription(of: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(text.contains("Friday, October 23, 2026"))
        XCTAssertTrue(text.contains("2:30 PM"))
    }

    // MARK: - Tool runtime gating

    private actor EventBox {
        var events: [ToolEvent] = []
        func add(_ event: ToolEvent) { events.append(event) }
    }

    private func makeRuntime(
        enabled: Set<VisibilitySource>,
        permission: PermissionState = .authorized,
        redactResults: Bool = false,
        redactionTerms: [String] = [],
        box: EventBox
    ) -> ToolRuntime {
        ToolRuntime(
            configuration: ToolRuntime.Configuration(
                conversationID: UUID(),
                enabledSources: enabled,
                folderRootPaths: [],
                redactResults: redactResults,
                redactionTerms: redactionTerms),
            sink: { event in await box.add(event) },
            permissionProvider: { _ in permission })
    }

    func testRuntimeRunsUtilitiesAndLogsTheEvent() async {
        let box = EventBox()
        let runtime = makeRuntime(enabled: [.system], box: box)
        let result = await runtime.execute(
            toolName: "calculate", arguments: ToolArguments(expression: "2 + 2"))
        XCTAssertEqual(result, "4")
        let events = await box.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.toolName, "calculate")
        XCTAssertEqual(events.first?.resultSummary, "4")
    }

    func testRuntimeRefusesToolsFromDisabledSources() async {
        let box = EventBox()
        let runtime = makeRuntime(enabled: [.system], box: box)
        let result = await runtime.execute(
            toolName: "search_files", arguments: ToolArguments(query: "roof"))
        XCTAssertTrue(result.contains("turned off"))
        // Even a refused lookup is logged — the record is the point.
        let events = await box.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.toolName, "search_files")
    }

    func testRuntimeGatesOnPermission() async {
        let box = EventBox()
        let runtime = makeRuntime(enabled: [.calendar], permission: .denied, box: box)
        let result = await runtime.execute(
            toolName: "calendar_events", arguments: ToolArguments())
        XCTAssertTrue(result.contains("doesn't have permission"))
        XCTAssertTrue(result.contains("Calendars"))
    }

    func testRuntimePermissionNotDeterminedPointsAtAllowButton() async {
        // UAT-10: the source is ON (that's why the tool exists)
        // but macOS was never asked — the refusal must point at
        // the Settings Allow… button, not tell the user to "turn
        // this on" (it already is).
        let box = EventBox()
        let runtime = makeRuntime(enabled: [.calendar],
                                  permission: .notDetermined, box: box)
        let result = await runtime.execute(
            toolName: "calendar_events", arguments: ToolArguments())
        XCTAssertTrue(result.contains("doesn't have permission"))
        XCTAssertTrue(result.contains("Allow…"))
        XCTAssertTrue(result.contains("What this app can see"))
        XCTAssertFalse(result.contains("Turn this on"))
    }

    func testRuntimeUnknownToolIsADeadEndWithoutAnEvent() async {
        let box = EventBox()
        let runtime = makeRuntime(enabled: [.system], box: box)
        let result = await runtime.execute(toolName: "nope", arguments: ToolArguments())
        XCTAssertEqual(result, "That tool doesn't exist.")
        let events = await box.events
        XCTAssertTrue(events.isEmpty)
    }

    func testRuntimeFileToolsOutsideScopeSaySo() async {
        let box = EventBox()
        let runtime = makeRuntime(enabled: [.files], box: box)
        let result = await runtime.execute(
            toolName: "read_file", arguments: ToolArguments(path: "/etc/passwd"))
        XCTAssertTrue(result.contains("no folders are shared"))
    }

    func testRuntimeRedactionHookScrubsResults() async {
        // The Phase 8 hook, exercised now: with redaction on (a
        // remote tool host), a custom term in a result never comes
        // back out of the runtime.
        let box = EventBox()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("the Falcon budget is ready", forType: .string)
        let runtime = makeRuntime(
            enabled: [.clipboard], redactResults: true,
            redactionTerms: ["Falcon"], box: box)
        let result = await runtime.execute(toolName: "read_clipboard", arguments: ToolArguments())
        XCTAssertFalse(result.contains("Falcon"))
        XCTAssertTrue(result.contains("[redacted]"))
    }

    // MARK: - Access-log summaries keep content out (audit S-11)

    func testClipboardAndFileSummariesAreTypeOnly() {
        // The query summary for write_clipboard was the first 40
        // characters of the text being copied — verbatim content in
        // the persisted log. Now it's a type-and-size line.
        let secret = "hunter2-is-a-very-secret-password"
        let writeSummary = ToolArguments(text: secret)
            .summary(for: "write_clipboard")
        XCTAssertEqual(writeSummary,
                       "Clipboard text (\(secret.count) characters)")
        XCTAssertFalse(writeSummary.contains("hunter2"))

        // Result summaries for the content-bearing tools.
        let clipResult = ToolResultText.summary(
            of: secret, toolName: "read_clipboard")
        XCTAssertEqual(clipResult,
                       "Clipboard text (\(secret.count) characters)")
        XCTAssertFalse(clipResult.contains("hunter2"))

        let fileResult = ToolResultText.summary(
            of: "Dear diary, today I…", toolName: "read_file")
        XCTAssertTrue(fileResult.hasPrefix("File text ("))
        XCTAssertFalse(fileResult.contains("diary"))

        XCTAssertEqual(ToolResultText.summary(
            of: "Copied to the clipboard (7 characters) — ready to paste anywhere.",
            toolName: "write_clipboard"), "Text copied to the clipboard")

        // Other tools keep the first-line summary they always had.
        XCTAssertEqual(ToolResultText.summary(
            of: "first\nsecond", toolName: "search_files"), "first")
    }

    func testRuntimeLogsClipboardResultAsTypeOnly() async {
        // End to end through the runtime's event sink: the event
        // that reaches the access log must not carry the clipboard's
        // first line.
        let box = EventBox()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("a copied secret line", forType: .string)
        let runtime = makeRuntime(enabled: [.clipboard], box: box)
        _ = await runtime.execute(toolName: "read_clipboard",
                                  arguments: ToolArguments())
        let events = await box.events
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events.first?.resultSummary.contains("secret") ?? true)
        XCTAssertTrue(events.first?.resultSummary
            .hasPrefix("Clipboard text (") ?? false)
    }

    // MARK: - Plan-record retention (audit S-04)

    func testActionPlanLogRotationMath() {
        XCTAssertEqual(ActionPlanLogPolicy.maxRecords,
                       AccessLogPolicy.maxRecords)
        XCTAssertEqual(ActionPlanLogPolicy.excessCount(totalRecords: 0), 0)
        XCTAssertEqual(ActionPlanLogPolicy.excessCount(
            totalRecords: ActionPlanLogPolicy.maxRecords), 0)
        XCTAssertEqual(ActionPlanLogPolicy.excessCount(
            totalRecords: ActionPlanLogPolicy.maxRecords + 1), 1)
        XCTAssertEqual(ActionPlanLogPolicy.excessCount(totalRecords: 1000),
                       1000 - ActionPlanLogPolicy.maxRecords)
    }

    // MARK: - Local Only folds into availability (audit S-06)

    func testLocalOnlyRemovesPowerToolsFromAvailability() {
        let unlocked = ToolAvailability(
            enabledSources: [], folderRootPaths: [], powerToolsEnabled: true)
        let locked = ToolAvailability(
            enabledSources: [], folderRootPaths: [], powerToolsEnabled: true,
            localOnly: true)
        XCTAssertTrue(unlocked.hasTools)
        XCTAssertTrue(unlocked.effectivePowerToolsEnabled)
        // Under the lock the power tools simply don't exist…
        XCTAssertFalse(locked.effectivePowerToolsEnabled)
        XCTAssertFalse(locked.hasTools)
        // …and the signature changes, so live sessions retire.
        XCTAssertNotEqual(unlocked.signature, locked.signature)

        // Read tools are untouched by the lock.
        let lockedReader = ToolAvailability(
            enabledSources: [.files], folderRootPaths: ["/x"],
            powerToolsEnabled: true, localOnly: true)
        XCTAssertTrue(lockedReader.hasTools)
    }

    func testCatalogDropsPowerToolsUnderLocalOnly() {
        let descriptors = ToolCatalog.descriptors(
            enabledSources: [.files], powerToolsEnabled: true,
            localOnly: true)
        XCTAssertFalse(descriptors.contains { $0.name == "run_command" })
        XCTAssertTrue(descriptors.allSatisfy { !$0.isPowerAction })
        // The lock doesn't touch read tools.
        XCTAssertTrue(descriptors.contains { $0.name == "read_file" })
        // Power-only + lock = no tool set at all.
        XCTAssertTrue(ToolCatalog.descriptors(
            enabledSources: [], powerToolsEnabled: true,
            localOnly: true).isEmpty)
    }

    // MARK: - Redaction terms in the session signature (audit S-13)

    func testRedactionTermsHashIsDeterministicAndOrderFree() {
        XCTAssertEqual(RedactionTermsHash.value(for: ["Falcon", "Acme"]),
                       RedactionTermsHash.value(for: ["Acme", "Falcon"]))
        XCTAssertEqual(RedactionTermsHash.value(for: ["  Falcon "]),
                       RedactionTermsHash.value(for: ["Falcon"]))
        XCTAssertEqual(RedactionTermsHash.value(for: []),
                       RedactionTermsHash.value(for: ["", "   "]))
        XCTAssertNotEqual(RedactionTermsHash.value(for: ["Falcon"]),
                          RedactionTermsHash.value(for: ["Falcon", "Acme"]))
        XCTAssertNotEqual(RedactionTermsHash.value(for: ["Falcon"]),
                          RedactionTermsHash.value(for: ["falcon2"]))
    }

    func testAvailabilitySignatureChangesWhenTermsChange() {
        let before = ToolAvailability(
            enabledSources: [.calendar], folderRootPaths: [],
            customRedactionTerms: ["Falcon"])
        let after = ToolAvailability(
            enabledSources: [.calendar], folderRootPaths: [],
            customRedactionTerms: ["Falcon", "Acme"])
        XCTAssertNotEqual(before.signature, after.signature)
        XCTAssertEqual(before.signature, ToolAvailability(
            enabledSources: [.calendar], folderRootPaths: [],
            customRedactionTerms: ["Falcon"]).signature)
    }
}
