import XCTest
@testable import LocalLLM

/// Phase 6 tests: the file-action layer's pure logic — argument
/// shaping for the write tools, catalog gating behind the separate
/// writing toggle, proposal validation (the security boundary: scope
/// on both ends, never-overwrite, the folder rules), the execution
/// pre-check, undo-plan construction, the JPEG ladder math, dedupe,
/// record coding, and the runtime's propose path end to end against
/// a real temporary folder (proving a proposal changes NOTHING on
/// disk). The FileManager/ImageIO execution wrapper itself is thin
/// and is exercised on the Mac.
final class FileActionsTests: XCTestCase {

    // MARK: - Fake disk

    /// In-memory `FileSystemProbe`: a set of existing paths, some of
    /// them directories.
    private struct FakeProbe: FileSystemProbe {
        var existing: Set<String>
        var directories: Set<String>
        func exists(atPath path: String) -> Bool { existing.contains(path) }
        func isDirectory(atPath path: String) -> Bool { directories.contains(path) }
    }

    private let home = "/Users/tester"
    private let root = "/Users/tester/Shared"

    /// A shared folder containing one file and one subfolder.
    private func standardProbe() -> FakeProbe {
        FakeProbe(
            existing: [root, "\(root)/photo.jpg", "\(root)/notes.txt",
                       "\(root)/Sub", "\(root)/taken.txt"],
            directories: [root, "\(root)/Sub"])
    }

    private func propose(_ kind: PlannedActionKind,
                         _ inputs: ActionInputs,
                         probe: FileSystemProbe,
                         roots: [String]? = nil) -> ProposalOutcome {
        ActionProposal.make(kind: kind, inputs: inputs,
                            roots: roots ?? [root], probe: probe,
                            home: home)
    }

    // MARK: - Argument shaping

    func testWriteArgumentsDecodeFromValues() {
        let arguments = ToolArguments(values: [
            "newName": .string("beach.jpg"),
            "destination": .string("/Users/tester/Shared/beach.jpg"),
            "append": .string("yes"),
            "maxWidth": .string("800"),
            "maxBytes": .int(200_000),
        ])
        XCTAssertEqual(arguments.newName, "beach.jpg")
        XCTAssertEqual(arguments.destination, "/Users/tester/Shared/beach.jpg")
        XCTAssertEqual(arguments.append, true)
        XCTAssertEqual(arguments.maxWidth, 800)
        XCTAssertEqual(arguments.maxBytes, 200_000)
    }

    func testAppendDecodesLooseBoolForms() {
        XCTAssertEqual(ToolArguments(values: ["append": .bool(false)]).append, false)
        XCTAssertEqual(ToolArguments(values: ["append": .int(0)]).append, false)
        XCTAssertEqual(ToolArguments(values: ["append": .int(3)]).append, true)
        XCTAssertNil(ToolArguments(values: ["append": .string("maybe")]).append)
    }

    func testResizeClampsHaveDefaultsAndBounds() {
        let plain = ToolArguments()
        XCTAssertEqual(plain.maxWidthClamped, 1200)
        XCTAssertEqual(plain.maxBytesClamped, 512_000)
        XCTAssertEqual(ToolArguments(maxWidth: 4).maxWidthClamped, 16)
        XCTAssertEqual(ToolArguments(maxWidth: 99_999).maxWidthClamped, 8192)
        XCTAssertEqual(ToolArguments(maxBytes: 5).maxBytesClamped, 10_000)
        XCTAssertEqual(ToolArguments(maxBytes: Int.max).maxBytesClamped, 20_000_000)
        XCTAssertFalse(ToolArguments().appendFlag)
        XCTAssertTrue(ToolArguments(append: true).appendFlag)
    }

    func testWriteToolSummaries() {
        let rename = ToolArguments(path: "/a/b.jpg", newName: "c.jpg")
        XCTAssertEqual(rename.summary(for: "rename_file"), "/a/b.jpg → c.jpg")
        let resize = ToolArguments(index: 2)
        XCTAssertEqual(resize.summary(for: "resize_photo"),
                       "photo #3 from most recent")
    }

    // MARK: - Catalog gating

    func testWriteToolsHiddenUnlessWritingEnabled() {
        let readOnly = ToolCatalog.descriptors(enabledSources: [.files, .photos])
        XCTAssertTrue(readOnly.allSatisfy { !$0.isWriteAction })
        // list_folder, read_file, recent_photos, photo_text + the 2
        // source-less utilities (calculate, current_time).
        XCTAssertEqual(readOnly.count, 6)

        let writing = ToolCatalog.descriptors(
            enabledSources: [.files, .photos], fileWritingEnabled: true)
        XCTAssertEqual(writing.filter { $0.isWriteAction }.count, 7)
    }

