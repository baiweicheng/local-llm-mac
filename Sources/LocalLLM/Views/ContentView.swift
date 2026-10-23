import SwiftUI
import SwiftData

/// The main window: conversation sidebar on the left, chat pane on the
/// right. The shared `ChatEngine` lives here so streams keep running (and
/// stay visible) when the selection changes.
///
/// Phase 3: this shell also owns the model stores — the MLX download
/// manager and the saved local servers — and wires them into the
/// engine as its backend provider, so a chat's picker choice resolves
/// against what's actually downloaded and configured right now.
struct ContentView: View {
    @State private var engine = ChatEngine()
    @State private var mlxStore = MLXModelStore()
    @State private var endpointStore = EndpointStore()
    @State private var selection: Conversation?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, engine: engine)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let conversation = selection {
                ChatView(conversation: conversation, engine: engine,
                         mlxStore: mlxStore, endpointStore: endpointStore)
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
        .onAppear {
            engine.configureBackendProvider { selection in
                BackendFactory.resolve(
                    selection: selection,
                    downloadedMLXRepoIDs: mlxStore.downloadedRepoIDs,
                    endpoints: endpointStore.configs)
            }
        }
    }
}
