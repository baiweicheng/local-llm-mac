import Foundation

/// Phase 6: file actions — the propose-then-confirm layer.
///
/// Phase 5 taught the model to *look*; this phase lets it *propose
/// changes*. The deal, enforced by the shape of this file plus the
/// runtime and the engine:
///
///  - A write tool call NEVER touches the disk. It produces a
///    `PlannedAction` — one line on a list the user reviews in the
///    chat (each item removable) and approves or discards as a whole.
///  - A proposal is validated here, purely: both ends of every
///    operation must sit inside the Phase 5 shared folders (the same
///    `FileScope` check), the source must exist, and — the standing
///    rule — NOTHING EVER OVERWRITES: a destination that already
///    exists refuses the proposal, so the model picks another name.
///  - Execution re-checks the same rules against the current disk
///    (`ActionExecution.preCheck`) before each item runs, because the
///    world can change between proposing and approving.
///  - Everything reversible gets an undo step (`ActionUndo`), built
///    here from the execution record: renames and moves go back,
///    copies and created files go to the Trash, created folders are
///    removed if still empty, edits restore the backup the executor
///    took first, and trashed items come back from the Trash.
///
/// Everything in this file is pure logic over injected facts (a
/// `FileSystemProbe` answers "does it exist / is it a folder"), so
/// the whole safety story is unit-testable with no disk at all.

// MARK: - What the disk looks like, as a question

/// The only two questions validation ever asks about the real disk.
/// The service layer answers them with FileManager; tests answer them
/// with a fake.
protocol FileSystemProbe: Sendable {
    func exists(atPath path: String) -> Bool
    func isDirectory(atPath path: String) -> Bool
}

// MARK: - Path display

/// Path string helpers for summaries — the pure counterparts of the
/// private helpers in `FileAccessService`, with the home folder
/// injected so tests can pin the output.
enum PathDisplay {

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func joining(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    /// "~/Downloads" form — what summaries show instead of a long
    /// absolute path.
    static func shortened(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The file name with its extension removed ("photo" for
    /// "photo.jpg") — used to derive a resized photo's default name.
    static func stem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
    }
}

// MARK: - The plan item

enum PlannedActionKind: String, Codable, Sendable, CaseIterable {
    case rename
    case move
    case copy
    case createFolder
    case editText
    case trash
    case resizePhoto

    /// The tool whose call proposes this kind of action.
    var toolName: String {
        switch self {
        case .rename: return "rename_file"
        case .move: return "move_file"
        case .copy: return "copy_file"
        case .createFolder: return "create_folder"
        case .editText: return "edit_text_file"
        case .trash: return "trash_file"
        case .resizePhoto: return "resize_photo"
        }
    }

    init?(toolName: String) {
        for kind in Self.allCases where kind.toolName == toolName {
            self = kind
            return
        }
        return nil
    }
}

/// One proposed file change, as it sits on the approval list. Paths
/// are the resolved (symlink-standardized) absolute forms the scope
/// check approved; `summary` is the plain-English line the card, the
/// log, and the model's outcome note all share.
struct PlannedAction: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var kind: PlannedActionKind
    /// The item being changed (rename/move/copy/trash, file-based
    /// resize). Nil for createFolder/editText (their target is the
    /// destination) and for library-photo resizes.
    var sourcePath: String?
    /// Library-photo resize only: which recent photo (0 = most recent).
    var sourcePhotoIndex: Int?
    /// Where the action's result lands: rename/move/copy target,
    /// the folder to create, the file to write, the resized output.
    var destinationPath: String?
    /// editText only: the text to write (replace or append).
    var editText: String?
    var appendEdit: Bool
    /// resizePhoto only: the caps the user approved seeing.
    var maxWidthPx: Int?
    var byteCeiling: Int?
    var summary: String

    init(id: UUID = UUID(),
         kind: PlannedActionKind,
         sourcePath: String? = nil,
         sourcePhotoIndex: Int? = nil,
         destinationPath: String? = nil,
         editText: String? = nil,
         appendEdit: Bool = false,
         maxWidthPx: Int? = nil,
         byteCeiling: Int? = nil,
         summary: String) {
        self.id = id
        self.kind = kind
        self.sourcePath = sourcePath
        self.sourcePhotoIndex = sourcePhotoIndex
        self.destinationPath = destinationPath
        self.editText = editText
        self.appendEdit = appendEdit
        self.maxWidthPx = maxWidthPx
        self.byteCeiling = byteCeiling
        self.summary = summary
    }
}

/// The raw material for a proposal, as the runtime assembles it from
/// a tool call: paths already symlink-resolved (scope is checked
/// here, against the resolved forms), numeric caps already clamped.
struct ActionInputs: Sendable, Equatable {
    var sourcePath: String?
    var destinationPath: String?
    var newName: String?
    var editText: String?
    var appendEdit: Bool = false
    var sourcePhotoIndex: Int?
    /// For a library-photo resize: the photo's file name at that
    /// index, used to derive the output name. Nil when the index ran
    /// past the end of the library's recent photos.
    var libraryPhotoName: String?
    var maxWidthPx: Int = 1200
    var byteCeiling: Int = 512_000
}

/// A proposal attempt's outcome: an action ready for the list, or
/// the plain-English reason there can't be one (which the model
/// relays to the user, so it is written for the user via the model).
/// (Error conformance is only so the shared source check can hand
/// its refusal back through a Result — a refusal is a normal,
/// expected answer, not a failure of the app.)
enum ProposalOutcome: Error, Sendable, Equatable {
    case proposed(PlannedAction)
    case refused(String)
}

// MARK: - Proposal validation

enum ActionProposal {