    func testWriteToolsStillNeedTheirSource() {
        let filesOnly = ToolCatalog.descriptors(
            enabledSources: [.files], fileWritingEnabled: true)
        XCTAssertTrue(filesOnly.contains { $0.name == "rename_file" })
        XCTAssertFalse(filesOnly.contains { $0.name == "resize_photo" })

        let photosOnly = ToolCatalog.descriptors(
            enabledSources: [.photos], fileWritingEnabled: true)
        XCTAssertTrue(photosOnly.contains { $0.name == "resize_photo" })
        XCTAssertFalse(photosOnly.contains { $0.name == "rename_file" })
    }

    func testWritingToggleChangesSessionSignature() {
        let off = ToolAvailability(enabledSources: [.files], folderRootPaths: [])
        let on = ToolAvailability(enabledSources: [.files], folderRootPaths: [],
                                  fileWritingEnabled: true)
        XCTAssertNotEqual(off.signature, on.signature)
        XCTAssertTrue(off.hasTools)
    }

    func testKindToolNameRoundTrip() {
        for kind in PlannedActionKind.allCases {
            XCTAssertEqual(PlannedActionKind(toolName: kind.toolName), kind)
        }
        XCTAssertNil(PlannedActionKind(toolName: "read_file"))
    }

    // MARK: - Proposal validation: rename

    func testRenameProposalHappyPath() {
        let outcome = propose(.rename, ActionInputs(
            sourcePath: "\(root)/photo.jpg", newName: "beach.jpg"),
            probe: standardProbe())
        guard case .proposed(let action) = outcome else {
            return XCTFail("expected a proposal, got \(outcome)")
        }
        XCTAssertEqual(action.kind, .rename)
        XCTAssertEqual(action.destinationPath, "\(root)/beach.jpg")
        XCTAssertTrue(action.summary.contains("photo.jpg"))
        XCTAssertTrue(action.summary.contains("beach.jpg"))
    }

    func testRenameRefusesBadNames() {
        for bad in ["", "  ", "a/b.jpg", ".", ".."] {
            let outcome = propose(.rename, ActionInputs(
                sourcePath: "\(root)/photo.jpg", newName: bad),
                probe: standardProbe())
            guard case .refused = outcome else {
                return XCTFail("name \(bad.debugDescription) should be refused")
            }
        }
    }

    func testRenameRefusesExistingDestination() {
        let outcome = propose(.rename, ActionInputs(
            sourcePath: "\(root)/photo.jpg", newName: "taken.txt"),
            probe: standardProbe())
        guard case .refused(let reason) = outcome else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(reason.contains("already"))
    }

    func testProposalsRefusePathsOutsideScope() {
        let outside = propose(.rename, ActionInputs(
            sourcePath: "/Users/tester/Private/secret.txt", newName: "x.txt"),
            probe: standardProbe())
        guard case .refused(let reason) = outside else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(reason.contains("shared"))

        // The sibling-prefix trap: SharedEvil is not Shared.
        let sibling = propose(.trash, ActionInputs(
            sourcePath: "/Users/tester/SharedEvil/file.txt"),
            probe: FakeProbe(existing: ["/Users/tester/SharedEvil/file.txt"],
                             directories: []))
        guard case .refused = sibling else {
            return XCTFail("sibling prefix must not pass the scope check")
        }
    }

    func testProposalsRefuseMissingSource() {
        let outcome = propose(.trash, ActionInputs(
            sourcePath: "\(root)/ghost.txt"), probe: standardProbe())
        guard case .refused(let reason) = outcome else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(reason.contains("nothing at"))
    }

    // MARK: - Proposal validation: move / copy / folders

    func testMoveProposalAndFolderIntoItselfRefusal() {
        let ok = propose(.move, ActionInputs(
            sourcePath: "\(root)/photo.jpg",
            destinationPath: "\(root)/Sub/photo.jpg"), probe: standardProbe())
        guard case .proposed = ok else { return XCTFail("expected proposal") }

        let intoItself = propose(.move, ActionInputs(
            sourcePath: root, destinationPath: "\(root)/Sub/Moved"),
            probe: standardProbe())
        guard case .refused(let reason) = intoItself else {
            return XCTFail("moving a folder into itself must be refused")
        }
        XCTAssertTrue(reason.contains("into itself"))
    }

