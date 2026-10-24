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
    /// Phase 9: run a shell command (propose-only, like everything
    /// here — see `Core/PowerTools.swift`). Not undoable.
    case runCommand
    /// Phase 9: call a tool on one of the user's MCP servers.
    /// Not undoable.
    case mcpCall

    /// The tool whose call proposes this kind of action. MCP calls
    /// have no single tool name (each server tool is its own), so
    /// this is the fallback identity used for icons and the audit
    /// log when the concrete name isn't at hand — the runtime's
    /// events and the decided record carry the real namespaced
    /// name from the action itself.
    var toolName: String {
        switch self {
        case .rename: return "rename_file"
        case .move: return "move_file"
        case .copy: return "copy_file"
        case .createFolder: return "create_folder"
        case .editText: return "edit_text_file"
        case .trash: return "trash_file"
        case .resizePhoto: return "resize_photo"
        case .runCommand: return "run_command"
        case .mcpCall: return "mcp_tool"
        }
    }

    init?(toolName: String) {
        for kind in Self.allCases where kind.toolName == toolName {
            self = kind
            return
        }
        return nil
    }

    /// Icon for plan cards. File kinds match their tool's icon;
    /// the power kinds have their own.
    var symbolName: String {
        switch self {
        case .rename: return "pencil"
        case .move: return "arrow.right.square"
        case .copy: return "doc.on.doc"
        case .createFolder: return "folder.badge.plus"
        case .editText: return "square.and.pencil"
        case .trash: return "trash"
        case .resizePhoto: return "arrow.down.right.and.arrow.up.left"
        case .runCommand: return "terminal"
        case .mcpCall: return "puzzlepiece.extension"
        }
    }

    /// Whether executing this kind can be taken back with Undo.
    /// File changes can; a command that has run, or a call another
    /// program has answered, has already happened — the cards say
    /// so up front rather than pretending otherwise.
    var isUndoable: Bool {
        switch self {
        case .runCommand, .mcpCall: return false
        default: return true
        }
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
    /// runCommand only (Phase 9): the EXACT command text and the
    /// folder it runs in (already scope-checked + resolved). The
    /// card renders the command verbatim — approval means "run
    /// precisely this".
    var commandText: String?
    var workingDirectory: String?
    /// Any kind, set when a proposal needs extra care: for a
    /// command, the `DangerousCommandClassifier`'s reason. A
    /// non-nil warning means the item starts UNCHECKED on the
    /// approval list — the user must deliberately check it before
    /// Approve can run it — and renders with a warning marker.
    var dangerWarning: String?
    /// mcpCall only (Phase 9): the server (by id and display name),
    /// the tool's own name, its full namespaced name, and the
    /// arguments in canonical JSON — everything the card shows and
    /// the executor sends.
    var mcpServerID: UUID?
    var mcpServerName: String?
    var mcpToolName: String?
    var mcpNamespacedName: String?
    var mcpArgumentsJSON: String?
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
         commandText: String? = nil,
         workingDirectory: String? = nil,
         dangerWarning: String? = nil,
         mcpServerID: UUID? = nil,
         mcpServerName: String? = nil,
         mcpToolName: String? = nil,
         mcpNamespacedName: String? = nil,
         mcpArgumentsJSON: String? = nil,
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
        self.commandText = commandText
        self.workingDirectory = workingDirectory
        self.dangerWarning = dangerWarning
        self.mcpServerID = mcpServerID
        self.mcpServerName = mcpServerName
        self.mcpToolName = mcpToolName
        self.mcpNamespacedName = mcpNamespacedName
        self.mcpArgumentsJSON = mcpArgumentsJSON
        self.summary = summary
    }

    /// Whether this item must be explicitly opted in on the
    /// approval list before it can run (see `dangerWarning`).
    var requiresExplicitOptIn: Bool { dangerWarning != nil }
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
    // Phase 9: shell + MCP raw material.
    /// runCommand: the exact command text.
    var commandText: String?
    /// runCommand: the requested working folder (already resolved);
    /// nil means "the first shared folder".
    var workingDirectory: String?
    /// mcpCall: the tool, as the runtime resolved it from the
    /// namespaced tool name the model called — server identity plus
    /// the raw arguments string the model supplied.
    var mcpTool: MCPToolInfo?
    var mcpArgumentsRaw: String?
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
        case .runCommand: return runCommand(inputs: inputs, roots: roots, probe: probe, home: home)
        case .mcpCall: return mcpCall(inputs: inputs, roots: roots, probe: probe, home: home)
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

    // MARK: Phase 9 — power tools

    /// A shell command. The scope rule is about where it RUNS: the
    /// working folder must be inside a shared folder (defaulting to
    /// the first one). What the command then does from there is the
    /// command's own business — that's exactly why it sits behind
    /// the power-tools switch plus this approval, and why the card
    /// shows the exact text. A dangerous-pattern hit doesn't refuse
    /// the proposal; it marks it opt-in-only (see `dangerWarning`).
    private static func runCommand(inputs: ActionInputs, roots: [String],
                                   probe: FileSystemProbe, home: String) -> ProposalOutcome {
        let command = (inputs.commandText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .refused("Running a command needs the command itself (command) — none was given.")
        }
        guard !roots.isEmpty else {
            return .refused("Commands run inside a shared folder, and no folders are shared with the app yet. The user can share folders in Settings → What this app can see → Shared folders.")
        }
        let workingDirectory: String
        if let requested = inputs.workingDirectory, !requested.isEmpty {
            guard inScope(requested, roots: roots) else {
                return .refused(outsideScopeMessage(roots: roots))
            }
            guard probe.isDirectory(atPath: requested) else {
                return .refused("The folder \(PathDisplay.shortened(requested, home: home)) doesn't exist, so the command can't run there.")
            }
            workingDirectory = requested
        } else {
            workingDirectory = roots[0]
        }
        let warning = DangerousCommandClassifier.assess(command).reason
        let oneLine = command
            .split(whereSeparator: { $0 == "\n" })
            .joined(separator: " ⏎ ")
        let summary = "Run in \(PathDisplay.shortened(workingDirectory, home: home)): \(String(oneLine.prefix(140)))"
        return .proposed(PlannedAction(
            kind: .runCommand, commandText: command,
            workingDirectory: workingDirectory,
            dangerWarning: warning, summary: summary))
    }

    /// A call to one of the user's MCP servers. The runtime has
    /// already resolved the namespaced tool name to the server's
    /// tool (`inputs.mcpTool`); what's validated here is the
    /// arguments — canonicalized once, so the card, the dedupe, and
    /// the wire all carry the identical text.
    private static func mcpCall(inputs: ActionInputs, roots: [String],
                                probe: FileSystemProbe, home: String) -> ProposalOutcome {
        guard let tool = inputs.mcpTool else {
            return .refused("That tool isn't available — its MCP server may be off or may have stopped. The user can check it in Settings → Power tools.")
        }
        switch MCPArguments.canonicalize(inputs.mcpArgumentsRaw) {
        case .refused(let reason):
            return .refused(reason)
        case .ok(let canonical):
            let summary = "Ask \(tool.serverName) to run “\(tool.toolName)”"
            return .proposed(PlannedAction(
                kind: .mcpCall, mcpServerID: tool.serverID,
                mcpServerName: tool.serverName,
                mcpToolName: tool.toolName,
                mcpNamespacedName: tool.namespacedName,
                mcpArgumentsJSON: canonical, summary: summary))
        }
    }
}