    static func make(kind: PlannedActionKind,
                     inputs: ActionInputs,
                     roots: [String],
                     probe: FileSystemProbe,
                     home: String) -> ProposalOutcome {
        switch kind {
        case .rename: return rename(inputs: inputs, roots: roots, probe: probe, home: home)
        case .move: return moveOrCopy(kind: .move, inputs: inputs, roots: roots, probe: probe, home: home)
        case .copy: return moveOrCopy(kind: .copy, inputs: inputs, roots: roots, probe: probe, home: home)
        case .createFolder: return createFolder(inputs: inputs, roots: roots, probe: probe, home: home)
        case .editText: return editText(inputs: inputs, roots: roots, probe: probe, home: home)
        case .trash: return trash(inputs: inputs, roots: roots, probe: probe, home: home)
        case .resizePhoto: return resizePhoto(inputs: inputs, roots: roots, probe: probe, home: home)
        }
    }

    // MARK: Shared checks

    private static func inScope(_ path: String, roots: [String]) -> Bool {
        FileScope.isPath(path, insideAnyRoot: roots)
    }

    private static func outsideScopeMessage(roots: [String]) -> String {
        guard !roots.isEmpty else {
            return "That can't be changed — no folders are shared with the app. The user can share folders in Settings → What this app can see → Shared folders."
        }
        let list = roots.map { "• \($0)" }.joined(separator: "\n")
        return "That path is outside the folders shared with the app, so it can't be changed. Shared folders:\n\(list)"
    }

    private static func missingMessage(_ path: String, home: String) -> String {
        "There's nothing at \(PathDisplay.shortened(path, home: home)) — it may have been moved or deleted."
    }

    private static func alreadyExistsMessage(name: String, folder: String, home: String) -> String {
        "There's already something named “\(name)” in \(PathDisplay.shortened(folder, home: home)), and a change never overwrites what's there. Pick a different name."
    }

    /// The checks every existing-item operation shares: present,
    /// inside scope, actually there.
    private static func checkedSource(inputs: ActionInputs,
                                      roots: [String],
                                      probe: FileSystemProbe,
                                      home: String) -> Result<String, ProposalOutcome> {
        guard let source = inputs.sourcePath, !source.isEmpty else {
            return .failure(.refused("That change needs the item's full path (path) — none was given."))
        }
        guard inScope(source, roots: roots) else {
            return .failure(.refused(outsideScopeMessage(roots: roots)))
        }
        guard probe.exists(atPath: source) else {
            return .failure(.refused(missingMessage(source, home: home)))
        }
        return .success(source)
    }