    func testMoveRefusesMissingDestinationParent() {
        let outcome = propose(.move, ActionInputs(
            sourcePath: "\(root)/photo.jpg",
            destinationPath: "\(root)/NoSuchFolder/photo.jpg"),
            probe: standardProbe())
        guard case .refused = outcome else {
            return XCTFail("expected refusal")
        }
    }

    func testCopyFolderAllowedButNotIntoItself() {
        // Folders can be copied (FileManager copies them whole) —
        // but never into themselves.
        let ok = propose(.copy, ActionInputs(
            sourcePath: "\(root)/Sub",
            destinationPath: "\(root)/SubCopy"), probe: standardProbe())
        guard case .proposed = ok else {
            return XCTFail("copying a folder should be proposable")
        }
        let intoItself = propose(.copy, ActionInputs(
            sourcePath: "\(root)/Sub",
            destinationPath: "\(root)/Sub/InnerCopy"), probe: standardProbe())
        guard case .refused(let reason) = intoItself else {
            return XCTFail("copying a folder into itself must be refused")
        }
        XCTAssertTrue(reason.contains("into itself"))
    }

    func testCreateFolderProposal() {
        let ok = propose(.createFolder, ActionInputs(
            sourcePath: "\(root)/Trips"), probe: standardProbe())
        guard case .proposed(let action) = ok else {
            return XCTFail("expected proposal")
        }
        XCTAssertNil(action.sourcePath)
        XCTAssertEqual(action.destinationPath, "\(root)/Trips")

        let exists = propose(.createFolder, ActionInputs(
            sourcePath: "\(root)/Sub"), probe: standardProbe())
        guard case .refused = exists else {
            return XCTFail("an existing folder must be refused")
        }
    }

    func testTrashRefusesTheSharedFolderItself() {
        let outcome = propose(.trash, ActionInputs(sourcePath: root),
                              probe: standardProbe())
        guard case .refused(let reason) = outcome else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(reason.contains("itself"))
    }

    // MARK: - Proposal validation: edit text

    func testEditTextCreateAndReplace() {
        let create = propose(.editText, ActionInputs(
            sourcePath: "\(root)/new.txt", editText: "hello"),
            probe: standardProbe())
        guard case .proposed(let createAction) = create else {
            return XCTFail("expected a create proposal")
        }
        XCTAssertTrue(createAction.summary.contains("Create"))
        XCTAssertEqual(createAction.destinationPath, "\(root)/new.txt")
        XCTAssertEqual(createAction.editText, "hello")

        let replace = propose(.editText, ActionInputs(
            sourcePath: "\(root)/notes.txt", editText: "fresh",
            appendEdit: false), probe: standardProbe())
        guard case .proposed(let replaceAction) = replace else {
            return XCTFail("expected a replace proposal")
        }
        XCTAssertTrue(replaceAction.summary.contains("Replace"))

        let append = propose(.editText, ActionInputs(
            sourcePath: "\(root)/notes.txt", editText: "more",
            appendEdit: true), probe: standardProbe())
        guard case .proposed(let appendAction) = append else {
            return XCTFail("expected an append proposal")
        }
        XCTAssertTrue(appendAction.summary.contains("Append"))
        XCTAssertTrue(appendAction.appendEdit)
    }

    func testEditTextRefusals() {
        // No text at all: refuse. (Whitespace-only text is the
        // model's choice to propose — the user sees it on the card
        // and approves or not, like any other contents.)
        let noText = propose(.editText, ActionInputs(
            sourcePath: "\(root)/notes.txt"), probe: standardProbe())
        guard case .refused = noText else {
            return XCTFail("missing text must be refused")
        }
        let outside = propose(.editText, ActionInputs(
            sourcePath: "/etc/notes.txt", editText: "x"),
            probe: standardProbe())
        guard case .refused = outside else {
            return XCTFail("outside scope must be refused")
        }
        let overFolder = propose(.editText, ActionInputs(
            sourcePath: "\(root)/Sub", editText: "x"),
            probe: standardProbe())
        guard case .refused = overFolder else {
            return XCTFail("writing text over a folder must be refused")
        }
    }

    // MARK: - Proposal validation: resize photo

    func testResizeFileSourceDerivesDestination() {
        let outcome = propose(.resizePhoto, ActionInputs(
            sourcePath: "\(root)/photo.jpg", maxWidthPx: 800,
            byteCeiling: 200_000), probe: standardProbe())
        guard case .proposed(let action) = outcome else {
            return XCTFail("expected proposal, got \(outcome)")
        }
        XCTAssertEqual(action.destinationPath, "\(root)/photo-resized.jpg")
        XCTAssertEqual(action.maxWidthPx, 800)
        XCTAssertEqual(action.byteCeiling, 200_000)
    }