// MARK: - Execution-time path resolution (audit S-02)

extension PlannedAction {

    /// A copy of this action with its paths replaced by their
    /// CURRENT resolved forms, using the two resolvers the service
    /// layer supplies (source paths resolve whole; destination
    /// paths resolve their parent folder and keep the final name,
    /// since the destination usually doesn't exist yet).
    ///
    /// Proposal resolved every path before the scope check; the
    /// point of re-resolving at execution is that the filesystem
    /// may have changed since — a folder swapped for a symlink in
    /// the propose → approve window must be seen for what it now
    /// points at, not what it pointed at then.
    func resolvingPaths(
        sourceResolver: (String) -> String?,
        destinationResolver: (String) -> String?
    ) -> PlannedAction {
        var copy = self
        if let sourcePath, let resolved = sourceResolver(sourcePath) {
            copy.sourcePath = resolved
        }
        if let destinationPath,
           let resolved = destinationResolver(destinationPath) {
            copy.destinationPath = resolved
        }
        if let workingDirectory,
           let resolved = sourceResolver(workingDirectory) {
            copy.workingDirectory = resolved
        }
        return copy
    }
}

// MARK: - Execution pre-check

/// The proposal rules, re-run at approval time against the disk as
/// it is NOW. The executor calls this before every item; a refusal
/// here fails just that item (with this note) and the rest still run.
/// Edits are the one deliberate exception to never-overwrite: the
/// file being edited IS the destination, and the executor backs it
/// up first — that's what makes the edit undoable.
///
/// Audit S-02: the SCOPE tests run on RESOLVED paths. The caller
/// passes the resolvers the read side uses (`FileAccessService`),
/// so a path component swapped for an outward symlink since the
/// proposal resolves outside the shared folders here and is
/// refused — the stored string alone would still have looked
/// in-scope. Existence and never-overwrite tests keep using the
/// stored paths (the filesystem follows links for those anyway,
/// and the executor operates on the stored paths once the resolved
/// forms have passed). The default resolvers are the identity, for
/// callers (and tests) with no filesystem to resolve against.
enum ActionExecution {

