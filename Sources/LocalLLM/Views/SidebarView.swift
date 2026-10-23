import SwiftUI
import SwiftData

/// The conversation list: newest first, with new / rename / delete.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @Binding var selection: Conversation?
    let engine: ChatEngine

    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var deleteTarget: Conversation?

    var body: some View {
        List(selection: $selection) {
            ForEach(conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conversation)
                .contextMenu {
                    Button("Rename…") {
                        renameText = conversation.title
                        renameTarget = conversation
                    }
                    Button("Delete", role: .destructive) {
                        deleteTarget = conversation
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        modelContext.insert(conversation)
        try? modelContext.save()
        selection = conversation
    }

    private func delete(_ conversation: Conversation) {
        engine.forget(conversationID: conversation.id)
        if selection?.id == conversation.id {
            selection = nil
        }
        modelContext.delete(conversation)
        try? modelContext.save()
    }
}