    func testResizeExplicitDestinationMustBeInScope() {
        let outcome = propose(.resizePhoto, ActionInputs(
            sourcePath: "\(root)/photo.jpg",
            destinationPath: "/Users/tester/Elsewhere/out.jpg"),
            probe: standardProbe())
        guard case .refused = outcome else {
            return XCTFail("expected refusal")
        }
    }

    func testResizeLibrarySourceUsesFirstRoot() {
        let outcome = propose(.resizePhoto, ActionInputs(
            sourcePhotoIndex: 0, libraryPhotoName: "IMG_2049.HEIC"),
            probe: standardProbe())
        guard case .proposed(let action) = outcome else {
            return XCTFail("expected proposal, got \(outcome)")
        }
        XCTAssertNil(action.sourcePath)
        XCTAssertEqual(action.destinationPath, "\(root)/IMG_2049-resized.jpg")
    }

    func testResizeLibrarySourceWithoutFoldersRefused() {
        let outcome = propose(.resizePhoto, ActionInputs(
            sourcePhotoIndex: 0, libraryPhotoName: "IMG_1.jpg"),
            probe: standardProbe(), roots: [])
        guard case .refused(let reason) = outcome else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(reason.contains("no folders are shared"))
    }

    func testResizeExistingDestinationRefused() {
        var probe = standardProbe()
        probe.existing.insert("\(root)/photo-resized.jpg")
        let outcome = propose(.resizePhoto, ActionInputs(
            sourcePath: "\(root)/photo.jpg"), probe: probe)
        guard case .refused = outcome else {
            return XCTFail("never-overwrite applies to resizes too")
        }
    }

    // MARK: - Execution pre-check

    func testPreCheckCatchesChangesSinceProposal() {
        guard case .proposed(let action) = propose(.rename, ActionInputs(
            sourcePath: "\(root)/photo.jpg", newName: "beach.jpg"),
            probe: standardProbe()) else { return XCTFail("setup") }

        // Nothing changed: the pre-check passes (nil refusal).
        XCTAssertNil(ActionExecution.preCheck(
            action, roots: [root], probe: standardProbe()))

        // The source vanished.
        var vanished = standardProbe()
        vanished.existing.remove("\(root)/photo.jpg")
        XCTAssertNotNil(ActionExecution.preCheck(
            action, roots: [root], probe: vanished))

        // Something appeared at the destination.
        var occupied = standardProbe()
        occupied.existing.insert("\(root)/beach.jpg")
        let refusal = ActionExecution.preCheck(
            action, roots: [root], probe: occupied)
        XCTAssertTrue(refusal?.contains("already at the destination") ?? false)
    }

    // MARK: - Execution-time resolution (audit S-02)

    /// A resolver simulating a symlink swap: after the proposal,
    /// `Shared/Sub` was replaced by a link to `/Outside`.
    private func swappedResolver(_ path: String) -> String? {
        path.replacingOccurrences(of: "\(root)/Sub", with: "/Outside")
    }

    private func swappedDestinationResolver(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let resolvedParent = swappedResolver(parent) ?? parent
        return (resolvedParent as NSString).appendingPathComponent(name)
    }

