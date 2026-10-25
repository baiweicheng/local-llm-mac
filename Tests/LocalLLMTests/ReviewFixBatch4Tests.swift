import Foundation
import XCTest
@testable import LocalLLM

/// Repository-review fix pass, batch 4 (P2s: findings 14, 15, 16,
/// 18, 22, 21). Same ground rule as batch 3: there is no Swift
/// toolchain in this workspace, and the live layers (a real photo
/// library, a packaged app's Automation prompt, a second window)
/// are exercised on the Mac. What IS proven here is the logic that
/// caused each bug, at the seam each fix exposes — the identifier
/// a proposal carries, the prompt a continuation seeds from, the
/// engine a proposal sink is bound to, the outcome an undo step
/// reports, the prefix a truncated read decodes, and the error
/// number a Finder denial maps to — so a regression in any of them
/// fails a test instead of silently returning.
final class ReviewFixBatch4Tests: XCTestCase {

    // MARK: - Finding 14: photo proposals keep a stable identity

    private struct FakeProbe: FileSystemProbe {
        var existing: Set<String>
        var directories: Set<String>
        func exists(atPath path: String) -> Bool { existing.contains(path) }
        func isDirectory(atPath path: String) -> Bool { directories.contains(path) }
    }

    private let home = "/Users/tester"
    private let root = "/Users/tester/Shared"

    /// The review's scenario, at the proposal seam: the model asked
    /// for recent photo #2; by approval time a new import has
    /// shifted what #2 means. The proposal must carry the asset
    /// captured at proposal time — and NOT the index — so the shift
    /// cannot retarget the resize.
    func testLibraryResizeProposalCarriesIdentifierNotIndex() {
        let probe = FakeProbe(existing: [root], directories: [root])
        let outcome = ActionProposal.make(
            kind: .resizePhoto,
            inputs: ActionInputs(
                sourcePhotoIndex: 2,
                libraryPhotoName: "IMG_0001.jpg",
                sourcePhotoIdentifier: "asset-AAA"),
            roots: [root], probe: probe, home: home)
        guard case .proposed(let action) = outcome else {
            return XCTFail("expected a proposal, got \(outcome)")
        }
        XCTAssertEqual(action.sourcePhotoIdentifier, "asset-AAA")
        XCTAssertNil(action.sourcePhotoIndex,
                     "an identifier-carrying proposal must not also "
                     + "carry the index it replaces")
        XCTAssertEqual(action.destinationPath,
                       "\(root)/IMG_0001-resized.jpg")
    }

    /// Same index, different assets: not duplicates. Same asset,
    /// same caps: a duplicate. The index-shift scenario must not
    /// collapse two different photos into one approval item, nor
    /// let a re-proposal of the same photo stack twice.
    func testPhotoIdentifierDistinguishesApprovalDuplicates() {
        let probe = FakeProbe(existing: [root], directories: [root])
        func propose(identifier: String) -> PlannedAction {
            let outcome = ActionProposal.make(
                kind: .resizePhoto,
                inputs: ActionInputs(
                    sourcePhotoIndex: 2,
                    libraryPhotoName: "IMG_0001.jpg",
                    sourcePhotoIdentifier: identifier),
                roots: [root], probe: probe, home: home)
            guard case .proposed(let action) = outcome else {
                fatalError("setup: expected a proposal")
            }
            return action
        }
        let first = propose(identifier: "asset-AAA")
        XCTAssertTrue(ActionPlanRules.isDuplicate(
            propose(identifier: "asset-AAA"), in: [first]))
        XCTAssertFalse(ActionPlanRules.isDuplicate(
            propose(identifier: "asset-BBB"), in: [first]))
    }

    /// The identifier survives the persisted record's JSON round
    /// trip — a plan decided in one launch and undone in another
    /// still names the same asset (the executor's identifier
    /// branch, not the legacy index branch, is what runs).
    func testPhotoIdentifierRoundTripsThroughCoding() {
        let action = PlannedAction(
            kind: .resizePhoto, sourcePhotoIdentifier: "asset-AAA",
            destinationPath: "\(root)/IMG_0001-resized.jpg",
            summary: "Resize IMG_0001.jpg")
        let item = ExecutedActionItem(action: action, outcome: .done,
                                      resultNote: "done")
        let decoded = ActionPlanCoding.decodeItems(
            ActionPlanCoding.encodeItems([item]))
        XCTAssertEqual(decoded, [item])
        XCTAssertEqual(decoded.first?.action.sourcePhotoIdentifier,
                       "asset-AAA")
    }

    // MARK: - Finding 15: Compare continues with the question asked

