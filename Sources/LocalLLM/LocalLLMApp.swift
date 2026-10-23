import SwiftUI
import SwiftData

/// App entry point.
///
/// "LocalLLM" is a placeholder name — the real name comes later; renaming
/// it touches this file, Package.swift, and the sidebar's empty-state text.
@main
struct LocalLLMApp: App {

    /// The SwiftData store for conversations and messages. If the on-disk
    /// store ever fails to open (corrupt file, future schema change), fall
    /// back to an in-memory store so the app still launches and chats work
    /// for the session — better than crashing on open. Phase 10 revisits
    /// storage migrations properly.
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Conversation.self, Message.self,
                                      ToolActivityRecord.self)
        } catch {
            let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
            // If even this fails there is no store at all; crashing loudly
            // at launch is the honest outcome.
            return try! ModelContainer(for: Conversation.self, Message.self,
                                       ToolActivityRecord.self,
                                       configurations: memoryOnly)
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .windowStyle(.titleBar)
    }
}
