import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// The chat pane: header with the Phase 3 model picker and model
/// status, the message list, and the composer. Return sends,
/// Shift+Return adds a line. Images can be attached with the paperclip
/// button, by dragging files into the window, or by pasting (⌘V) while
/// the composer is focused.
struct ChatView: View {
    @Bindable var conversation: Conversation
    let engine: ChatEngine
    let mlxStore: MLXModelStore
    let endpointStore: EndpointStore
    let settings: AppSettings
    let fileScopeStore: FileScopeStore
    let permissionCenter: PermissionCenter
    /// Phase 8: whether an OpenRouter key is saved (the picker reads
    /// it for its cloud rows — never the key itself).
    let openRouterKeyStore: OpenRouterKeyStore
    /// Phase 8: backend resolution for compare mode — the same
    /// factory path the engine uses, supplied by the app shell.
    let backendResolver: (ModelSelection) -> ResolvedBackend
    /// Phase 8: compare mode's "continue with this one" lands here —
    /// the shell selects the seeded conversation.
    let onCompareContinue: (Conversation) -> Void
    /// Phase 9: the MCP server list + manager, passed through to
    /// the Settings sheet's Power tools section.
    let mcpServerStore: MCPServerStore
    let mcpManager: MCPServerManager
    /// Audit B-58: the quick-panel coordinator, passed through to
    /// the Settings sheet so its hotkey-failure state can show.
    let hudCoordinator: HUDCoordinator
    @Environment(\.modelContext) private var modelContext

    /// Phase 5: this conversation's tool-lookup records, oldest
    /// first, merged into the transcript by time (see
    /// `transcriptItems`). The access log is global; the predicate
    /// keeps this chat's cards to this chat.
    @Query private var toolRecords: [ToolActivityRecord]

    /// Phase 6: this conversation's decided action plans (approved
    /// or discarded), merged into the transcript the same way.
    @Query private var planRecords: [ActionPlanRecord]

    init(conversation: Conversation, engine: ChatEngine,
         mlxStore: MLXModelStore, endpointStore: EndpointStore,
         settings: AppSettings, fileScopeStore: FileScopeStore,
         permissionCenter: PermissionCenter,
         openRouterKeyStore: OpenRouterKeyStore,
         backendResolver: @escaping (ModelSelection) -> ResolvedBackend,
         onCompareContinue: @escaping (Conversation) -> Void,
         mcpServerStore: MCPServerStore, mcpManager: MCPServerManager,
         hudCoordinator: HUDCoordinator) {
        self.conversation = conversation
        self.engine = engine
        self.mlxStore = mlxStore
        self.endpointStore = endpointStore
        self.settings = settings
        self.fileScopeStore = fileScopeStore
        self.permissionCenter = permissionCenter
        self.openRouterKeyStore = openRouterKeyStore
        self.backendResolver = backendResolver
        self.onCompareContinue = onCompareContinue
        self.mcpServerStore = mcpServerStore
        self.mcpManager = mcpManager
        self.hudCoordinator = hudCoordinator
        let id = conversation.id
        _toolRecords = Query(
            filter: #Predicate<ToolActivityRecord> { $0.conversationID == id },
            sort: \ToolActivityRecord.createdAt)
        _planRecords = Query(
            filter: #Predicate<ActionPlanRecord> { $0.conversationID == id },
            sort: \ActionPlanRecord.createdAt)
    }

    @State private var input = ""
    @State private var showingInstructions = false
    @State private var showingModels = false
    @State private var showingSettings = false
    @State private var showingCompare = false
    @State private var showingFileImporter = false
    /// Phase 10: the "save these instructions as a set" draft name
    /// in the instructions sheet.
    @State private var presetNameDraft = ""
    /// Images staged in the composer, waiting to go with the next send.
    @State private var pendingAttachments: [ImageAttachment] = []
    /// Audit E-03: the thumbnail cache's identity for the composer
    /// strip (staged images have no message yet) — one stable id
    /// per chat view, reset whenever the strip empties so a later
    /// batch never shows an earlier batch's cached thumbnails.
    @State private var pendingStripID = UUID()
    /// Re-read on appear and after each send; the system state can change
    /// while the app is open (e.g. the model finishes downloading).
    @State private var availability: ModelAvailabilityState = .current

