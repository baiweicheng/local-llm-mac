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
         permissionCenter: PermissionCenter) {
        self.conversation = conversation
        self.engine = engine
        self.mlxStore = mlxStore
        self.endpointStore = endpointStore
        self.settings = settings
        self.fileScopeStore = fileScopeStore
        self.permissionCenter = permissionCenter
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
    @State private var showingFileImporter = false
    /// Images staged in the composer, waiting to go with the next send.
    @State private var pendingAttachments: [ImageAttachment] = []
    /// Re-read on appear and after each send; the system state can change
    /// while the app is open (e.g. the model finishes downloading).
    @State private var availability: ModelAvailabilityState = .current

    private var conversationID: UUID { conversation.id }
    private var isResponding: Bool { engine.isResponding(conversationID) }
    private var canAttachMore: Bool {
        pendingAttachments.count < ImageAttachmentCodec.maxAttachmentsPerMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if conversation.modelSelection.isAuto,
               let note = engine.routingNotes[conversationID] {
                routingNoteBar(note)
            }
            Divider()
            messageList
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
            } else if selectedDescriptor == nil {
                modelMissingBanner
            }
            if !engine.pendingPlan(for: conversationID).isEmpty {
                PendingPlanCard(
                    actions: engine.pendingPlan(for: conversationID),
                    busy: engine.planBusyIDs.contains(conversationID),
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
                         permissionCenter: permissionCenter)
        }
        .sheet(isPresented: $showingModels) {
            ModelsView(mlxStore: mlxStore, endpointStore: endpointStore)
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { attachImage(fromFile: url) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imageURLs = urls.filter { $0.isFileURL }
            guard !imageURLs.isEmpty else { return false }
            for url in imageURLs { attachImage(fromFile: url) }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(contextMeterText)
                .font(.caption)
                .foregroundStyle(.secondary)
            modelPicker
            statusPill
            if settings.localOnly {
                lockBadge
            }
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
            .help("Settings (privacy, what this app can see)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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

    /// Every backend this chat could use right now: the built-in model,
    /// each downloaded MLX model, and each configured local server.
    private var descriptors: [BackendDescriptor] {
        BackendRegistry.descriptors(
            downloadedMLX: mlxStore.downloadedModels,
            endpoints: endpointStore.configs,
            onDeviceReady: availability.canChat)
    }

    /// The row for this chat's current selection — nil when the model
    /// it points at was deleted or removed.
    private var selectedDescriptor: BackendDescriptor? {
        descriptors.first { $0.selection == conversation.modelSelection }
    }

    /// Whether the selected backend can take a message right now. For
    /// the built-in model this is the Apple Intelligence state; a local
    /// server counts as ready when configured (whether it's running is
    /// only known at send time, and the error then says so).
    private var canChatWithSelection: Bool {
        selectedDescriptor?.isReady ?? false
    }

    private var modelPicker: some View {
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
    private var statusPill: some View {
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
    private var contextMeterText: String {
        let instructions = PromptHistory.mergedInstructions(
            userInstructions: conversation.systemInstructions)
        let all = conversation.sortedMessages
        let prefix = min(conversation.summarizedMessageCount, all.count)
        let turns = all.dropFirst(prefix).map { $0.chatTurn }
        var used = PromptHistory.estimatedContextTokens(
            instructions: instructions, turns: turns)
        if let summary = conversation.contextSummary {
            used += PromptHistory.approximateTokenCount(for: summary)
        }
        let window = selectedDescriptor?.budget.windowTokens
            ?? ContextBudget.onDevice.windowTokens
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
    private enum TranscriptItem: Identifiable {
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

    private var transcriptItems: [TranscriptItem] {
        let messages = conversation.sortedMessages
        let summarized = conversation.summarizedMessageCount
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.sortedMessages.isEmpty && !isResponding {
                        emptyState
                    }
                    ForEach(transcriptItems) { item in
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
            .onChange(of: conversation.sortedMessages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: toolRecords.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: planRecords.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: engine.pendingPlan(for: conversationID).count) {
                scrollToBottom(proxy)
            }
            .onChange(of: engine.streamingText[conversationID]) {
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ask anything")
                .font(.title3)
            Text(emptyStateText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if isResponding {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let last = conversation.sortedMessages.last {
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

    private var emptyStateText: String {
        if conversation.modelSelection.isAuto {
            return "This chat is on Auto: each message is sorted on your Mac and given to the best local model for the job — the built-in model for quick things, a bigger downloaded model for hard ones. Nothing you type leaves the machine."
        }
        if conversation.modelSelection.isOnDevice {
            return "This chat runs on the model built into your Mac. Nothing you type leaves the machine."
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
    private var showsToolsNote: Bool {
        guard settings.anyVisibilitySourceEnabled else { return false }
        if case .endpoint = conversation.modelSelection { return true }
        return false
    }

    private var toolsNoteBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye.slash")
            Text("Lookups are off for this chat: they work with the Apple On-Device model and downloaded MLX models for now — a server chat like this one can't look things up on your Mac.")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12))
    }

    /// When the Apple Intelligence banner matters: the built-in model
    /// is down AND this chat depends on it — an explicitly on-device
    /// chat always does; an Auto chat only when it has nothing else
    /// (no downloaded MLX model and no server configured) to route to.
    private var showsAvailabilityBanner: Bool {
        guard !availability.canChat else { return false }
        if conversation.modelSelection.isOnDevice { return true }
        if conversation.modelSelection.isAuto {
            return mlxStore.downloadedModels.isEmpty
                && endpointStore.configs.isEmpty
        }
        return false
    }

    private var modelMissingBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text("The model this chat was using isn't available anymore — it was deleted or removed. Pick a model in the header to keep chatting.")
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
                    .onKeyPress(.return) { press in
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
                if let image = NSImage(data: attachment.data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                pendingAttachments.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.borderless)
                            .offset(x: 5, y: -5)
                            .help("Remove image")
                        }
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
        availability = .current
        engine.send(text: text, attachments: attachments,
                    in: conversation, context: modelContext)
    }

    private func stop() {
        engine.stop(conversationID: conversationID)
    }

    // MARK: - Attaching images

    /// Reads an image file (picker, drag-and-drop) and stages it,
    /// downscaled, in the composer.
    private func attachImage(fromFile url: URL) {
        guard canAttachMore else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let prepared = ImagePreparer.prepare(data) else { return }
        pendingAttachments.append(prepared)
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
            for url in urls where url.isFileURL {
                attachImage(fromFile: url)
            }
            return
        }
        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = pasteboard.data(forType: type),
               let prepared = ImagePreparer.prepare(data) {
                if canAttachMore { pendingAttachments.append(prepared) }
                return
            }
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
            HStack {
                Spacer()
                Button("Done") { showingInstructions = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
