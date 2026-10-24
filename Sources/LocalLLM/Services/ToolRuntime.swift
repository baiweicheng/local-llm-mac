import Foundation

/// Phase 5: the app-level tool runtime — the one place every tool
/// call flows through, whichever backend made it.
///
/// The framework backend calls it via `FrameworkTool`; the MLX
/// backend calls it from its toolDispatch closure. Both paths get the
/// same guarantees, enforced here and nowhere else:
///
///  - A tool only runs if its source is enabled in this session's
///    snapshot (defense in depth — disabled tools aren't even offered,
///    but a stale session can't resurrect one).
///  - A source behind a system permission only runs while that
///    permission is actually granted; otherwise the model gets the
///    plain-English guidance to pass along, not an error.
///  - Results are clamped to the Phase 2 context budget before they
///    can enter a prompt.
///  - Every execution emits a `ToolEvent` — which the engine persists
///    to the access log and renders as a transcript card.
///  - Phase 6: file-action tools never execute here at all. A call is
///    validated (scope on both ends, never-overwrite) and handed to
///    the engine as a proposal via `Configuration.proposalSink`; the
///    disk changes only after the user approves the list in the chat,
///    in `FileActionService`. The proposal itself is logged like any
///    other call, so proposals and executions both appear in the
///    audit log.
///  - Phase 9: the power tools follow the file actions exactly —
///    a `run_command` call or an MCP server tool call is validated
///    (the command's folder against the same scope; an MCP call's
///    arguments canonicalized) and proposed through the same sink.
///    Execution lives in `ShellCommandService` / `MCPServerManager`,
///    reached only from the engine's approve path.
///
/// PRIVACY: tool results are local data. While every tool-capable
/// backend was local (Phases 5–7), results never left the machine
/// and `redactResults` stayed false. Phase 8 turns the flag ON for
/// the one tool host that is remote — Private Cloud Compute: the
/// engine builds a PCC session's runtime with `redactResults` set
/// and the user's custom terms attached, and every result passes
/// through the Phase 4 `Redactor` HERE, before returning — the one
/// choke point no result can bypass, whichever tool produced it.
/// (OpenRouter, like the Phase 3 servers, hosts no tools at all;
/// and under Local Only the factory refuses cloud backends before
/// a session can exist.)
actor ToolRuntime {

    struct Configuration: Sendable {
        var conversationID: UUID
        var enabledSources: Set<VisibilitySource>
        var folderRootPaths: [String]
        /// Phase 8: on when this session's tool host is remote
        /// (Private Cloud Compute) — results are scrubbed before
        /// returning. False for local hosts (on-device, MLX).
        var redactResults: Bool
        var redactionTerms: [String]
        /// Phase 6: the file-writing Settings toggle, snapshotted
        /// with the rest of the tool availability. Write tools are
        /// offered only while it's on, and a call that arrives with
        /// it off (a stale session) is refused here.
        var fileWritingEnabled: Bool = false
        /// Phase 9: the power-tools master switch, snapshotted the
        /// same way, plus the MCP tools the manager discovered for
        /// this session (already namespaced; their descriptors join
        /// the catalog's for as long as the switch is on). A call
        /// naming a tool the snapshot doesn't know — a server that
        /// stopped, a session built before a server was added — is
        /// answered plainly, never guessed at.
        var powerToolsEnabled: Bool = false
        /// Audit S-06: the Local Only lock, snapshotted with the
        /// rest. While it's on, power tools are neither offered nor
        /// run here — defense in depth behind the catalog gate, so
        /// even a session built before the lock flipped refuses a
        /// power call instead of proposing one.
        var localOnly: Bool = false
        var mcpTools: [MCPToolInfo] = []
        /// Phase 6: where validated proposals go — the engine's
        /// pending approval list for the conversation. Returns false
        /// when the identical change is already on the list (and for
        /// the default sink, which accepts nothing).
        var proposalSink: @Sendable (UUID, PlannedAction) async -> Bool = { _, _ in false }
    }

    private let configuration: Configuration
    private let sink: @Sendable (ToolEvent) async -> Void
    private let permissionProvider: @Sendable (VisibilitySource) -> PermissionState

    init(configuration: Configuration,
         sink: @escaping @Sendable (ToolEvent) async -> Void,
         permissionProvider: @escaping @Sendable (VisibilitySource) -> PermissionState) {
        self.configuration = configuration
        self.sink = sink
        self.permissionProvider = permissionProvider
    }

    /// The tools this session may offer its model: the static
    /// catalog (gated by sources + the writing and power switches)
    /// plus this snapshot's MCP server tools.
    var descriptors: [ToolDescriptor] {
        var result = ToolCatalog.descriptors(
            enabledSources: configuration.enabledSources,
            fileWritingEnabled: configuration.fileWritingEnabled,
            powerToolsEnabled: configuration.powerToolsEnabled,
            localOnly: configuration.localOnly)
        if configuration.powerToolsEnabled, !configuration.localOnly {
            result += configuration.mcpTools.map(\.descriptor)
        }
        return result
    }

    /// Looks a called tool up in the same merged set `descriptors`
    /// offers — static catalog first, then the MCP snapshot (whose
    /// names are namespaced and can't collide with the catalog's).
    private func descriptor(named name: String) -> ToolDescriptor? {
        if let descriptor = ToolCatalog.descriptor(named: name) {
            return descriptor
        }
        return configuration.mcpTools
            .first { $0.namespacedName == name }?.descriptor
    }

    /// Run one tool call and return the text the model sees. Never
    /// throws: every failure is a plain-English sentence the model can
    /// relay, because a 3B model handles "the calendar is turned off"
    /// far better than an exception.
    func execute(toolName: String, arguments: ToolArguments) async -> String {
        guard let descriptor = descriptor(named: toolName) else {
            return "That tool doesn't exist."
        }
        let result: String
        if let source = descriptor.source,
           !configuration.enabledSources.contains(source) {
            result = "That lookup is turned off. The user can enable \(source.displayName) in Settings → What this app can see."
        } else if let source = descriptor.source,
                  source.needsSystemPermission,
                  permissionProvider(source) != .authorized {
            let state = permissionProvider(source)
            if state == .notDetermined {
                // UAT-10: the source is already ON (that's why the
                // tool exists) — the Settings guidance's "turn this
                // on" would dead-end here. The actual fix is the
                // Allow… button next to the source in Settings, so
                // the relayed refusal names it.
                result = "The app doesn't have permission for "
                    + "\(source.displayName) yet — macOS hasn't been "
                    + "asked. The user can allow it in Settings → "
                    + "What this app can see: there's an Allow… "
                    + "button next to \(source.displayName)."
            } else {
                result = "The app doesn't have permission for \(source.displayName) yet. "
                    + (PermissionGuidance.text(source: source, state: state)
                        ?? "The user can allow it in Settings → What this app can see.")
            }
        } else if descriptor.isWriteAction, !configuration.fileWritingEnabled {
            // Defense in depth: write tools aren't offered while the
            // toggle is off, but a session built earlier could still
            // try one.
            result = "File changes are turned off. The user can turn them on in Settings → File changes — every proposed change still needs their approval before anything happens."
        } else if descriptor.isPowerAction, configuration.localOnly {
            // Audit S-06: the lock pauses power tools outright —
            // an approved command or server call can itself send
            // data off this Mac, which is what the lock forbids.
            result = "Power tools are paused while Local Only is on — a command or server call could itself reach the network. The user can turn Local Only off in Settings if they want this to run."
        } else if descriptor.isPowerAction, !configuration.powerToolsEnabled {
            // Same defense in depth for the power switch.
            result = "Power tools are turned off. The user can turn them on in Settings → Power tools — every command and server call still needs their approval before anything runs."
        } else if descriptor.isWriteAction {
            result = await propose(descriptor: descriptor, arguments: arguments)
        } else if descriptor.isPowerAction {
            result = await proposePower(descriptor: descriptor, arguments: arguments)
        } else {
            result = await run(descriptor: descriptor, arguments: arguments)
        }

        let redacted = configuration.redactResults
            ? Redactor.redact(result, customTerms: configuration.redactionTerms).text
            : result
        let clamped = ToolResultText.clamp(redacted)

        await sink(ToolEvent(
            conversationID: configuration.conversationID,
            toolName: descriptor.name,
            source: descriptor.source,
            querySummary: arguments.summary(for: descriptor.name),
            // Audit S-11: content-bearing tools (clipboard, file
            // reads) log a type-and-size summary, never content.
            resultSummary: ToolResultText.summary(
                of: clamped, toolName: descriptor.name),
            date: Date()))

        return clamped
    }

    // MARK: - Execution table

    private func run(descriptor: ToolDescriptor, arguments: ToolArguments) async -> String {
        switch descriptor.name {
        case "search_files":
            return await SpotlightSearchService.search(
                phrase: arguments.query ?? "", limit: arguments.limitClamped)
        case "list_folder":
            return FileAccessService.listFolder(
                path: arguments.path ?? "", roots: configuration.folderRootPaths)
        case "read_file":
            return FileAccessService.readFile(
                path: arguments.path ?? "", roots: configuration.folderRootPaths)
        case "calendar_events":
            return CalendarService.upcomingEvents(days: arguments.daysClamped)
        case "list_reminders":
            return await CalendarService.incompleteReminders(limit: arguments.limitClamped)
        case "search_contacts":
            return ContactsService.search(name: arguments.query ?? "")
        case "recent_photos":
            return PhotosService.recentPhotos(
                albumName: arguments.query, limit: arguments.limitClamped)
        case "photo_text":
            return await PhotosService.photoText(index: arguments.indexClamped)
        case "search_music":
            return await MusicService.searchLibrary(
                term: arguments.query ?? "", limit: arguments.limitClamped)
        case "now_playing":
            return MusicService.nowPlaying()
        case "system_info":
            return SystemInfoService.systemInfo()
        case "read_clipboard":
            return ClipboardService.read()
        case "write_clipboard":
            return ClipboardService.write(arguments.text ?? "")
        case "calculate":
            return Calculator.evaluate(arguments.expression ?? "")
        case "current_time":
            return DateDisplay.fullDescription(of: Date(), timeZone: .current)
        default:
            return "That tool isn't wired up yet."
        }
    }

    // MARK: - Phase 6: file-action proposals

    /// Validates a file-action call and, when it passes, puts it on
    /// the conversation's approval list. The only disk access here
    /// is read-only (resolving paths, checking what exists): a
    /// proposal NEVER changes anything. Validation failures come
    /// back as the plain-English refusal the model relays.
    private func propose(descriptor: ToolDescriptor,
                         arguments: ToolArguments) async -> String {
        guard let kind = PlannedActionKind(toolName: descriptor.name) else {
            return "That tool isn't wired up yet."
        }
        let roots = configuration.folderRootPaths
        let inputs: ActionInputs
        switch kind {
        case .rename:
            inputs = ActionInputs(sourcePath: resolved(arguments.path),
                                  newName: arguments.newName)
        case .move, .copy:
            inputs = ActionInputs(sourcePath: resolved(arguments.path),
                                  destinationPath: resolved(arguments.destination))
        case .createFolder:
            inputs = ActionInputs(sourcePath: resolved(arguments.path))
        case .editText:
            inputs = ActionInputs(sourcePath: resolved(arguments.path),
                                  editText: arguments.text,
                                  appendEdit: arguments.appendFlag)
        case .trash:
            inputs = ActionInputs(sourcePath: resolved(arguments.path))
        case .resizePhoto:
            let filePath = resolved(arguments.path)
            inputs = ActionInputs(
                sourcePath: filePath,
                destinationPath: resolved(arguments.destination),
                sourcePhotoIndex: filePath == nil ? arguments.indexClamped : nil,
                libraryPhotoName: filePath == nil
                    ? PhotosService.recentPhotoFilename(index: arguments.indexClamped)
                    : nil,
                maxWidthPx: arguments.maxWidthClamped,
                byteCeiling: arguments.maxBytesClamped)
        }

        let outcome = ActionProposal.make(
            kind: kind, inputs: inputs, roots: roots,
            probe: FileActionService.probe, home: NSHomeDirectory())
        return await submit(outcome, nothingYet: "NOTHING has been changed yet")
    }

    /// Hands a validated proposal to the engine's approval list
    /// and words the answer for the model: proposed means PENDING,
    /// in terms a small model won't misread as done.
    private func submit(_ outcome: ProposalOutcome,
                        nothingYet: String) async -> String {
        switch outcome {
        case .refused(let reason):
            return reason
        case .proposed(let action):
            if await configuration.proposalSink(configuration.conversationID, action) {
                return "Added to the list for the user's approval — \(nothingYet): \(action.summary) The user sees the list in the chat with Approve and Discard buttons. Do not say it is done; what the user decides comes back in a later message."
            }
            return "That exact item is already on the approval list — the user hasn't decided yet, so nothing new was added."
        }
    }

    // MARK: - Phase 9: power-tool proposals

    /// The same propose-only path for the power tools: a shell
    /// command, or a call to one of the session's MCP servers. The
    /// only "execution" here is validation — resolving the folder a
    /// command would run in, canonicalizing an MCP call's
    /// arguments. Nothing runs; nothing is called.
    private func proposePower(descriptor: ToolDescriptor,
                              arguments: ToolArguments) async -> String {
        let roots = configuration.folderRootPaths
        if descriptor.name == "run_command" {
            let inputs = ActionInputs(
                commandText: arguments.command,
                workingDirectory: resolved(arguments.path))
            let outcome = ActionProposal.make(
                kind: .runCommand, inputs: inputs, roots: roots,
                probe: FileActionService.probe, home: NSHomeDirectory())
            return await submit(outcome, nothingYet: "NOTHING has been run yet")
        }
        guard let tool = configuration.mcpTools.first(
            where: { $0.namespacedName == descriptor.name }) else {
            return SharedWording.mcpToolUnavailable
        }
        let inputs = ActionInputs(mcpTool: tool,
                                  mcpArgumentsRaw: arguments.argumentsJSON)
        let outcome = ActionProposal.make(
            kind: .mcpCall, inputs: inputs, roots: roots,
            probe: FileActionService.probe, home: NSHomeDirectory())
        return await submit(outcome, nothingYet: "NOTHING has been run yet")
    }

    /// The resolved absolute form of a path the model named (nil for
    /// an empty one) — the same resolution the read tools use, so a
    /// path means the same thing on both sides.
    private func resolved(_ rawPath: String?) -> String? {
        guard let rawPath,
              !rawPath.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return FileAccessService.resolvedPath(rawPath)
    }
}