    func testPreCheckRefusesASourceSwappedOutsideScope() {
        guard case .proposed(let action) = propose(.trash, ActionInputs(
            sourcePath: "\(root)/Sub"), probe: standardProbe())
        else { return XCTFail("setup") }
        // Sanity: without the swap, the pre-check passes.
        XCTAssertNil(ActionExecution.preCheck(
            action, roots: [root], probe: standardProbe()))
        // With `Sub` now a symlink to /Outside, the stored string
        // still reads as in-scope — only re-resolution catches it.
        let refusal = ActionExecution.preCheck(
            action, roots: [root], probe: standardProbe(),
            resolve: swappedResolver)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("no longer inside") ?? false)
    }

    func testPreCheckRefusesADestinationParentSwappedOutsideScope() {
        guard case .proposed(let action) = propose(.move, ActionInputs(
            sourcePath: "\(root)/photo.jpg",
            destinationPath: "\(root)/Sub/photo.jpg"),
            probe: standardProbe()) else { return XCTFail("setup") }
        let refusal = ActionExecution.preCheck(
            action, roots: [root], probe: standardProbe(),
            resolve: swappedResolver,
            resolveDestination: swappedDestinationResolver)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("destination") ?? false)
    }

    func testPreCheckRefusesACommandFolderSwappedOutsideScope() {
        guard case .proposed(let action) = propose(.editText, ActionInputs(
            sourcePath: "\(root)/Sub/notes.txt", editText: "x"),
            probe: standardProbe()) else { return XCTFail("setup") }
        // editText's target is a destination: its parent is what
        // gets resolved.
        let refusal = ActionExecution.preCheck(
            action, roots: [root], probe: standardProbe(),
            resolve: swappedResolver,
            resolveDestination: swappedDestinationResolver)
        XCTAssertNotNil(refusal)
    }

    func testResolvingPathsRewritesAnActionCopy() {
        guard case .proposed(let action) = propose(.move, ActionInputs(
            sourcePath: "\(root)/photo.jpg",
            destinationPath: "\(root)/Sub/photo.jpg"),
            probe: standardProbe()) else { return XCTFail("setup") }
        let resolved = action.resolvingPaths(
            sourceResolver: swappedResolver,
            destinationResolver: swappedDestinationResolver)
        XCTAssertEqual(resolved.sourcePath, "\(root)/photo.jpg")
        XCTAssertEqual(resolved.destinationPath, "/Outside/photo.jpg")
        // The original is untouched (it's a copy).
        XCTAssertEqual(action.destinationPath, "\(root)/Sub/photo.jpg")
    }

    func testUndoScopeRules() {
        let identity: (String) -> String? = { $0 }
        let rename = UndoStep(
            itemID: UUID(),
            kind: .moveBack(from: "\(root)/beach.jpg", to: "\(root)/photo.jpg"),
            description: "Rename back")
        XCTAssertTrue(UndoStepScope.isAllowed(
            rename, roots: [root], home: home, resolve: identity))

        // The place it returns to is no longer shared.
        XCTAssertFalse(UndoStepScope.isAllowed(
            rename, roots: [], home: home, resolve: identity))

        // A trashed item's undo legitimately starts in the Trash…
        let fromTrash = UndoStep(
            itemID: UUID(),
            kind: .moveBack(from: "\(home)/.Trash/taken.txt",
                            to: "\(root)/taken.txt"),
            description: "Back from Trash")
        XCTAssertTrue(UndoStepScope.isAllowed(
            fromTrash, roots: [root], home: home, resolve: identity))
        // …but may only land back inside a shared folder.
        let trashToOutside = UndoStep(
            itemID: UUID(),
            kind: .moveBack(from: "\(home)/.Trash/taken.txt",
                            to: "/Outside/taken.txt"),
            description: "Bad landing")
        XCTAssertFalse(UndoStepScope.isAllowed(
            trashToOutside, roots: [root], home: home, resolve: identity))

        // A move-back whose source was swapped out of scope (and
        // isn't the Trash) is refused.
        let swapped = UndoStep(
            itemID: UUID(),
            kind: .moveBack(from: "\(root)/Sub/beach.jpg",
                            to: "\(root)/photo.jpg"),
            description: "Swapped source")
        XCTAssertFalse(UndoStepScope.isAllowed(
            swapped, roots: [root], home: home, resolve: swappedResolver))

        // trashFile / removeFolderIfEmpty act inside scope only.
        XCTAssertTrue(UndoStepScope.isAllowed(
            UndoStep(itemID: UUID(),
                     kind: .trashFile(path: "\(root)/copy.txt"),
                     description: "Trash the copy"),
            roots: [root], home: home, resolve: identity))
        XCTAssertFalse(UndoStepScope.isAllowed(
            UndoStep(itemID: UUID(),
                     kind: .removeFolderIfEmpty(path: "/Outside/Folder"),
                     description: "Remove folder"),
            roots: [root], home: home, resolve: identity))

        // restoreBackup: the target must be in scope and the backup
        // must be the app's own backup copy.
        let backup = "/Users/tester/Library/Application Support/LocalLLM/ActionBackups/plan/item"
        XCTAssertTrue(UndoStepScope.isAllowed(
            UndoStep(itemID: UUID(),
                     kind: .restoreBackup(backupPath: backup,
                                          targetPath: "\(root)/notes.txt"),
                     description: "Restore"),
            roots: [root], home: home, resolve: identity))
        XCTAssertFalse(UndoStepScope.isAllowed(
            UndoStep(itemID: UUID(),
                     kind: .restoreBackup(backupPath: "/Outside/evil",
                                          targetPath: "\(root)/notes.txt"),
                     description: "Restore"),
            roots: [root], home: home, resolve: identity))
        XCTAssertFalse(UndoStepScope.isAllowed(
            UndoStep(itemID: UUID(),
                     kind: .restoreBackup(backupPath: backup,
                                          targetPath: "/Outside/notes.txt"),
                     description: "Restore"),
            roots: [root], home: home, resolve: identity))

        // notUndoable runs nothing, so nothing is checked.
        XCTAssertTrue(UndoStepScope.isAllowed(
            UndoStep(itemID: UUID(),
                     kind: .notUndoable(reason: "nope"),
                     description: "Can't"),
            roots: [], home: home, resolve: identity))
    }

    // MARK: - Dedupe

    func testDuplicateDetection() {
        guard case .proposed(let rename) = propose(.rename, ActionInputs(
            sourcePath: "\(root)/photo.jpg", newName: "beach.jpg"),
            probe: standardProbe()) else { return XCTFail("setup") }
        XCTAssertTrue(ActionPlanRules.isDuplicate(rename, in: [rename]))

        guard case .proposed(let other) = propose(.rename, ActionInputs(
            sourcePath: "\(root)/photo.jpg", newName: "other.jpg"),
            probe: standardProbe()) else { return XCTFail("setup") }
        XCTAssertFalse(ActionPlanRules.isDuplicate(other, in: [rename]))

        guard case .proposed(let editA) = propose(.editText, ActionInputs(
            sourcePath: "\(root)/notes.txt", editText: "one"),
            probe: standardProbe()),
              case .proposed(let editB) = propose(.editText, ActionInputs(
            sourcePath: "\(root)/notes.txt", editText: "two"),
            probe: standardProbe()) else { return XCTFail("setup") }
        XCTAssertFalse(ActionPlanRules.isDuplicate(editB, in: [editA]))
        XCTAssertTrue(ActionPlanRules.isDuplicate(editA, in: [editA]))
    }

    // MARK: - Undo plan construction

    private func executed(_ action: PlannedAction,
                          outcome: ExecutedActionItem.Outcome = .done,
                          backup: String? = nil,
                          trashResult: String? = nil) -> ExecutedActionItem {
        ExecutedActionItem(action: action, outcome: outcome,
                           resultNote: "note", backupPath: backup,
                           trashResultPath: trashResult)
    }

    func testUndoStepsPerKind() {
        let probe = standardProbe()
        guard case .proposed(let rename) = propose(.rename, ActionInputs(
                sourcePath: "\(root)/photo.jpg", newName: "beach.jpg"), probe: probe),
              case .proposed(let copy) = propose(.copy, ActionInputs(
                sourcePath: "\(root)/notes.txt",
                destinationPath: "\(root)/notes copy.txt"), probe: probe),
              case .proposed(let folder) = propose(.createFolder, ActionInputs(
                sourcePath: "\(root)/Trips"), probe: probe),
              case .proposed(let trash) = propose(.trash, ActionInputs(
                sourcePath: "\(root)/taken.txt"), probe: probe)
        else { return XCTFail("setup") }

        let steps = ActionUndo.steps(for: [
            executed(rename), executed(copy), executed(folder),
            executed(trash, trashResult: "/Users/tester/.Trash/taken.txt"),
        ], home: home)
        // Reverse order: trash undone first, rename last; steps are
        // keyed by the action's id.
        XCTAssertEqual(steps.map { $0.itemID },
                       [trash.id, folder.id, copy.id, rename.id])
        XCTAssertEqual(steps[0].kind,
                       .moveBack(from: "/Users/tester/.Trash/taken.txt",
                                 to: "\(root)/taken.txt"))
        XCTAssertEqual(steps[1].kind, .removeFolderIfEmpty(path: "\(root)/Trips"))
        XCTAssertEqual(steps[2].kind, .trashFile(path: "\(root)/notes copy.txt"))
        XCTAssertEqual(steps[3].kind,
                       .moveBack(from: "\(root)/beach.jpg",
                                 to: "\(root)/photo.jpg"))
    }

    func testUndoEditRestoresBackupOrTrashesTheFile() {
        let probe = standardProbe()
        guard case .proposed(let replace) = propose(.editText, ActionInputs(
                sourcePath: "\(root)/notes.txt", editText: "new"), probe: probe),
              case .proposed(let create) = propose(.editText, ActionInputs(
                sourcePath: "\(root)/new.txt", editText: "hi"), probe: probe)
        else { return XCTFail("setup") }

        // With the executor's backup: restore the old contents.
        let withBackup = ActionUndo.steps(for: [
            executed(replace, backup: "/backups/plan/item")], home: home)
        XCTAssertEqual(withBackup.first?.kind,
                       .restoreBackup(backupPath: "/backups/plan/item",
                                      targetPath: "\(root)/notes.txt"))

        // A file the edit created has no backup: its undo is the
        // Trash (nothing of the user's is lost — the file didn't
        // exist before the plan).
        let created = ActionUndo.steps(for: [executed(create)], home: home)
        XCTAssertEqual(created.first?.kind, .trashFile(path: "\(root)/new.txt"))
    }

    func testUndoSkipsFailedAndDeclinedAndHandlesOrphanTrash() {
        let probe = standardProbe()
        guard case .proposed(let rename) = propose(.rename, ActionInputs(
                sourcePath: "\(root)/photo.jpg", newName: "beach.jpg"), probe: probe),
              case .proposed(let trash) = propose(.trash, ActionInputs(
                sourcePath: "\(root)/taken.txt"), probe: probe)
        else { return XCTFail("setup") }

        XCTAssertTrue(ActionUndo.steps(for: [
            executed(rename, outcome: .failed("nope"))], home: home).isEmpty)
        XCTAssertTrue(ActionUndo.steps(for: [
            executed(rename, outcome: .declined)], home: home).isEmpty)

        // Trashed without a recorded Trash location: still listed,
        // but as honestly not undoable.
        let orphan = ActionUndo.steps(for: [executed(trash)], home: home)
        XCTAssertEqual(orphan.count, 1)
        guard case .notUndoable = orphan[0].kind else {
            return XCTFail("expected notUndoable")
        }
        XCTAssertFalse(ActionUndo.hasUndoableSteps(for: [executed(trash)]))
        XCTAssertTrue(ActionUndo.hasUndoableSteps(for: [executed(rename)]))
    }

    // MARK: - Photo resize math

    func testOutputDimensions() {
        XCTAssertEqual(PhotoResize.outputDimensions(
            sourceWidth: 4000, sourceHeight: 3000, maxWidth: 1200).width, 1200)
        XCTAssertEqual(PhotoResize.outputDimensions(
            sourceWidth: 4000, sourceHeight: 3000, maxWidth: 1200).height, 900)
        // Portrait: height follows the width cap proportionally.
        let portrait = PhotoResize.outputDimensions(
            sourceWidth: 3000, sourceHeight: 4000, maxWidth: 1200)
        XCTAssertEqual(portrait.width, 1200)
        XCTAssertEqual(portrait.height, 1600)
        // Never enlarged.
        let small = PhotoResize.outputDimensions(
            sourceWidth: 800, sourceHeight: 600, maxWidth: 1200)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 600)
        // Degenerate input can't divide by zero.
        let zero = PhotoResize.outputDimensions(
            sourceWidth: 0, sourceHeight: 0, maxWidth: 1200)
        XCTAssertEqual(zero.width, 1200)
    }

    func testAttemptWalkOrderAndShrinkRounds() {
        let attempts = PhotoResize.attempts(
            sourceWidth: 4000, sourceHeight: 3000, maxWidth: 1200)
        XCTAssertEqual(attempts.count,
                       (PhotoResize.maxShrinkRounds + 1) * PhotoResize.qualityLadder.count)
        // First attempt: full capped size (larger dimension = height
        // here? no — 1200×900, so the cap is 1200), best quality.
        XCTAssertEqual(attempts.first?.maxPixelSize, 1200)
        XCTAssertEqual(attempts.first?.quality, PhotoResize.qualityLadder.first)
        XCTAssertEqual(attempts.first?.round, 0)
        // Rounds shrink monotonically.
        let roundCaps = Dictionary(grouping: attempts, by: { $0.round })
            .sorted { $0.key < $1.key }
            .map { $0.value.first?.maxPixelSize ?? 0 }
        XCTAssertEqual(roundCaps, [1200, 900, 675, 506])
        // The ladder descends within a round.
        let roundZero = attempts.filter { $0.round == 0 }
        XCTAssertEqual(roundZero.map { $0.quality },
                       PhotoResize.qualityLadder)
    }

    func testNextQualityWalksDown() {
        XCTAssertEqual(PhotoResize.nextQuality(after: 0.85), 0.72)
        XCTAssertEqual(PhotoResize.nextQuality(after: 0.9), 0.85)
        XCTAssertNil(PhotoResize.nextQuality(after: 0.15))
        XCTAssertNil(PhotoResize.nextQuality(after: 0.1))
    }

    // MARK: - Record coding

    func testExecutedItemsRoundTripThroughCoding() {
        guard case .proposed(let action) = propose(.editText, ActionInputs(
            sourcePath: "\(root)/notes.txt", editText: "new"),
            probe: standardProbe()) else { return XCTFail("setup") }
        var item = ExecutedActionItem(
            action: action, outcome: .failed("disk said no"),
            resultNote: "disk said no", artifactPath: "\(root)/x.jpg",
            artifactBytes: 1234, backupPath: "/backups/1")
        item.undoNote = "Undone."
        let decoded = ActionPlanCoding.decodeItems(
            ActionPlanCoding.encodeItems([item]))
        XCTAssertEqual(decoded, [item])
        XCTAssertEqual(ActionPlanCoding.decodeItems(nil), [])
        XCTAssertEqual(ActionPlanCoding.decodeItems(Data("junk".utf8)), [])
    }

    // MARK: - Settings persistence

    func testFileWritingTogglePersistsAndDefaultsOff() {
        let suite = "LocalLLMTests.fileWriting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppSettings(defaults: defaults).fileWritingEnabled)
        let settings = AppSettings(defaults: defaults)
        settings.fileWritingEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).fileWritingEnabled)
    }

    // MARK: - Runtime propose path (real folder, nothing changes)

    private actor ProposalBox {
        var actions: [PlannedAction] = []
        var accept = true
        func add(_ action: PlannedAction) -> Bool {
            guard accept else { return false }
            actions.append(action)
            return true
        }
    }

    func testRuntimeProposesWithoutTouchingTheDisk() async throws {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalLLMTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        let source = base.appendingPathComponent("photo.jpg")
        try Data("fake".utf8).write(to: source)
        let resolvedRoot = FileAccessService.resolvedPath(base.path)!
        let resolvedSource = FileAccessService.resolvedPath(source.path)!

        let box = ProposalBox()
        let runtime = ToolRuntime(
            configuration: ToolRuntime.Configuration(
                conversationID: UUID(),
                enabledSources: [.files],
                folderRootPaths: [resolvedRoot],
                redactResults: false,
                redactionTerms: [],
                fileWritingEnabled: true,
                proposalSink: { _, action in await box.add(action) }),
            sink: { _ in },
            permissionProvider: { _ in .authorized })

        let result = await runtime.execute(
            toolName: "rename_file",
            arguments: ToolArguments(path: resolvedSource, newName: "beach.jpg"))
        XCTAssertTrue(result.contains("NOTHING has been changed yet"),
                      "unexpected result: \(result)")
        let proposed = await box.actions
        XCTAssertEqual(proposed.count, 1)
        XCTAssertEqual(proposed.first?.destinationPath,
                       (resolvedRoot as NSString).appendingPathComponent("beach.jpg"))
        // The guarantee itself: the file is exactly where it was.
        XCTAssertTrue(fileManager.fileExists(atPath: resolvedSource))
        XCTAssertFalse(fileManager.fileExists(
            atPath: proposed.first?.destinationPath ?? ""))

        // A refusal (destination now "exists" is not simulated here;
        // instead propose outside the scope) returns the reason and
        // adds nothing.
        let refused = await runtime.execute(
            toolName: "rename_file",
            arguments: ToolArguments(path: "/etc/hosts", newName: "x"))
        XCTAssertTrue(refused.contains("outside the folders shared"),
                      "got: \(refused)")
        let after = await box.actions
        XCTAssertEqual(after.count, 1)
    }

    func testRuntimeRefusesWriteToolsWhileToggleOff() async {
        let runtime = ToolRuntime(
            configuration: ToolRuntime.Configuration(
                conversationID: UUID(),
                enabledSources: [.files],
                folderRootPaths: ["/tmp/whatever"],
                redactResults: false,
                redactionTerms: []),
            sink: { _ in },
            permissionProvider: { _ in .authorized })
        // Not offered…
        let descriptors = await runtime.descriptors
        XCTAssertTrue(descriptors.allSatisfy { !$0.isWriteAction })
        // …and refused if called anyway.
        let result = await runtime.execute(
            toolName: "rename_file",
            arguments: ToolArguments(path: "/tmp/whatever/a.txt", newName: "b.txt"))
        XCTAssertTrue(result.contains("File changes are turned off"),
                      "got: \(result)")
    }
}