    private var conversationID: UUID { conversation.id }
    private var isResponding: Bool { engine.isResponding(conversationID) }
    private var canAttachMore: Bool {
        pendingAttachments.count < ImageAttachmentCodec.maxAttachmentsPerMessage
    }

    var body: some View {
        // Audit E-02: ONE sort and ONE transcript merge per body
        // pass, shared by everything below. The old shape re-sorted
        // the whole conversation and re-merged the transcript in
        // `contextMeterText`, `transcriptItems`, the empty check,
        // the onChange value, and the scroll target — and body
        // re-evaluates on EVERY streaming chunk, so a long chat paid
        // several full sorts per token.
        let sorted = conversation.sortedMessages
        let items = TranscriptBuilder.items(
            messages: sorted,
            summarizedCount: conversation.summarizedMessageCount,
            toolRecords: toolRecords, planRecords: planRecords)
        let allDescriptors = descriptors
        let currentDescriptor = allDescriptors.first {
            $0.selection == conversation.modelSelection
        }
        return VStack(spacing: 0) {
            header(descriptors: allDescriptors,
                   selectedDescriptor: currentDescriptor,
                   sortedMessages: sorted)
            if conversation.modelSelection.isAuto,
               let note = engine.routingNotes[conversationID] {
                routingNoteBar(note)
            }
            Divider()
            messageList(sortedMessages: sorted, items: items,
                        selectedDescriptor: currentDescriptor)
            if let error = engine.errorMessages[conversationID] {
                errorBanner(error)
            }
            if let info = engine.infoMessages[conversationID] {
                infoBanner(info)
            }
            if showsToolsNote {
                toolsNoteBanner
            }
            if showsAvailabilityBanner {
                availabilityBanner
            } else if currentDescriptor == nil {
                modelMissingBanner
            }
            if !engine.pendingPlan(for: conversationID).isEmpty {
                PendingPlanCard(
                    actions: engine.pendingPlan(for: conversationID),
                    busy: engine.planBusyIDs.contains(conversationID),
                    excludedIDs: engine.excludedPendingItems(
                        for: conversationID),
                    onToggleIncluded: { actionID, included in
                        engine.setPendingActionIncluded(
                            actionID, included: included,
                            conversationID: conversationID)
                    },
                    onRemove: { actionID in
                        engine.removePendingAction(actionID,
                                                   conversationID: conversationID)
                    },
                    onApprove: {
                        engine.approvePlan(conversationID: conversationID,
                                           context: modelContext)
                    },
                    onDiscard: {
                        engine.discardPlan(conversationID: conversationID,
                                           context: modelContext)
                    })
            }
            Divider()
            composer
        }
        .onAppear { availability = .current }
        .sheet(isPresented: $showingInstructions) {
            instructionsSheet
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: settings, fileScopeStore: fileScopeStore,
                         permissionCenter: permissionCenter,
                         openRouterKeyStore: openRouterKeyStore,
                         mcpServerStore: mcpServerStore,
                         mcpManager: mcpManager,
                         mlxStore: mlxStore, endpointStore: endpointStore,
                         hudCoordinator: hudCoordinator)
        }
        .sheet(isPresented: $showingCompare) {
            CompareView(descriptors: descriptors,
                        resolver: backendResolver,
                        onContinue: onCompareContinue,
                        endpoints: endpointStore.configs,
                        customRedactionTerms: settings.customRedactionTerms)
        }
        .sheet(isPresented: $showingModels) {
            ModelsView(mlxStore: mlxStore, endpointStore: endpointStore)
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                attachImages(fromFiles: urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imageURLs = urls.filter { $0.isFileURL }
            guard !imageURLs.isEmpty else { return false }
            // UAT-08: the drop only claims success for what it
            // actually staged — claiming it for files that all
            // failed to attach (or didn't fit) lied to the user
            // twice over, here and in the silent composer.
            return attachImages(fromFiles: imageURLs) > 0
        }
    }

    // MARK: - Header