    static func preCheck(_ action: PlannedAction,
                         roots: [String],
                         probe: FileSystemProbe,
                         resolve: (String) -> String? = { $0 },
                         resolveDestination: ((String) -> String?)? = nil
    ) -> String? {
        func resolved(_ path: String) -> String {
            resolve(path) ?? path
        }
        func resolvedDestination(_ path: String) -> String {
            (resolveDestination ?? resolve)(path) ?? path
        }
        func scoped(_ path: String) -> Bool {
            FileScope.isPath(resolved(path), insideAnyRoot: roots)
        }
        func scopedDestination(_ path: String) -> Bool {
            FileScope.isPath(resolvedDestination(path),
                             insideAnyRoot: roots)
        }
        switch action.kind {
        case .rename, .move, .copy:
            guard let source = action.sourcePath, scoped(source) else {
                return "The item is no longer inside a shared folder."
            }
            guard probe.exists(atPath: source) else {
                return "The item isn't there anymore."
            }
            guard let destination = action.destinationPath,
                  scopedDestination(destination) else {
                return "The destination is no longer inside a shared folder."
            }
            if probe.isDirectory(atPath: source),
               resolvedDestination(destination)
                .lowercased()
                .hasPrefix(resolved(source).lowercased() + "/") {
                return "A folder can't be moved into itself."
            }
            guard !probe.exists(atPath: destination) else {
                return "Something is already at the destination, and a change never overwrites it."
            }
            return nil
        case .createFolder:
            guard let path = action.destinationPath,
                  scopedDestination(path) else {
                return "The folder is no longer inside a shared folder."
            }
            guard !probe.exists(atPath: path) else {
                return "Something is already there."
            }
            return nil
        case .editText:
            guard let path = action.destinationPath,
                  scopedDestination(path) else {
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
            guard let destination = action.destinationPath,
                  scopedDestination(destination) else {
                return "The destination is no longer inside a shared folder."
            }
            guard !probe.exists(atPath: destination) else {
                return "Something is already at the destination, and a change never overwrites it."
            }
            return nil
        case .runCommand:
            // Phase 9: the folder it runs in must still be shared
            // and still there. (What the command itself does is not
            // re-judged — the user approves the exact text.)
            guard let command = action.commandText, !command.isEmpty else {
                return "The command text is missing."
            }
            guard let directory = action.workingDirectory, scoped(directory) else {
                return "The folder it was to run in is no longer shared."
            }
            guard probe.isDirectory(atPath: directory) else {
                return "The folder it was to run in isn't there anymore."
            }
            return nil
        case .mcpCall:
            // Phase 9: the pure pre-check can only confirm the
            // proposal is complete; whether the server is still
            // configured, enabled, and running is the executor's
            // live check (it fails just this item if not).
            guard action.mcpServerID != nil, action.mcpToolName != nil,
                  action.mcpArgumentsJSON != nil else {
                return "The call is missing its server, tool, or arguments."
            }
            return nil
        }
    }
}

// MARK: - Undo scope (audit S-02)

/// The scope rule for undo steps, checked at undo time on RESOLVED
/// paths — undo originally performed no scope check at all.
///
/// The rule is per kind, because undo's endpoints aren't all
/// user-scope paths by design:
///  - `moveBack`: the place the item returns TO must be inside a
///    shared folder; where it comes FROM must be inside one too —
///    or in the Trash (a trashed item's undo legitimately starts
///    there).
///  - `trashFile` / `removeFolderIfEmpty`: the path acted on must
///    be inside a shared folder.
///  - `restoreBackup`: the file being restored must be inside a
///    shared folder; the backup itself lives in the app's own
///    backup area (its path carries the `ActionBackups` marker),
///    never in user scope, and is admitted on that basis alone.
///  - `notUndoable`: nothing runs, so nothing is checked.
enum UndoStepScope {

