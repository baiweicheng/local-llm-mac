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
///
/// PRIVACY: tool results are local data. In this phase every
/// tool-capable backend is local (the on-device model and MLX models
/// run on this Mac; endpoint chats get no tools), so results never
/// leave the machine and `redactResults` is false. The flag exists
/// for Phase 8's cloud tier: when a framework cloud backend (Private
/// Cloud Compute / OpenRouter) ever hosts tools, the engine sets it
/// and results pass through the Phase 4 `Redactor` here, before
/// returning — the one choke point no result can bypass. Tools are
/// likewise disabled entirely under Local Only for any network backend
/// (today: endpoint chats have no tools at all, under any setting).
actor ToolRuntime {

    struct Configuration: Sendable {
        var conversationID: UUID
        var enabledSources: Set<VisibilitySource>
        var folderRootPaths: [String]
        /// Phase 8 hook — see the type comment. False for every
        /// tool-capable backend that exists in Phase 5.
        var redactResults: Bool
        var redactionTerms: [String]
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

    /// The tools this session may offer its model.
    var descriptors: [ToolDescriptor] {
        ToolCatalog.descriptors(enabledSources: configuration.enabledSources)
    }

    /// Run one tool call and return the text the model sees. Never
    /// throws: every failure is a plain-English sentence the model can
    /// relay, because a 3B model handles "the calendar is turned off"
    /// far better than an exception.
    func execute(toolName: String, arguments: ToolArguments) async -> String {
        guard let descriptor = ToolCatalog.descriptor(named: toolName) else {
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
            result = "The app doesn't have permission for \(source.displayName) yet. "
                + (PermissionGuidance.text(source: source, state: state)
                    ?? "The user can allow it in Settings → What this app can see.")
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
            resultSummary: ToolResultText.summary(of: clamped),
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
}
