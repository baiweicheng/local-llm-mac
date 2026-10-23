import SwiftUI
import SwiftData

/// App entry point.
///
/// "LocalLLM" is a placeholder name — the real name comes later; renaming
/// it touches this file, Package.swift, and the sidebar's empty-state text.
@main
struct LocalLLMApp: App {

    /// Phase 7: the quick-panel coordinator doubles as the app
    /// delegate — it owns the Carbon hotkey and the floating panel,
    /// and ContentView configures it with the shared stores on
    /// appear. The main window remains the app's home; the panel is
    /// additive.
    @NSApplicationDelegateAdaptor(HUDCoordinator.self)
    private var hudCoordinator

    /// The SwiftData store for conversations and messages. If the on-disk
    /// store ever fails to open (corrupt file, future schema change), fall
    /// back to an in-memory store so the app still launches and chats work
    /// for the session — better than crashing on open. Phase 10 revisits
    /// storage migrations properly.
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Conversation.self, Message.self,
                                      ToolActivityRecord.self,
                                      ActionPlanRecord.self)
        } catch {
            let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
            // If even this fails there is no store at all; crashing loudly
            // at launch is the honest outcome.
            return try! ModelContainer(for: Conversation.self, Message.self,
                                       ToolActivityRecord.self,
                                       ActionPlanRecord.self,
                                       configurations: memoryOnly)
        }
    }()

    var body: some Scene {
        // The id lets the quick panel front (or recreate) this
        // window with `openWindow` when the user picks "Open in
        // main window".
        WindowGroup(id: "main") {
            ContentView(hudCoordinator: hudCoordinator)
        }
        .modelContainer(container)
        .windowStyle(.titleBar)
    }
}