    /// The destination checks move/copy/resize share: present, in
    /// scope, its folder exists, and nothing sits there already.
    private static func checkedDestination(_ destination: String,
                                           roots: [String],
                                           probe: FileSystemProbe,
                                           home: String) -> ProposalOutcome? {
        guard inScope(destination, roots: roots) else {
            return .refused(outsideScopeMessage(roots: roots))
        }
        let parent = PathDisplay.parentPath(destination)
        guard probe.isDirectory(atPath: parent) else {
            return .refused("The folder \(PathDisplay.shortened(parent, home: home)) doesn't exist, so nothing can be put there. Create it first (create_folder) or pick a folder that exists.")
        }
        guard !probe.exists(atPath: destination) else {
            return .refused(alreadyExistsMessage(
                name: PathDisplay.fileName(destination), folder: parent, home: home))
        }
        return nil
    }

    // MARK: Per kind

    private static func rename(inputs: ActionInputs, roots: [String],
                               probe: FileSystemProbe, home: String) -> ProposalOutcome {
        let source: String
        switch checkedSource(inputs: inputs, roots: roots, probe: probe, home: home) {
        case .success(let path): source = path
        case .failure(let outcome): return outcome
        }
        let newName = (inputs.newName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newName.contains("/"),
              newName != ".", newName != ".." else {
            return .refused("The new name must be just a name — non-empty, with no slashes in it.")
        }
        let folder = PathDisplay.parentPath(source)
        let destination = PathDisplay.joining(folder, newName)
        guard destination != source else {
            return .refused("“\(newName)” is the name it already has.")
        }
        guard !probe.exists(atPath: destination) else {
            return .refused(alreadyExistsMessage(name: newName, folder: folder, home: home))
        }
        let summary = "Rename “\(PathDisplay.fileName(source))” → “\(newName)” in \(PathDisplay.shortened(folder, home: home))"
        return .proposed(PlannedAction(kind: .rename, sourcePath: source,
                                       destinationPath: destination,
                                       summary: summary))
    }

    private static func moveOrCopy(kind: PlannedActionKind,
                                   inputs: ActionInputs, roots: [String],
                                   probe: FileSystemProbe, home: String) -> ProposalOutcome {
        let verb = kind == .move ? "Move" : "Copy"
        let source: String
        switch checkedSource(inputs: inputs, roots: roots, probe: probe, home: home) {
        case .success(let path): source = path
        case .failure(let outcome): return outcome
        }
        guard let destination = inputs.destinationPath, !destination.isEmpty else {
            return .refused("That change needs the full destination path (destination) — where the \(kind == .move ? "moved" : "copied") item should end up.")
        }
        guard destination != source else {
            return .refused("That's where it already is.")
        }
        // A folder can never land inside itself.
        if probe.isDirectory(atPath: source),
           destination == source || destination.hasPrefix(source + "/") {
            return .refused("A folder can't be \(kind == .move ? "moved" : "copied") into itself.")
        }
        if let refusal = checkedDestination(destination, roots: roots, probe: probe, home: home) {
            return refusal
        }
        let name = PathDisplay.fileName(source)
        let summary = "\(verb) “\(name)” from \(PathDisplay.shortened(PathDisplay.parentPath(source), home: home)) to \(PathDisplay.shortened(PathDisplay.parentPath(destination), home: home))"
        return .proposed(PlannedAction(kind: kind, sourcePath: source,
                                       destinationPath: destination,
                                       summary: summary))
    }

    private static func createFolder(inputs: ActionInputs, roots: [String],
                                     probe: FileSystemProbe, home: String) -> ProposalOutcome {
        guard let path = inputs.sourcePath, !path.isEmpty else {
            return .refused("Creating a folder needs its full path (path) — none was given.")
        }
        guard inScope(path, roots: roots) else {
            return .refused(outsideScopeMessage(roots: roots))
        }
        guard !probe.exists(atPath: path) else {
            return .refused(probe.isDirectory(atPath: path)
                ? "That folder already exists."
                : "There's already a file at \(PathDisplay.shortened(path, home: home)), so a folder can't be created there.")
        }
        let parent = PathDisplay.parentPath(path)
        guard probe.isDirectory(atPath: parent) else {
            return .refused("The folder \(PathDisplay.shortened(parent, home: home)) doesn't exist, so the new folder can't be created inside it.")
        }
        let summary = "Create folder “\(PathDisplay.fileName(path))” in \(PathDisplay.shortened(parent, home: home))"
        return .proposed(PlannedAction(kind: .createFolder,
                                       destinationPath: path, summary: summary))
    }

    private static func editText(inputs: ActionInputs, roots: [String],
                                 probe: FileSystemProbe, home: String) -> ProposalOutcome {
        guard let path = inputs.sourcePath, !path.isEmpty else {
            return .refused("Editing a file needs its full path (path) — none was given.")
        }
        guard let text = inputs.editText else {
            return .refused("Editing a file needs the text to write (text) — none was given.")
        }
        guard inScope(path, roots: roots) else {
            return .refused(outsideScopeMessage(roots: roots))
        }
        let exists = probe.exists(atPath: path)
        if exists, probe.isDirectory(atPath: path) {
            return .refused("\(PathDisplay.shortened(path, home: home)) is a folder — text can't be written over a folder.")
        }
        if !exists {
            let parent = PathDisplay.parentPath(path)
            guard probe.isDirectory(atPath: parent) else {
                return .refused("The folder \(PathDisplay.shortened(parent, home: home)) doesn't exist, so the file can't be created there.")
            }
        }
        let name = PathDisplay.fileName(path)
        let folder = PathDisplay.shortened(PathDisplay.parentPath(path), home: home)
        let summary: String
        if inputs.appendEdit {
            summary = exists
                ? "Append text to “\(name)” in \(folder)"
                : "Create “\(name)” in \(folder) with the given text"
        } else {
            summary = exists
                ? "Replace the contents of “\(name)” in \(folder)"
                : "Create “\(name)” in \(folder) with the given text"
        }
        return .proposed(PlannedAction(kind: .editText, destinationPath: path,
                                       editText: text, appendEdit: inputs.appendEdit,
                                       summary: summary))
    }

    private static func trash(inputs: ActionInputs, roots: [String],
                              probe: FileSystemProbe, home: String) -> ProposalOutcome {
        let source: String
        switch checkedSource(inputs: inputs, roots: roots, probe: probe, home: home) {
        case .success(let path): source = path
        case .failure(let outcome): return outcome
        }
        // A shared folder ITSELF is never trashed from here: that
        // would sweep away the whole tree the user designated, not
        // an item in it. (The scope check admits the root by design —
        // it has to, for listing — so the write side refuses it.)
        if roots.contains(where: {
            FileScope.normalizedPath($0).lowercased()
                == FileScope.normalizedPath(source).lowercased()
        }) {
            return .refused("That's one of the shared folders itself — it can't be moved to the Trash from here. Items inside it can be.")
        }
        let summary = "Move “\(PathDisplay.fileName(source))” (in \(PathDisplay.shortened(PathDisplay.parentPath(source), home: home))) to the Trash"
        return .proposed(PlannedAction(kind: .trash, sourcePath: source,
                                       summary: summary))
    }

    private static func resizePhoto(inputs: ActionInputs, roots: [String],
                                    probe: FileSystemProbe, home: String) -> ProposalOutcome {
        guard !roots.isEmpty else {
            return .refused("The resized photo needs somewhere to go — no folders are shared with the app. The user can share a folder in Settings → What this app can see → Shared folders.")
        }
        let sourceName: String
        var sourcePath: String? = nil
        var photoIndex: Int? = nil
        if let path = inputs.sourcePath, !path.isEmpty {
            guard inScope(path, roots: roots) else {
                return .refused(outsideScopeMessage(roots: roots))
            }
            guard probe.exists(atPath: path) else {
                return .refused(missingMessage(path, home: home))
            }
            guard !probe.isDirectory(atPath: path) else {
                return .refused("\(PathDisplay.shortened(path, home: home)) is a folder, not a photo.")
            }
            sourcePath = path
            sourceName = PathDisplay.fileName(path)
        } else if let index = inputs.sourcePhotoIndex {
            guard let name = inputs.libraryPhotoName else {
                return .refused("There aren't that many recent photos in the library.")
            }
            photoIndex = index
            sourceName = name
        } else {
            return .refused("Resizing a photo needs either a recent photo (index) or an image file's path (path).")
        }

        let destination: String
        if let given = inputs.destinationPath, !given.isEmpty {
            destination = given
        } else if let sourcePath {
            destination = PathDisplay.joining(
                PathDisplay.parentPath(sourcePath),
                PathDisplay.stem(sourcePath) + "-resized.jpg")
        } else {
            destination = PathDisplay.joining(
                roots[0], PathDisplay.stem(sourceName) + "-resized.jpg")
        }
        if let refusal = checkedDestination(destination, roots: roots, probe: probe, home: home) {
            return refusal
        }
        let sizeText = ByteCountFormatter.string(
            fromByteCount: Int64(inputs.byteCeiling), countStyle: .file)
        let summary = "Resize “\(sourceName)” → “\(PathDisplay.fileName(destination))” in \(PathDisplay.shortened(PathDisplay.parentPath(destination), home: home)) (at most \(inputs.maxWidthPx) px wide, under \(sizeText))"
        return .proposed(PlannedAction(
            kind: .resizePhoto, sourcePath: sourcePath,
            sourcePhotoIndex: photoIndex, destinationPath: destination,
            maxWidthPx: inputs.maxWidthPx, byteCeiling: inputs.byteCeiling,
            summary: summary))
    }
}

// MARK: - Execution pre-check

/// The proposal rules, re-run at approval time against the disk as
/// it is NOW. The executor calls this before every item; a refusal
/// here fails just that item (with this note) and the rest still run.
/// Edits are the one deliberate exception to never-overwrite: the
/// file being edited IS the destination, and the executor backs it
/// up first — that's what makes the edit undoable.
enum ActionExecution {

