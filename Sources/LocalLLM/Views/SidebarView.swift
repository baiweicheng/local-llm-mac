import SwiftUI
import SwiftData

/// The conversation list: newest first, with new / rename / delete.
/// Phase 10 adds the search field (title + message text, with a
/// matching snippet under the title) and Markdown export in the
/// context menu.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @Binding var selection: Conversation?
    let engine: ChatEngine
    /// Phase 10: the default model for new chats comes from here.
    let settings: AppSettings

    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var deleteTarget: Conversation?
    @State private var searchText = ""

    /// The trimmed search text; empty means "not searching".
    private var query: String { ChatSearch.normalizedQuery(searchText) }

    /// The chats to show: every chat when not searching, otherwise
    /// only the ones that match (the match proof is recomputed per
    /// row by `hit(for:)` — cheap at sidebar scale).
    private var visibleConversations: [Conversation] {
        guard !query.isEmpty else { return conversations }
        return conversations.filter { hit(for: $0) != nil }
    }

    /// This chat's search hit under the current query (nil when not
    /// searching or not matching).
    private func hit(for conversation: Conversation) -> ChatSearchHit? {
        guard !query.isEmpty else { return nil }
        return ChatSearch.hit(
            title: conversation.title,
            messageTexts: conversation.sortedMessages.map(\.text),
            query: query)
    }

    var body: some View {
        List(selection: $selection) {
            if !query.isEmpty, visibleConversations.isEmpty {
                Text("No chats match \u{201C}\(query)\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleConversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    if let snippet = hit(for: conversation)?.snippet {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(conversation)
                .contextMenu {
                    Button("Rename…") {
                        renameText = conversation.title
                        renameTarget = conversation
                    }
                    Button("Export as Markdown…") {
                        ConversationExporter.exportToFile(conversation)
                    }
                    Button("Copy as Markdown") {
                        ConversationExporter.copyToPasteboard(conversation)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        deleteTarget = conversation
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar,
                    prompt: "Search chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New chat (⌘N)")
            }
        }
        .alert("Rename Chat", isPresented: renameBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        target.title = trimmed
                        target.updatedAt = Date()
                        try? modelContext.save()
                    }
                }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                if let target = deleteTarget {
                    delete(target)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The conversation and all its messages will be removed from this Mac. This can't be undone.")
        }
    }

    // `alert`/`confirmationDialog` want a Bool binding; these adapt the
    // optional targets above.
    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    private func newChat() {
        let conversation = Conversation()
        // Phase 10: new chats start on the user's default model
        // (Auto unless they picked a specific one in Settings).
        // `Conversation()` itself defaults to Auto; the setting is
        // applied here, at the one place a user starts a chat.
        conversation.modelSelection = settings.defaultModelSelection
        modelContext.insert(conversation)
        try? modelContext.save()
        selection = conversation
    }

    private func delete(_ conversation: Conversation) {
        engine.forget(conversationID: conversation.id)
        if selection?.id == conversation.id {
            selection = nil
        }
        // Audit S-05: the conversation's tool-activity and plan
        // records are standalone models keyed by conversation id —
        // they do NOT cascade with the conversation, so delete them
        // in the same save, or a "deleted" chat's lookups, commands,
        // and server answers stay behind in the access log.
        let id = conversation.id
        let toolRecords = FetchDescriptor<ToolActivityRecord>(
            predicate: #Predicate { $0.conversationID == id })
        for record in (try? modelContext.fetch(toolRecords)) ?? [] {
            modelContext.delete(record)
        }
        let planRecords = FetchDescriptor<ActionPlanRecord>(
            predicate: #Predicate { $0.conversationID == id })
        for record in (try? modelContext.fetch(planRecords)) ?? [] {
            modelContext.delete(record)
        }
        modelContext.delete(conversation)
        try? modelContext.save()
    }
}
