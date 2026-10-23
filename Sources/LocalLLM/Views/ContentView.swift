import SwiftUI
import SwiftData

/// The main window: conversation sidebar on the left, chat pane on the
/// right. The shared `ChatEngine` lives here so streams keep running (and
/// stay visible) when the selection changes.
struct ContentView: View {
    @State private var engine = ChatEngine()
    @State private var selection: Conversation?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, engine: engine)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let conversation = selection {
                ChatView(conversation: conversation, engine: engine)
                    .id(conversation.id)
            } else {
                ContentUnavailableView(
                    "No Chat Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a chat on the left, or press ⌘N to start a new one.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