    private func header(descriptors: [BackendDescriptor],
                          selectedDescriptor: BackendDescriptor?,
                          sortedMessages: [Message]) -> some View {
        HStack(spacing: 10) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(contextMeterText(
                sortedMessages: sortedMessages,
                window: selectedDescriptor?.budget.windowTokens))
                .font(.caption)
                .foregroundStyle(.secondary)
            modelPicker(descriptors: descriptors,
                        selectedDescriptor: selectedDescriptor)
            statusPill(selectedDescriptor: selectedDescriptor)
            if conversation.modelSelection.isCloud {
                cloudBadge
            }
            if settings.localOnly {
                lockBadge
            }
            Button {
                showingCompare = true
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help("Compare two models on one prompt, side by side")
            Menu {
                Button("Export as Markdown…") {
                    ConversationExporter.exportToFile(conversation)
                }
                Button("Copy as Markdown") {
                    ConversationExporter.copyToPasteboard(conversation)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export this chat as a Markdown file, or copy it as Markdown")
            Button {
                showingInstructions = true
            } label: {
                Image(systemName: "text.quote")
            }
            .buttonStyle(.borderless)
            .help("System instructions for this chat")
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (general, privacy, what this app can see)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Phase 8: this chat's model runs in the cloud — said out loud
    /// in the header, not just implied by the picker. (Auto chats
    /// don't wear it: their route changes per message, and each
    /// reply's pill names the backend that actually answered.)
    private var cloudBadge: some View {
        Label("Cloud", systemImage: "cloud")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .help("This chat's model runs in the cloud, not on this Mac. What you send passes the privacy check first — secrets and personal details are hidden before anything leaves. Pick a local model above to keep everything on this Mac.")
    }

    /// The Local Only lock, visible wherever a chat is open so the
    /// state is never a surprise.
    private var lockBadge: some View {
        Label("Local Only", systemImage: "lock.fill")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.15), in: Capsule())
            .help("Local Only is on: only models that run on this Mac may answer. Turn it off in Privacy settings (gear button).")
    }

    /// The latest Auto routing explanation, as a quiet caption under
    /// the header — routing should be visible, not magic.
    private func routingNoteBar(_ note: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
            Text(note)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: - Model picker (Phase 3)

    /// Every backend this chat could use right now: the built-in
    /// model, Apple Private Cloud, each downloaded MLX model, each
    /// configured local server, and the OpenRouter cloud models.
    private var descriptors: [BackendDescriptor] {
        BackendRegistry.descriptors(
            downloadedMLX: mlxStore.downloadedModels,
            endpoints: endpointStore.configs,
            onDeviceReady: availability.canChat,
            cloud: CloudPickerInputs(
                pccReady: PCCAvailabilityReader.isReady,
                openRouterKeyPresent: openRouterKeyStore.hasKey,
                customOpenRouterModelID: settings.openRouterCustomModelID))
    }

    /// Whether the selected backend can take a message right now. For
    /// the built-in model this is the Apple Intelligence state; a local
    /// server counts as ready when configured (whether it's running is
    /// only known at send time, and the error then says so).
    /// (Audit E-02: the descriptor itself is computed ONCE in
    /// `body` and passed down; this check recomputes the registry
    /// lookup only for the composer's enable state, off the render
    /// path of the transcript.)
    private var canChatWithSelection: Bool {
        descriptors.first {
            $0.selection == conversation.modelSelection
        }?.isReady ?? false
    }

    private func modelPicker(descriptors: [BackendDescriptor],
                             selectedDescriptor: BackendDescriptor?) -> some View {
        Menu {
            ForEach(descriptors) { descriptor in
                Button {
                    pickModel(descriptor.selection)
                } label: {
                    if descriptor.selection == conversation.modelSelection {
                        Label(descriptor.displayName, systemImage: "checkmark")
                    } else {
                        Text(descriptor.displayName)
                    }
                }
            }
            Divider()
            Button {
                showingModels = true
            } label: {
                Label("Manage Models…", systemImage: "cpu")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(selectedDescriptor?.displayName ?? "Choose a model")
                    .font(.callout)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which model this chat uses")
    }

    private func pickModel(_ selection: ModelSelection) {
        guard selection != conversation.modelSelection else { return }
        conversation.modelSelection = selection
        conversation.updatedAt = Date()
        try? modelContext.save()
    }

    /// Status pill for the selected backend: the Apple Intelligence
    /// state for the built-in model, the model's name for the others.
    private func statusPill(selectedDescriptor: BackendDescriptor?) -> some View {
        let onDevice = conversation.modelSelection.isOnDevice
        return HStack(spacing: 5) {
            Circle()
                .fill(canChatWithSelection ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(onDevice ? availability.headline
                         : (selectedDescriptor?.displayName ?? "Model unavailable"))
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .help(onDevice ? availability.explanation
                       : (selectedDescriptor?.detail ?? ""))
    }

    /// A rough "how full is the model's memory" meter. The estimate is
    /// approximate on purpose (see `PromptHistory`) and labeled as such;
    /// it counts the summary plus the live turns, which is what the
    /// model actually holds.
    private func contextMeterText(sortedMessages: [Message],
                                  window: Int?) -> String {
        let instructions = PromptHistory.mergedInstructions(
            userInstructions: conversation.systemInstructions)
        let all = sortedMessages
        let prefix = min(conversation.summarizedMessageCount, all.count)
        let turns = all.dropFirst(prefix).map { $0.chatTurn }
        var used = PromptHistory.estimatedContextTokens(
            instructions: instructions, turns: turns)
        if let summary = conversation.contextSummary {
            used += PromptHistory.approximateTokenCount(for: summary)
        }
        let window = window ?? ContextBudget.onDevice.windowTokens
        return "≈ \(used) / \(window) tokens"
    }

    // MARK: - Messages

    /// One row of the merged transcript: a message, a tool-lookup
    /// card, or the summarized divider. Phase 5 merges messages and
    /// tool records by time so a lookup appears exactly where it
    /// happened in the conversation. The divider keeps its Phase 2
    /// semantics — it belongs to the message sequence (tool records
    /// are not messages and never affect the compaction prefix), so
    /// it's placed by message position within the merged list.
    enum TranscriptItem: Identifiable {
        case message(Message)
        case tool(ToolActivityRecord)
        case plan(ActionPlanRecord)
        case divider

        var id: String {
            switch self {
            case .message(let message): return "message-\(message.id.uuidString)"
            case .tool(let record): return "tool-\(record.id.uuidString)"
            case .plan(let record): return "plan-\(record.id.uuidString)"
            case .divider: return "summarized-divider"
            }
        }

        /// When the item happened (the divider has no time of its
        /// own and sorts first among equals).
        var createdAt: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .tool(let record): return record.createdAt
            case .plan(let record): return record.createdAt
            case .divider: return .distantPast
            }
        }
    }

    /// Builds the merged transcript from ALREADY-SORTED messages
    /// (audit E-02): kept separate from the view so the merge logic
    /// is exercised by tests, and so `body` computes it exactly
    /// once per pass from the one sorted array it shares with the
    /// context meter, the empty check, and the scroll target.
    enum TranscriptBuilder {
        static func items(messages: [Message],
                          summarizedCount: Int,
                          toolRecords: [ToolActivityRecord],
                          planRecords: [ActionPlanRecord]) -> [TranscriptItem] {
            let summarized = summarizedCount
            // Tool cards and plan cards share one time-ordered stream of
            // non-message items; the divider stays placed by message
            // position, exactly as before.
            var events: [TranscriptItem] = toolRecords.map(TranscriptItem.tool)
            events += planRecords.map(TranscriptItem.plan)
            events.sort { $0.createdAt < $1.createdAt }
            var items: [TranscriptItem] = []
            var eventIndex = 0
            for (index, message) in messages.enumerated() {
                while eventIndex < events.count,
                      events[eventIndex].createdAt <= message.createdAt {
                    items.append(events[eventIndex])
                    eventIndex += 1
                }
                if index == summarized, summarized > 0 {
                    items.append(.divider)
                }
                items.append(.message(message))
            }
            if summarized > 0, summarized >= messages.count {
                items.append(.divider)
            }
            while eventIndex < events.count {
                items.append(events[eventIndex])
                eventIndex += 1
            }
            return items
        }
    }

    private func messageList(sortedMessages: [Message],
                             items: [TranscriptItem],
                             selectedDescriptor: BackendDescriptor?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if sortedMessages.isEmpty && !isResponding {
                        emptyState(selectedDescriptor: selectedDescriptor)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message)
                                .id(message.id)
                        case .tool(let record):
                            ToolActivityCard(record: record)
                        case .plan(let record):
                            ActionPlanCard(record: record, engine: engine)
                        case .divider:
                            SummarizedDivider()
                        }
                    }
                    if isResponding {
                        StreamingBubble(text: engine.streamingText[conversationID] ?? "")
                            .id("streaming")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: sortedMessages.count) {
                scrollToBottom(proxy, sortedMessages: sortedMessages)
            }
            .onChange(of: toolRecords.count) {
                scrollToBottom(proxy, sortedMessages: sortedMessages)
            }
            .onChange(of: planRecords.count) {
                scrollToBottom(proxy, sortedMessages: sortedMessages)
            }
            .onChange(of: engine.pendingPlan(for: conversationID).count) {
                scrollToBottom(proxy, sortedMessages: sortedMessages)
            }
            .onChange(of: engine.streamingText[conversationID]) {
                scrollToBottom(proxy, sortedMessages: sortedMessages)
            }
        }
    }

    private func emptyState(selectedDescriptor: BackendDescriptor?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ask anything")
                .font(.title3)
            Text(emptyStateText(selectedDescriptor: selectedDescriptor))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy,
                                sortedMessages: [Message]) {
        if isResponding {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let last = sortedMessages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .font(.callout)
            Spacer()
            Button {
                engine.errorMessages[conversationID] = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }

    private func emptyStateText(selectedDescriptor: BackendDescriptor?) -> String {
        if conversation.modelSelection.isAuto {
            return "This chat is on Auto: each message is sorted on your Mac and given to the best model for the job — the built-in model for quick things, a bigger downloaded model for hard ones, and a cloud model when a prompt really needs one and a cloud route is set up. The note under the header always says which model got each message."
        }
        if conversation.modelSelection.isOnDevice {
            return "This chat runs on the model built into your Mac. Nothing you type leaves the machine."
        }
        if conversation.modelSelection.isCloud {
            let name = selectedDescriptor?.displayName ?? "a cloud model"
            if conversation.modelSelection == .privateCloudCompute {
                return "This chat runs on \(name) — Apple's servers, under Apple's privacy design, at no charge. Before anything is sent, the privacy check hides secrets and personal details, and lookup results get the same check before they leave this Mac."
            }
            return "This chat runs on \(name) in the cloud. Before anything is sent, the privacy check hides secrets and personal details — and each reply's pill shows what it cost. Lookups on this Mac don't run in an OpenRouter chat."
        }
        let name = selectedDescriptor?.displayName ?? "a local model"
        return "This chat runs on \(name), on this Mac. Nothing you type leaves the machine."
    }

    /// The privacy-check notice — informational, not an error: the
    /// send worked; the user is being told what was hidden first.
    private func infoBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
            Text(message)
                .font(.callout)
            Spacer()
            Button {
                engine.infoMessages[conversationID] = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.blue.opacity(0.12))
    }

    /// Phase 5: the honest gap, stated where the user will see it —
    /// visibility sources are enabled, but this chat's model is a
    /// local server, and server chats can't make lookups this phase.
    /// Phase 8 adds the same gap for OpenRouter chats (Apple Private
    /// Cloud CAN make lookups — its results pass the privacy check
    /// first — so it never shows this note).
    ///
    /// UAT-06: the note judges the backend that actually answers,
    /// not the picker. For an Auto chat that's the engine's last
    /// routed selection — an Auto Mac-action prompt stood in by a
    /// server has no tools even though the picker says "Auto", and
    /// keying off the picker hid exactly that case. For a manual
    /// pick, the pick itself is the answer (nothing routes it).
    private var toolsNoteSelection: ModelSelection {
        if conversation.modelSelection.isAuto,
           let routed = engine.lastEffectiveSelections[conversationID] {
            return routed
        }
        return conversation.modelSelection
    }

    private var showsToolsNote: Bool {
        guard settings.anyVisibilitySourceEnabled else { return false }
        switch toolsNoteSelection {
        case .endpoint, .openRouter: return true
        case .auto, .onDevice, .mlx, .privateCloudCompute: return false
        }
    }

    private var toolsNoteBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye.slash")
            Text(toolsNoteText)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12))
    }