    /// The review's scenario: asked A, edited the field to B
    /// without rerunning, pressed "Continue with this one". The
    /// seeded chat must pair the answer to A with A — not with B.
    /// The submitted model rides along too: a picker moved after
    /// the run must not reassign the answer to another model.
    @MainActor
    func testContinueSeedsSubmittedPromptNotEditedField() {
        let column = CompareColumn(selection: .onDevice)
        column.submittedPrompt = "Why is the sky blue?"
        column.submittedSelection = .privateCloudCompute
        let seed = column.continuationSeed(
            currentPrompt: "Why is the sea salty?",
            answer: "Because of Rayleigh scattering.")
        XCTAssertEqual(seed.userText, "Why is the sky blue?")
        XCTAssertEqual(seed.assistantText,
                       "Because of Rayleigh scattering.")
        XCTAssertEqual(seed.selection, .privateCloudCompute)
        XCTAssertEqual(seed.title, "Why is the sky blue?")
    }

    /// No run yet: the seed falls back to the live field and the
    /// column's effective selection, as before (the view's
    /// `canContinue` gate excludes this state for the button, but
    /// the fallback must still be sane).
    @MainActor
    func testContinueFallsBackToCurrentPromptWithoutRun() {
        let column = CompareColumn(selection: .onDevice)
        let seed = column.continuationSeed(
            currentPrompt: "A fresh question", answer: "An answer")
        XCTAssertEqual(seed.userText, "A fresh question")
        XCTAssertEqual(seed.selection, .onDevice)
    }

    // MARK: - Finding 16: each window's proposals stay in its window

    /// Two engines, two sinks: a proposal sent through engine A's
    /// sink lands ONLY in A's pending list, and vice versa. Under
    /// the old static `proposalTarget`, the second engine's init
    /// overwrote the destination, so A's proposal would have
    /// appeared in B's window instead.
    @MainActor
    func testTwoEnginesProposalSinksStayDistinct() async {
        let engineA = ChatEngine()
        let engineB = ChatEngine()
        let conversation = UUID()
        let action = PlannedAction(
            kind: .createFolder,
            destinationPath: "\(root)/NewFolder",
            summary: "Create NewFolder")
        let deliveredA = await engineA.proposalSink()(
            conversation, action)
        XCTAssertTrue(deliveredA)
        XCTAssertEqual(engineA.pendingPlans[conversation], [action])
        XCTAssertNil(engineB.pendingPlans[conversation])

        let other = PlannedAction(
            kind: .createFolder,
            destinationPath: "\(root)/OtherFolder",
            summary: "Create OtherFolder")
        let deliveredB = await engineB.proposalSink()(
            conversation, other)
        XCTAssertTrue(deliveredB)
        XCTAssertEqual(engineB.pendingPlans[conversation], [other])
        XCTAssertEqual(engineA.pendingPlans[conversation], [action])
    }

    // MARK: - Finding 18: failed undo stays retryable

    /// The completion rule itself: non-reversible steps never
    /// block "fully undone"; any failed reversible step does.
    func testUndoCompletionRequiresNoFailedReversibleStep() {
        XCTAssertTrue(UndoCompletion.isFullyUndone(outcomes: []))
        XCTAssertTrue(UndoCompletion.isFullyUndone(
            outcomes: [.succeeded, .notReversible]))
        XCTAssertFalse(UndoCompletion.isFullyUndone(
            outcomes: [.succeeded, .failed]))
        XCTAssertFalse(UndoCompletion.isFullyUndone(
            outcomes: [.failed]))
    }