    static func preCheck(_ action: PlannedAction,
                         roots: [String],
                         probe: FileSystemProbe) -> String? {
        func scoped(_ path: String) -> Bool {
            FileScope.isPath(path, insideAnyRoot: roots)
        }
        switch action.kind {
        case .rename, .move, .copy:
            guard let source = action.sourcePath, scoped(source) else {
                return "The item is no longer inside a shared folder."
            }
            guard probe.exists(atPath: source) else {
                return "The item isn't there anymore."
            }
            guard let destination = action.destinationPath, scoped(destination) else {
                return "The destination is no longer inside a shared folder."
            }
            if probe.isDirectory(atPath: source),
               destination.hasPrefix(source + "/") {
                return "A folder can't be moved into itself."
            }
            guard !probe.exists(atPath: destination) else {
                return "Something is already at the destination, and a change never overwrites it."
            }
            return nil
        case .createFolder:
            guard let path = action.destinationPath, scoped(path) else {
                return "The folder is no longer inside a shared folder."
            }
            guard !probe.exists(atPath: path) else {
                return "Something is already there."
            }
            return nil
        case .editText:
            guard let path = action.destinationPath, scoped(path) else {
                return "The file is no longer inside a shared folder."
            }
            if probe.exists(atPath: path), probe.isDirectory(atPath: path) {
                return "That path is a folder now."
            }
            return nil
        case .trash:
            guard let source = action.sourcePath, scoped(source) else {
                return "The item is no longer inside a shared folder."
            }
            guard probe.exists(atPath: source) else {
                return "The item isn't there anymore."
            }
            return nil
        case .resizePhoto:
            if let source = action.sourcePath {
                guard scoped(source), probe.exists(atPath: source),
                      !probe.isDirectory(atPath: source) else {
                    return "The photo file isn't there anymore."
                }
            }
            guard let destination = action.destinationPath, scoped(destination) else {
                return "The destination is no longer inside a shared folder."
            }
            guard !probe.exists(atPath: destination) else {
                return "Something is already at the destination, and a change never overwrites it."
            }
            return nil
        }
    }
}

// MARK: - Execution record

/// One item of an executed (or discarded) plan, with what actually
/// happened. This is what the persisted plan record stores (JSON),
/// what the transcript card renders, and what undo is built from.
struct ExecutedActionItem: Codable, Sendable, Equatable {