    static func isAllowed(_ step: UndoStep,
                          roots: [String],
                          home: String,
                          resolve: (String) -> String?) -> Bool {
        func resolved(_ path: String) -> String { resolve(path) ?? path }
        func scoped(_ path: String) -> Bool {
            FileScope.isPath(resolved(path), insideAnyRoot: roots)
        }
        switch step.kind {
        case .notUndoable:
            return true
        case .moveBack(let from, let to):
            let trashRoot = PathDisplay.joining(home, ".Trash")
            return scoped(to)
                && (scoped(from)
                    || FileScope.isPath(resolved(from),
                                        insideAnyRoot: [trashRoot]))
        case .trashFile(let path), .removeFolderIfEmpty(let path):
            return scoped(path)
        case .restoreBackup(let backupPath, let targetPath):
            return scoped(targetPath)
                && resolved(backupPath).contains("/ActionBackups/")
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
    /// Phase 9: the substance of what happened, beyond the one-line
    /// note — a command's output (tail-capped for the model) or an
    /// MCP call's result text. Shown on the decided card and quoted
    /// in the note the model gets, since for these two kinds the
    /// output IS the point.
    var modelDetail: String?

    init(action: PlannedAction, outcome: Outcome, resultNote: String,
         artifactPath: String? = nil, artifactBytes: Int? = nil,
         backupPath: String? = nil, trashResultPath: String? = nil,
         undoNote: String? = nil, modelDetail: String? = nil) {
        self.action = action
        self.outcome = outcome
        self.resultNote = resultNote
        self.artifactPath = artifactPath
        self.artifactBytes = artifactBytes
        self.backupPath = backupPath
        self.trashResultPath = trashResultPath
        self.undoNote = undoNote
        self.modelDetail = modelDetail
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
                && existing.commandText == candidate.commandText
                && existing.workingDirectory == candidate.workingDirectory
                && existing.mcpNamespacedName == candidate.mcpNamespacedName
                && existing.mcpArgumentsJSON == candidate.mcpArgumentsJSON
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
            case .runCommand:
                // Phase 9: a command that has run can't be un-run.
                // The step exists so the card SAYS that (rather than
                // the item silently having no undo), and
                // `hasUndoableSteps` correctly ignores it.
                return UndoStep(
                    itemID: item.action.id,
                    kind: .notUndoable(reason: "a command that has run can't be un-run"),
                    description: "Can't undo — the command already ran.")
            case .mcpCall:
                return UndoStep(
                    itemID: item.action.id,
                    kind: .notUndoable(reason: "the server already answered the call"),
                    description: "Can't undo — \(action.mcpServerName ?? "the server") already ran the call.")
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
