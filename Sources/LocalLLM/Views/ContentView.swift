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
///
/// Phase 4: it also owns the privacy settings and wires the engine's
/// routing context (what's downloaded/configured, the Local Only
/// lock, the custom redaction terms) from the same live sources, so
/// routing and the factory never disagree about the world.
///
/// Phase 5: it also owns the visibility stores — the shared-folder
/// scope and the permission center — and wires the engine's tool
/// availability from the same live settings, so what a session may
/// look at is always what the Settings panel shows.
///
/// Phase 7: it also configures the quick-panel coordinator (owned
/// by the app as its delegate) with the same live objects, and takes
/// "open this conversation" requests from it — both the live
/// callback and the pending slot it drains on appear, which covers
/// the main window having been closed when Open was pressed.
struct ContentView: View {
    @State private var engine = ChatEngine()
    @State private var mlxStore = MLXModelStore()
    @State private var endpointStore = EndpointStore()
    @State private var settings = AppSettings()
    @State private var fileScopeStore = FileScopeStore()
    @State private var permissionCenter = PermissionCenter()
    @State private var selection: Conversation?
    let hudCoordinator: HUDCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, engine: engine)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let conversation = selection {
                ChatView(conversation: conversation, engine: engine,
                         mlxStore: mlxStore, endpointStore: endpointStore,
                         settings: settings, fileScopeStore: fileScopeStore,
                         permissionCenter: permissionCenter)
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
                    endpoints: endpointStore.configs,
                    localOnly: settings.localOnly,
                    kvCacheMode: settings.kvCacheMode)
            }
            engine.configureRoutingContextProvider {
                RoutingInputs(
                    downloadedMLX: mlxStore.downloadedModels,
                    endpoints: endpointStore.configs,
                    localOnly: settings.localOnly,
                    cloudAvailable: false, // Phase 8 brings cloud backends
                    onDeviceReady: ModelAvailabilityState.current.canChat,
                    customRedactionTerms: settings.customRedactionTerms,
                    kvCacheMode: settings.kvCacheMode)
            }
            engine.configureToolAvailabilityProvider {
                ToolAvailability(
                    enabledSources: settings.enabledVisibilitySources,
                    folderRootPaths: fileScopeStore.rootPaths,
                    fileWritingEnabled: settings.fileWritingEnabled)
            }
            hudCoordinator.configure(
                engine: engine,
                settings: settings,
                container: modelContext.container,
                onOpenConversation: { conversationID in
                    // Front (or recreate) the main window, then land
                    // on the conversation — this is the path that
                    // owns a real scene `openWindow`, so it works
                    // even when the window was closed.
                    openWindow(id: "main")
                    selectConversation(id: conversationID)
                })
            if let pending = hudCoordinator.consumePendingOpenConversationID() {
                selectConversation(id: pending)
            }
        }
    }

    /// Selects a conversation in the sidebar by id — the quick
    /// panel's "open in the main window" lands here.
    private func selectConversation(id: UUID) {
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id })
        if let conversation = try? modelContext.fetch(descriptor).first {
            selection = conversation
        }
    }
}
