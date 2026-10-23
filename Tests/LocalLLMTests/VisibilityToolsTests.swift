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
}
