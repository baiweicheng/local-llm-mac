import SwiftUI
import SwiftData

/// App entry point.
///
/// The product's name is Blink (chosen 2026-10-23) — a display name
/// only: it lives in Scripts/make-app.sh (the bundle name and the
/// generated Info.plist) and the README. This module, its types,
/// and its storage keys keep the internal name "LocalLLM".
@main
struct LocalLLMApp: App {

    /// Phase 7: the quick-panel coordinator doubles as the app
    /// delegate — it owns the Carbon hotkey and the floating panel,
    /// and ContentView configures it with the shared stores on
    /// appear. The main window remains the app's home; the panel is
    /// additive.
    @NSApplicationDelegateAdaptor(HUDCoordinator.self)
    private var hudCoordinator

    /// The SwiftData store for conversations and messages, plus
    /// whether the persistent store actually opened.
    ///
    /// Review finding 10: if the on-disk store ever fails to open
    /// (corrupt file, future schema change), the app still falls
    /// back to an in-memory store so it launches and chats work
    /// for the session — but that fallback is NO LONGER silent.
    /// `persistentStoreFailed` travels to ContentView, which shows
    /// a visible banner ("chats won't be saved") and SKIPS the
    /// startup backup sweep, so an empty in-memory store can never
    /// be read as proof that every real backup folder is orphaned.
    /// Every schema change across the ten phases was additive (new
    /// models, new optional fields), which SwiftData migrates in
    /// place; this fallback is the safety net if that ever stops
    /// being true.
    let container: ModelContainer
    let persistentStoreFailed: Bool

    init() {
        do {
            container = try ModelContainer(for: Conversation.self, Message.self,
                                           ToolActivityRecord.self,
                                           ActionPlanRecord.self)
            persistentStoreFailed = false
        } catch {
            let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
            // If even this fails there is no store at all; crashing loudly
            // at launch is the honest outcome.
            container = try! ModelContainer(for: Conversation.self, Message.self,
                                            ToolActivityRecord.self,
                                            ActionPlanRecord.self,
                                            configurations: memoryOnly)
            persistentStoreFailed = true
        }
    }

    var body: some Scene {
        // The id lets the quick panel front (or recreate) this
        // window with `openWindow` when the user picks "Open in
        // main window".
        WindowGroup(id: "main") {
            ContentView(hudCoordinator: hudCoordinator,
                        persistentStoreFailed: persistentStoreFailed)
        }
        .modelContainer(container)
        .windowStyle(.titleBar)
    }
}
