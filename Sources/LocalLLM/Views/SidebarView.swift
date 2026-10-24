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

    /// Audit E-01: search hits are computed ONCE per (query, corpus
    /// fingerprint) and cached here. The old shape recomputed the
    /// full-corpus scan at least three times per keystroke — the
    /// `visibleConversations` filter, the empty check, and once
    /// more per row for its snippet — each hit re-sorting and
    /// re-scanning every message of every conversation.
    @State private var cachedHits: [UUID: ChatSearchHit] = [:]
    @State private var cachedHitKey: SearchCacheKey?

    /// What identifies a valid hit cache: the query plus a cheap
    /// fingerprint of the corpus (conversation count and the
    /// newest `updatedAt` — any send, rename, or delete moves it).
    private struct SearchCacheKey: Equatable {
        let query: String
        let count: Int
        let latestUpdate: Date?
    }

    /// The trimmed search text; empty means "not searching".
    private var query: String { ChatSearch.normalizedQuery(searchText) }

    private var currentKey: SearchCacheKey {
        SearchCacheKey(query: query,
                       count: conversations.count,
                       latestUpdate: conversations.map(\.updatedAt).max())
    }

    /// The cached hits for the current key, recomputing (once)
    /// when the key has moved.
    private func hits() -> [UUID: ChatSearchHit] {
        guard !query.isEmpty else { return [:] }
        if cachedHitKey == currentKey { return cachedHits }
        let computed = ChatSearch.hits(
            in: conversations.map {
                (id: $0.id, title: $0.title,
                 messageTexts: $0.sortedMessages.map(\.text))
            },
            query: query)
        // We're inside a view computation; the writes land in the
        // next update cycle (the values returned THIS pass are the
        // freshly computed ones, so nothing renders stale).
        DispatchQueue.main.async {
            cachedHits = computed
            cachedHitKey = currentKey
        }
        return computed
    }

    var body: some View {
        // Audit E-01: one hits computation per body pass, shared by
        // the empty check, the filter, and every row's snippet.
        let found = query.isEmpty ? [:] : hits()
        let visible = query.isEmpty
            ? conversations
            : conversations.filter { found[$0.id] != nil }
        return List(selection: $selection) {
            if !query.isEmpty, visible.isEmpty {
                Text("No chats match \u{201C}\(query)\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(visible) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    if let snippet = found[conversation.id]?.snippet {
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
            // Audit E-05: the record's on-disk backup folder goes
            // with it — the records were the only thing that could
            // ever reach those backups.
            ChatEngine.deleteBackupFolder(forRecordID: record.id)
            modelContext.delete(record)
        }
        // The direct deletions above bypass the engine's rotation
        // bookkeeping; keep its in-memory log count honest (E-10).
        ChatEngine.resetActivityCount(for: modelContext.container)
        modelContext.delete(conversation)
        try? modelContext.save()
    }
}
