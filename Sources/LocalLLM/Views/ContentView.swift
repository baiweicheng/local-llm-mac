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
///
/// Phase 8: it also owns the OpenRouter key store (the Keychain —
/// the shell reads the key value in exactly one place, the backend
/// resolver below, and hands it to the factory) and wires the
/// cloud facts into routing: whether a key exists (never the key)
/// and whether Private Cloud Compute is offered right now. The
/// same resolver serves the engine and compare mode, so both
/// resolve selections identically.
///
/// Phase 9: it also owns the MCP server store and manager, and
/// wires the power tools into the engine three ways: the tool
/// availability (the master switch + the discovered-tool
/// signature), the tools provider a session build fetches (the one
/// moment servers launch), and the executor an approved MCP plan
/// item runs through.
///
/// Phase 10: the same `settings` object now also carries the
/// default model for new chats and the instructions library; the
/// sidebar reads the default when it creates a chat, and the
/// Settings sheet it opens manages both.
struct ContentView: View {
    @State private var engine = ChatEngine()
    @State private var mlxStore = MLXModelStore()
    @State private var endpointStore = EndpointStore()
    @State private var settings = AppSettings()
    @State private var fileScopeStore = FileScopeStore()
    @State private var permissionCenter = PermissionCenter()
    @State private var openRouterKeyStore = OpenRouterKeyStore()
    @State private var mcpServerStore = MCPServerStore()
    @State private var mcpManager = MCPServerManager()
    @State private var selection: Conversation?
    let hudCoordinator: HUDCoordinator
    /// Review finding 10: true when the app fell back to an
    /// in-memory store because the persistent store failed to
    /// open. Drives the visible banner below and gates the
    /// backup sweep in `onAppear` — the sweep must never run
    /// against an empty in-memory store.
    let persistentStoreFailed: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    /// The one backend-resolution path: a stored selection plus the
    /// live world (downloads, servers, the lock, the KV mode, the
    /// Keychain key) → a live backend.
    private func resolveBackend(_ selection: ModelSelection) -> ResolvedBackend {
        BackendFactory.resolve(
            selection: selection,
            downloadedMLXRepoIDs: mlxStore.downloadedRepoIDs,
            endpoints: endpointStore.configs,
            localOnly: settings.localOnly,
            kvCacheMode: settings.kvCacheMode,
            openRouterAPIKey: openRouterKeyStore.currentKey())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Review finding 10: the store failure is visible,
            // not silent — the user must know this session's
            // chats won't survive a quit, and that nothing old
            // was deleted to make room.
            if persistentStoreFailed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Your saved chats couldn't be opened, so chats in this session won't be saved when you quit. Your earlier chats and undo backups have been left untouched — nothing was deleted.")
                        .font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.25))
            }
            NavigationSplitView {
                SidebarView(selection: $selection, engine: engine,
                            settings: settings)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let conversation = selection {
                ChatView(conversation: conversation, engine: engine,
                         mlxStore: mlxStore, endpointStore: endpointStore,
                         settings: settings, fileScopeStore: fileScopeStore,
                         permissionCenter: permissionCenter,
                         openRouterKeyStore: openRouterKeyStore,
                         backendResolver: resolveBackend,
                         onCompareContinue: { conversation in
                             selection = conversation
                         },
                         mcpServerStore: mcpServerStore,
                         mcpManager: mcpManager,
                         hudCoordinator: hudCoordinator)
                    .id(conversation.id)
            } else {
                ContentUnavailableView(
                    "No Chat Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a chat on the left, or press ⌘N to start a new one.")
                )
            }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        // Review finding 8: observe the two switches CENTRALLY,
        // here in the shell that owns the manager — every toggle
        // in Settings writes the same shared `settings` object, so
        // these fire whichever control flipped. Turning Local Only
        // on, or the power-tools master switch off, TERMINATES
        // servers already running; the launch gates (discovery
        // refuses under the lock, sessions retire on the switch)
        // only ever stopped NEW servers, leaving live ones able to
        // continue their own network activity.
        .onChange(of: settings.localOnly) {
            mcpManager.stopServersWhenPowerUnavailable(
                localOnly: settings.localOnly,
                powerToolsEnabled: settings.powerToolsEnabled)
        }
        .onChange(of: settings.powerToolsEnabled) {
            mcpManager.stopServersWhenPowerUnavailable(
                localOnly: settings.localOnly,
                powerToolsEnabled: settings.powerToolsEnabled)
        }
        .onAppear {
            // Audit E-05: prune backup folders whose plan records
            // are gone (or no longer undoable) — once per launch.
            // Review finding 10: NEVER against a fallback
            // in-memory store — its empty record set would mark
            // every real backup folder orphaned. (The engine's
            // prune re-checks this itself, so even a caller that
            // forgot the gate can't sweep an in-memory store.)
            if !persistentStoreFailed {
                engine.pruneOrphanedActionBackups(context: modelContext)
            }
            engine.configureBackendProvider { selection in
                resolveBackend(selection)
            }
            engine.configureRoutingContextProvider {
                RoutingInputs(
                    downloadedMLX: mlxStore.downloadedModels,
                    endpoints: endpointStore.configs,
                    localOnly: settings.localOnly,
                    // Phase 8: routing learns THAT a key exists and
                    // whether PCC is offered — never the key itself.
                    openRouterKeyPresent: openRouterKeyStore.hasKey,
                    pccReady: PCCAvailabilityReader.isReady,
                    onDeviceReady: ModelAvailabilityState.current.canChat,
                    customRedactionTerms: settings.customRedactionTerms,
                    kvCacheMode: settings.kvCacheMode)
            }
            engine.configureToolAvailabilityProvider {
                ToolAvailability(
                    enabledSources: settings.enabledVisibilitySources,
                    folderRootPaths: fileScopeStore.rootPaths,
                    fileWritingEnabled: settings.fileWritingEnabled,
                    powerToolsEnabled: settings.powerToolsEnabled,
                    mcpToolsSignature: mcpManager.toolSignature,
                    // Audit S-06: the lock rides along, so power
                    // tools vanish (and plan execution refuses them)
                    // while it's on. Audit S-13: the redaction terms
                    // ride along by hash (in the signature), so a
                    // term added mid-conversation retires live
                    // sessions and rebuilds their tool runtimes.
                    localOnly: settings.localOnly,
                    customRedactionTerms: settings.customRedactionTerms)
            }
            mcpManager.configure { mcpServerStore.configs }
            engine.configureMCPToolsProvider {
                // Audit S-06: under Local Only, discovery doesn't
                // run at all — servers don't even launch.
                guard !settings.localOnly else { return [] }
                return await mcpManager.availableTools()
            }
            engine.configureMCPExecutorProvider { action in
                await mcpManager.executeApprovedCall(action)
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