    enum Outcome: Codable, Sendable, Equatable {
        case done
        case failed(String)
        /// The user discarded the plan — this item never ran.
        case declined
    }

    var action: PlannedAction
    var outcome: Outcome
    /// One plain-English line: what happened, shown on the card and
    /// quoted in the note the model gets.
    var resultNote: String
    /// The file this action CREATED, when it created one (a copy, a
    /// new text file, a resized photo) — rendered as a draggable
    /// artifact chip. `artifactBytes` is its size at execution time,
    /// the chip's label if the file itself is gone.
    var artifactPath: String?
    var artifactBytes: Int?
    /// editText on an existing file: the pre-edit copy the executor
    /// kept, which undo restores. Nil for created files (their undo
    /// is the Trash) and everything else.
    var backupPath: String?
    /// trash: where the item actually landed in the Trash — undo
    /// moves it back from there. Nil when the OS didn't report it,
    /// in which case undo honestly says it can't.
    var trashResultPath: String?
    /// What undo did with this item, once undo has run.
    var undoNote: String?

    init(action: PlannedAction, outcome: Outcome, resultNote: String,
         artifactPath: String? = nil, artifactBytes: Int? = nil,
         backupPath: String? = nil, trashResultPath: String? = nil,
         undoNote: String? = nil) {
        self.action = action
        self.outcome = outcome
        self.resultNote = resultNote
        self.artifactPath = artifactPath
        self.artifactBytes = artifactBytes
        self.backupPath = backupPath
        self.trashResultPath = trashResultPath
        self.undoNote = undoNote
    }