    /// A retry steps only outstanding work: an item already
    /// reversed is skipped, so its move-back is not attempted a
    /// second time (where it would fail — the item is no longer
    /// where the change left it) and cannot mask the item that
    /// still needs undoing.
    func testUndoStepsSkipAlreadyReversedItems() {
        func renamed(_ name: String) -> ExecutedActionItem {
            ExecutedActionItem(
                action: PlannedAction(
                    kind: .rename, sourcePath: "\(root)/\(name)-old",
                    destinationPath: "\(root)/\(name)-new",
                    summary: "Rename \(name)"),
                outcome: .done, resultNote: "done")
        }
        var done = renamed("a")
        done.undoSucceeded = true
        let pending = renamed("b")
        let steps = ActionUndo.steps(for: [done, pending], home: home)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.itemID, pending.action.id)
        // …and the plan is still offered undo while work remains.
        XCTAssertTrue(ActionUndo.hasUndoableSteps(
            for: [done, pending]))
        XCTAssertFalse(ActionUndo.hasUndoableSteps(for: [done]))
    }

    /// The structured outcomes at the executor seam, without
    /// touching real user files: a scope-revoked step fails, a
    /// never-reversible step reports exactly that, and a missing
    /// file fails — none of them masquerades as success.
    func testUndoStepResultClassifiesOutcomes() {
        let refused = FileActionService.executeUndoStepResult(
            UndoStep(itemID: UUID(),
                     kind: .moveBack(from: "/elsewhere/moved.txt",
                                     to: "\(root)/orig.txt"),
                     description: "Move back"),
            roots: [root])
        XCTAssertEqual(refused.outcome, .failed)

        let never = FileActionService.executeUndoStepResult(
            UndoStep(itemID: UUID(),
                     kind: .notUndoable(
                        reason: "a command that has run can't be un-run"),
                     description: "Can't undo"),
            roots: [root])
        XCTAssertEqual(never.outcome, .notReversible)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewFixBatch4-\(UUID().uuidString)")
        let resolved = FileAccessService.resolvedPath(base.path) ?? base.path
        defer { try? FileManager.default.removeItem(atPath: resolved) }
        try? FileManager.default.createDirectory(
            atPath: resolved, withIntermediateDirectories: true)
        let missing = FileActionService.executeUndoStepResult(
            UndoStep(itemID: UUID(),
                     kind: .trashFile(path: "\(resolved)/gone.txt"),
                     description: "Trash the created file"),
            roots: [resolved])
        XCTAssertEqual(missing.outcome, .failed)
    }

    /// A create-folder undo whose folder gained contents since
    /// creation is a FAILED reversible step — not "done": the user
    /// can empty the folder and retry, and the plan must stay
    /// undoable until then.
    func testNonEmptyFolderUndoIsAFailedReversibleStep() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewFixBatch4-\(UUID().uuidString)")
        let resolved = FileAccessService.resolvedPath(base.path) ?? base.path
        defer { try? FileManager.default.removeItem(atPath: resolved) }
        try? FileManager.default.createDirectory(
            atPath: resolved, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: "\(resolved)/something.txt", contents: Data())
        let result = FileActionService.executeUndoStepResult(
            UndoStep(itemID: UUID(),
                     kind: .removeFolderIfEmpty(path: resolved),
                     description: "Remove the folder"),
            roots: [resolved])
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.note.contains("isn't empty"))
    }

    // MARK: - Finding 22: UTF-8 text cut at the read boundary

    /// The review's exact scenario: 23,999 ASCII chars + € + more
    /// text, read through the 24,000-byte cutoff. The first byte
    /// of € lands at the boundary; the prefix must still read as
    /// text (the dangling byte trimmed), not as "not text".
    func testDecodeTrimsIncompleteTrailingSequenceAtCutoff() {
        var bytes = Data(repeating: 0x61, count: 23_999)
        bytes.append(contentsOf: "€ and more text".utf8)
        let prefix = bytes.prefix(24_000)
        XCTAssertEqual(prefix.count, 24_000)
        let text = FileAccessService.decodeTextPrefix(
            Data(prefix), isTruncated: true)
        XCTAssertEqual(text, String(repeating: "a", count: 23_999))
    }

    /// A two-byte cut of the same character trims two bytes, and
    /// genuinely invalid content is still rejected — including a
    /// dangling sequence at the end of a COMPLETE file (there the
    /// cut is not a boundary artifact, it is invalid content).
    func testDecodeStillRejectsInvalidContent() {
        var bytes = Data("hello ".utf8)
        bytes.append(contentsOf: [0xE2, 0x82]) // € cut after 2 bytes
        XCTAssertEqual(
            FileAccessService.decodeTextPrefix(bytes, isTruncated: true),
            "hello ")

        let binary = Data([0x61, 0x62, 0xFF, 0x63])
        XCTAssertNil(FileAccessService.decodeTextPrefix(
            binary, isTruncated: true))
        XCTAssertNil(FileAccessService.decodeTextPrefix(
            binary, isTruncated: false))

        var wholeFile = Data(repeating: 0x61, count: 100)
        wholeFile.append(0xE2) // dangling lead byte, file complete
        XCTAssertNil(FileAccessService.decodeTextPrefix(
            wholeFile, isTruncated: false))
    }

    // MARK: - Finding 21: Finder automation denial surfaces distinctly

    /// The capture seam: macOS's Automation-denied error number
    /// maps to `.denied`; anything else (including no number at
    /// all) maps to plain `.unavailable` — never to a silent
    /// "nothing selected".
    func testAutomationDeniedErrorNumberMapsToDenied() {
        XCTAssertEqual(
            HUDContextCapture.outcomeForErrorNumber(-1743), .denied)
        XCTAssertEqual(
            HUDContextCapture.outcomeForErrorNumber(nil), .unavailable)
        XCTAssertEqual(
            HUDContextCapture.outcomeForErrorNumber(-1708), .unavailable)
    }

    /// The panel surface: a denied snapshot renders a denial chip
    /// (so the user learns WHY there is no Finder chip), while an
    /// ordinary empty selection renders no such chip.
    func testDeniedSnapshotShowsDeniedChip() {
        var denied = HUDContextSnapshot.empty
        denied.finderAutomationDenied = true
        let chips = denied.chips
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.text, "Finder access denied")
        XCTAssertTrue(chips.first?.helpText.contains("Automation")
                      ?? false)

        XCTAssertFalse(HUDContextSnapshot.empty.chips.contains {
            $0.text == "Finder access denied"
        })
    }
}