    private var toolsNoteText: String {
        if case .openRouter = toolsNoteSelection {
            return "Lookups are off for this chat: they work with the models that run on this Mac and with Apple Private Cloud — a cloud chat like this one can't look things up on your Mac."
        }
        return "Lookups are off for this chat: they work with the Apple On-Device model and downloaded MLX models for now — a server chat like this one can't look things up on your Mac."
    }

    /// When the Apple Intelligence banner matters: the built-in model
    /// is down AND this chat depends on it — an explicitly on-device
    /// chat always does; an Auto chat only when it has nothing else
    /// (no downloaded MLX model, no server configured, and no cloud
    /// route — Phase 8) to route to.
    private var showsAvailabilityBanner: Bool {
        guard !availability.canChat else { return false }
        if conversation.modelSelection.isOnDevice { return true }
        if conversation.modelSelection.isAuto {
            return mlxStore.downloadedModels.isEmpty
                && endpointStore.configs.isEmpty
                && !openRouterKeyStore.hasKey
                && !PCCAvailabilityReader.isReady
        }
        return false
    }

    private var modelMissingBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(SharedWording.modelUnavailableBanner)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }

    private var availabilityBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(availability.explanation)
                .font(.callout)
            Spacer()
            Button("Check Again") { availability = .current }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                pendingStrip
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showingFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!canAttachMore)
                .help(canAttachMore
                      ? "Attach images (up to \(ImageAttachmentCodec.maxAttachmentsPerMessage))"
                      : "Up to \(ImageAttachmentCodec.maxAttachmentsPerMessage) images per message")
                TextEditor(text: $input)
                    .font(.body)
                    .frame(minHeight: 24, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.3)))
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored // Shift+Return: newline, as usual.
                        }
                        send()
                        return .handled
                    }
                if isResponding {
                    Button(action: stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canChatWithSelection || !canSend)
                    .help("Send (Return)")
                }
            }
        }
        .padding(12)
        .onPasteCommand(of: [.image, .fileURL]) { _ in
            handlePaste()
        }
    }

    /// Staged images above the composer, each removable before sending.
    private var pendingStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                // Audit E-03: cached downscaled thumbnail, like the
                // transcript's — not a full decode per render.
                AttachmentThumbnailView(messageID: pendingStripID,
                                        index: index,
                                        data: attachment.data,
                                        side: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            pendingAttachments.remove(at: index)
                            if pendingAttachments.isEmpty {
                                pendingStripID = UUID()
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.borderless)
                        .offset(x: 5, y: -5)
                        .help("Remove image")
                    }
            }
            Spacer()
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingAttachments.isEmpty
    }

    private func send() {
        guard canChatWithSelection, !isResponding, canSend else { return }
        let text = input
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        pendingStripID = UUID()
        availability = .current
        engine.send(text: text, attachments: attachments,
                    in: conversation, context: modelContext)
    }

    private func stop() {
        engine.stop(conversationID: conversationID)
    }

    // MARK: - Attaching images

    /// What happened to one attach attempt (UAT-08) — the batch
    /// callers tally these so a failed or over-limit image is
    /// never just silently missing from the composer.
    private enum AttachOutcome {
        case added
        case unreadable
        case overLimit
    }

    /// Reads an image file (picker, drag-and-drop) and stages it,
    /// downscaled, in the composer.
    private func attachImage(fromFile url: URL) -> AttachOutcome {
        guard canAttachMore else { return .overLimit }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let prepared = ImagePreparer.prepare(data)
        else { return .unreadable }
        pendingAttachments.append(prepared)
        return .added
    }

    /// Attaches a batch of files (picker, drop, paste) and reports
    /// the outcome in the chat's info banner when anything didn't
    /// make it. Returns how many were staged.
    @discardableResult
    private func attachImages(fromFiles urls: [URL]) -> Int {
        var added = 0, unreadable = 0, overLimit = 0
        for url in urls {
            switch attachImage(fromFile: url) {
            case .added: added += 1
            case .unreadable: unreadable += 1
            case .overLimit: overLimit += 1
            }
        }
        reportAttachProblems(added: added, unreadable: unreadable,
                              overLimit: overLimit)
        return added
    }

    /// UAT-08: the visible half of attach failures — one plain
    /// sentence in the info banner naming how many images were
    /// read, and how many didn't fit. Silent when all attached.
    private func reportAttachProblems(added: Int, unreadable: Int,
                                      overLimit: Int) {
        guard unreadable > 0 || overLimit > 0 else { return }
        var problems: [String] = []
        if unreadable > 0 {
            problems.append(unreadable == 1
                ? "one image couldn't be read as an image"
                : "\(unreadable) images couldn't be read as images")
        }
        if overLimit > 0 {
            problems.append(overLimit == 1
                ? "one image didn't fit — up to "
                    + "\(ImageAttachmentCodec.maxAttachmentsPerMessage) per message"
                : "\(overLimit) images didn't fit — up to "
                    + "\(ImageAttachmentCodec.maxAttachmentsPerMessage) per message")
        }
        let joined = problems.joined(separator: "; ")
        engine.infoMessages[conversationID] = added > 0
            ? "\(added) of \(added + unreadable + overLimit) images "
                + "attached — \(joined)."
            : "Couldn't attach: \(joined)."
    }

    /// Stages whatever image a paste delivered. `onPasteCommand` fires
    /// while the content is on the general pasteboard, so it can simply
    /// be read synchronously: file URLs first (Finder copies), then raw
    /// image data (screenshots and copied pictures).
    private func handlePaste() {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: options) as? [URL],
           !urls.isEmpty {
            attachImages(fromFiles: urls.filter { $0.isFileURL })
            return
        }
        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            guard let data = pasteboard.data(forType: type),
                  let prepared = ImagePreparer.prepare(data)
            else { continue }
            // A readable image was pasted: stage it, or say why
            // not (UAT-08 — the cap used to swallow this silently).
            guard canAttachMore else {
                reportAttachProblems(added: 0, unreadable: 0,
                                     overLimit: 1)
                return
            }
            pendingAttachments.append(prepared)
            return
        }
        // UAT-08: image data was offered but none of it could be
        // prepared — say so instead of silently staging nothing.
        if [NSPasteboard.PasteboardType.tiff, .png].contains(
            where: { pasteboard.data(forType: $0) != nil }) {
            reportAttachProblems(added: 0, unreadable: 1, overLimit: 0)
        }
    }

    // MARK: - Instructions sheet

    private var instructionsSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System Instructions")
                .font(.headline)
            Text("Tell the model how to behave in this chat — for example, \u{201C}Answer like I'm a beginner\u{201D} or \u{201C}Be brief\u{201D}. Leave it empty to use the built-in default. Changing this starts a fresh session for the chat; the visible history stays.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $conversation.systemInstructions)
                .font(.body)
                .frame(minHeight: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.3)))
            // Phase 10: the instructions library — apply a saved
            // set (its text is copied in; the chat keeps its own
            // copy), or save this chat's instructions as a set.
            if !settings.instructionPresets.isEmpty {
                Menu("Use a saved instruction set…") {
                    ForEach(settings.instructionPresets) { preset in
                        Button(preset.name) {
                            conversation.systemInstructions = preset.text
                        }
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                TextField("Name for these instructions", text: $presetNameDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save as Instruction Set") { savePresetDraft() }
                    .disabled(!canSavePresetDraft)
            }
            Text("Saved sets live in Settings → Instructions library, where they can be edited or deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { showingInstructions = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private var canSavePresetDraft: Bool {
        InstructionPresetRules.canSave(
            name: presetNameDraft,
            text: conversation.systemInstructions,
            existing: settings.instructionPresets)
    }

    private func savePresetDraft() {
        settings.addInstructionPreset(
            name: presetNameDraft, text: conversation.systemInstructions)
        presetNameDraft = ""
    }
}