    var succeeded: Bool { outcome == .done }
}

/// JSON coding for plan records, in one place so the record model
/// and the tests agree on the shape.
enum ActionPlanCoding {

    static func encodeItems(_ items: [ExecutedActionItem]) -> Data? {
        try? JSONEncoder().encode(items)
    }

    static func decodeItems(_ data: Data?) -> [ExecutedActionItem] {
        guard let data,
              let items = try? JSONDecoder().decode(
                [ExecutedActionItem].self, from: data) else { return [] }
        return items
    }
}

// MARK: - Plan rules

enum ActionPlanRules {

    /// The same change proposed twice (a chatty model re-issuing a
    /// call) lands on the list once. Identity is kind + source +
    /// destination + edit payload — the summary wording doesn't
    /// count, so a re-phrased duplicate is still a duplicate.
    static func isDuplicate(_ candidate: PlannedAction,
                            in plan: [PlannedAction]) -> Bool {
        plan.contains { existing in
            existing.kind == candidate.kind
                && existing.sourcePath == candidate.sourcePath
                && existing.sourcePhotoIndex == candidate.sourcePhotoIndex
                && existing.destinationPath == candidate.destinationPath
                && existing.editText == candidate.editText
                && existing.appendEdit == candidate.appendEdit
        }
    }
}

// MARK: - Undo

enum UndoStepKind: Equatable, Sendable {
    /// rename/move/trash-restore: put the item at `from` back at `to`.
    case moveBack(from: String, to: String)
    /// copy / created file / resized output: the created file goes
    /// to the Trash (undo is itself reversible from there).
    case trashFile(path: String)
    /// createFolder: remove it, but only while it's still empty.
    case removeFolderIfEmpty(path: String)
    /// editText with a backup: restore the pre-edit contents.
    case restoreBackup(backupPath: String, targetPath: String)
    /// Honestly not reversible — the executor skips these and the
    /// card shows the reason.
    case notUndoable(reason: String)
}

struct UndoStep: Equatable, Sendable {
    let itemID: UUID
    let kind: UndoStepKind
    /// Plain-English line for the card and the model's note.
    let description: String
}

/// Builds the undo plan for an executed plan record: one step per
/// successful item, in REVERSE order (the last thing done is the
/// first thing undone — a rename-then-move chain only unwinds that
/// way). Failed and discarded items get no step — nothing happened.
enum ActionUndo {

