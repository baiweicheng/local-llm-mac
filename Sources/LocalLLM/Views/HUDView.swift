import SwiftData
import SwiftUI

/// Phase 7: the quick panel's content.
///
/// The root (`HUDPanelRoot`) is what the coordinator's `NSPanel`
/// hosts; it rebinds to the coordinator's current conversation. The
/// conversation view below it is a compact chat: the same messages,
/// tool cards, decided-plan cards, and telemetry pills as the main
/// window — the same `ChatEngine` pipeline (Auto routing, tools,
/// compaction), never a second-class copy.
///
/// The one deliberate difference from `ChatView`: **approvals**.
/// When a conversation has proposed file changes waiting, the panel
/// shows a notice card and an Open button — the Approve/Discard card
/// exists only in the main window, so a file change can never be
/// approved from a transient panel by reflex. Read-only lookups run
/// here exactly as they do in the window, and cards for plans that
/// were already decided (including their artifact chips) render as
/// usual — minus the Undo button, for the same reason.
struct HUDPanelRoot: View {
    let coordinator: HUDCoordinator

    var body: some View {
        Group {
            if let conversation = coordinator.currentConversation,
               let engine = coordinator.engine {
                HUDConversationView(conversation: conversation,
                                    engine: engine,
                                    coordinator: coordinator)
                    .id(conversation.id)
            } else {
                Color.clear
            }
        }
        .frame(width: 680, height: 540)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct HUDConversationView: View {
    @Bindable var conversation: Conversation
    let engine: ChatEngine
    let coordinator: HUDCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Query private var toolRecords: [ToolActivityRecord]
    @Query private var planRecords: [ActionPlanRecord]

    init(conversation: Conversation, engine: ChatEngine,
         coordinator: HUDCoordinator) {
        self.conversation = conversation
        self.engine = engine
        self.coordinator = coordinator
        let id = conversation.id
        _toolRecords = Query(
            filter: #Predicate<ToolActivityRecord> { $0.conversationID == id },
            sort: \ToolActivityRecord.createdAt)
        _planRecords = Query(
            filter: #Predicate<ActionPlanRecord> { $0.conversationID == id },
            sort: \ActionPlanRecord.createdAt)
    }

    @State private var input = ""
    @FocusState private var composerFocused: Bool

    private var conversationID: UUID { conversation.id }
    private var isResponding: Bool { engine.isResponding(conversationID) }
    private var pendingActions: [PlannedAction] {
        engine.pendingPlan(for: conversationID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !coordinator.contextSnapshot.chips.isEmpty {
                chipsRow
            }
            Divider()
            transcript
            if let error = engine.errorMessages[conversationID] {
                compactBanner(text: error, symbol: "exclamationmark.triangle",
                              color: .orange) {
                    engine.errorMessages[conversationID] = nil
                }
            }
            if let info = engine.infoMessages[conversationID] {
                compactBanner(text: info, symbol: "lock.shield",
                              color: .blue) {
                    engine.infoMessages[conversationID] = nil
                }
            }
            if !pendingActions.isEmpty {
                approvalDeferralCard
            }
            Divider()
            composer
        }
        // Esc dismisses from anywhere in the panel; the hidden
        // cancel-action button below is the belt to this suspender
        // (key presses can be swallowed by the text field first).
        .onKeyPress(.escape) {
            coordinator.dismiss()
            return .handled
        }
        .background {
            Button("") { coordinator.dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: coordinator.summonGeneration) {
            composerFocused = true
        }
        .onAppear { composerFocused = true }
    }

    // MARK: - Header & chips

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.secondary)
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                openInMainWindow()
            } label: {
                Label("Open in main window", systemImage: "macwindow")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Continue this conversation in the main window (⌘Return)")
            Button {
                coordinator.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the quick panel (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// What the panel captured when it opened, as small pills — the
    /// user sees exactly what context the model will be given.
    private var chipsRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(coordinator.contextSnapshot.chips.enumerated()),
                    id: \.offset) { _, chip in
                Label(chip.text, systemImage: chip.symbolName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .help(chip.helpText)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Transcript (compact)

    /// Messages, tool cards, and decided-plan cards in one time
    /// order — the same sources ChatView merges, kept simpler here
    /// (the panel is a quick surface; the summarized divider stays a
    /// main-window nicety).
    private enum Row: Identifiable {
        case message(Message)
        case tool(ToolActivityRecord)
        case plan(ActionPlanRecord)

        var id: String {
            switch self {
            case .message(let message): return "m-\(message.id.uuidString)"
            case .tool(let record): return "t-\(record.id.uuidString)"
            case .plan(let record): return "p-\(record.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .tool(let record): return record.createdAt
            case .plan(let record): return record.createdAt
            }
        }
    }

    private var rows: [Row] {
        var all: [Row] = conversation.sortedMessages.map(Row.message)
        all += toolRecords.map(Row.tool)
        all += planRecords.map(Row.plan)
        return all.sorted { $0.createdAt < $1.createdAt }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if conversation.sortedMessages.isEmpty && !isResponding {
                        VStack(spacing: 6) {
                            Text("Ask anything — this uses the same models and lookups as the main window, and the chat is saved in the sidebar like any other.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .message(let message):
                            MessageBubble(message: message)
                                .id(message.id)
                        case .tool(let record):
                            ToolActivityCard(record: record)
                        case .plan(let record):
                            // No Undo from the panel — reversing a
                            // file change is a main-window decision,
                            // like approving one.
                            ActionPlanCard(record: record, engine: engine,
                                           showsUndoButton: false)
                        }
                    }
                    if isResponding {
                        StreamingBubble(
                            text: engine.streamingText[conversationID] ?? "")
                            .id("streaming")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.sortedMessages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: engine.streamingText[conversationID]) {
                scrollToBottom(proxy)
            }
            .onChange(of: coordinator.summonGeneration) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if isResponding {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let last = conversation.sortedMessages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Approval deferral

    /// A pending approval list, shown WITHOUT an Approve button:
    /// the items are listed so the user knows they're waiting, and
    /// the only action offered is opening the main window, where
    /// the real approval card lives. Phase 9: the same deferral
    /// covers proposed commands and MCP calls — including the
    /// warning marker on a flagged command, so the danger is
    /// visible here even though the decision happens there.
    private var approvalDeferralCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .foregroundStyle(.orange)
                Text(pendingActions.count == 1
                     ? "1 proposed action needs your approval in the main window"
                     : "\(pendingActions.count) proposed actions need your approval in the main window")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
            }
            ForEach(pendingActions) { action in
                Text(action.requiresExplicitOptIn
                     ? "• ⚠ \(action.summary)"
                     : "• \(action.summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Nothing has changed or run yet — approving always happens in the main window, never from this panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open") { openInMainWindow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask, or tell it what to do…", text: $input,
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...4)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.3)))
                .focused($composerFocused)
                .onKeyPress(.return) { press in
                    if press.modifiers.contains(.command) {
                        openInMainWindow()
                        return .handled
                    }
                    if press.modifiers.contains(.shift) {
                        return .ignored // Shift+Return: newline.
                    }
                    send()
                    return .handled
                }
            if isResponding {
                Button {
                    engine.stop(conversationID: conversationID)
                } label: {
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
                .disabled(input.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return)")
            }
        }
        .padding(12)
    }

    private func compactBanner(text: String, symbol: String,
                               color: Color,
                               dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
            Text(text)
                .font(.callout)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(color.opacity(0.13))
    }

    // MARK: - Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        // A fresh HUD conversation gets its "Quick — …" title from
        // its first prompt (the engine's own auto-title only fires
        // for the untouched placeholder, which this replaces).
        if conversation.sortedMessages.isEmpty {
            conversation.title = HUDConversationNaming.title(
                forFirstPrompt: text)
            conversation.updatedAt = Date()
            try? modelContext.save()
        }
        // The captured context rides as a prompt prefix: part of the
        // sent copy only (the stored message stays exactly what was
        // typed), scrubbed by the privacy check like everything else
        // if the chat ever points off this Mac.
        engine.send(text: text, in: conversation, context: modelContext,
                    promptPrefix: coordinator.contextSnapshot
                        .promptContextText())
    }

    private func openInMainWindow() {
        coordinator.requestOpenInMainWindow()
        openWindow(id: "main")
    }
}