    static func steps(for items: [ExecutedActionItem], home: String) -> [UndoStep] {
        items.reversed().compactMap { item in
            guard item.outcome == .done else { return nil }
            let action = item.action
            func name(_ path: String?) -> String {
                path.map { "“\(PathDisplay.fileName($0))”" } ?? "the item"
            }
            switch action.kind {
            case .rename, .move:
                guard let source = action.sourcePath,
                      let destination = action.destinationPath else {
                    return UndoStep(itemID: item.action.id,
                                    kind: .notUndoable(reason: "the original path wasn't recorded"),
                                    description: "Can't undo \(name(action.destinationPath)) — the original path wasn't recorded.")
                }
                let verb = action.kind == .rename ? "Rename" : "Move"
                return UndoStep(
                    itemID: item.action.id,
                    kind: .moveBack(from: destination, to: source),
                    description: "\(verb) \(name(destination)) back to \(PathDisplay.shortened(source, home: home))")
            case .copy:
                guard let destination = action.destinationPath else { return nil }
                return UndoStep(
                    itemID: item.action.id,
                    kind: .trashFile(path: destination),
                    description: "Move the copy \(name(destination)) to the Trash")
            case .createFolder:
                guard let path = action.destinationPath else { return nil }
                return UndoStep(
                    itemID: item.action.id,
                    kind: .removeFolderIfEmpty(path: path),
                    description: "Remove the folder \(name(path)) (only if it's still empty)")
            case .editText:
                guard let path = action.destinationPath else { return nil }
                if let backup = item.backupPath {
                    return UndoStep(
                        itemID: item.action.id,
                        kind: .restoreBackup(backupPath: backup, targetPath: path),
                        description: "Restore \(name(path)) to what it said before the edit")
                }
                return UndoStep(
                    itemID: item.action.id,
                    kind: .trashFile(path: path),
                    description: "Move the created file \(name(path)) to the Trash")
            case .trash:
                guard let source = action.sourcePath else { return nil }
                if let landed = item.trashResultPath {
                    return UndoStep(
                        itemID: item.action.id,
                        kind: .moveBack(from: landed, to: source),
                        description: "Move \(name(source)) back from the Trash")
                }
                return UndoStep(
                    itemID: item.action.id,
                    kind: .notUndoable(reason: "the app didn't record where it landed in the Trash"),
                    description: "Can't undo moving \(name(source)) to the Trash — its place in the Trash wasn't recorded. It can be dragged back from the Trash in Finder.")
            case .resizePhoto:
                guard let destination = action.destinationPath else { return nil }
                return UndoStep(
                    itemID: item.action.id,
                    kind: .trashFile(path: destination),
                    description: "Move the resized copy \(name(destination)) to the Trash (the original is untouched)")
            }
        }
    }

    /// Whether undo is worth offering for this record at all.
    static func hasUndoableSteps(for items: [ExecutedActionItem]) -> Bool {
        steps(for: items, home: "").contains { step in
            if case .notUndoable = step.kind { return false }
            return true
        }
    }
}
