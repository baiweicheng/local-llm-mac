import Foundation
import SwiftData

/// Phase 5: one persisted access-log entry — one tool execution.
///
/// The log is deliberately a separate model from `Message`, not a
/// special message row: Phase 2's context compaction counts message
/// prefixes (`summarizedMessageCount` over the sorted messages), and
/// interleaving non-message rows would break that arithmetic. ChatView
/// merges messages and these records by `createdAt` to render the
/// transcript; Settings shows the same records as the access log
/// ("Recent lookups"). One record of truth, two views — nothing the
/// model looks at is invisible to the user.
@Model
final class ToolActivityRecord {
    var id: UUID
    /// The conversation the lookup happened in. (The log is global;
    /// this is what lets a chat show just its own cards.)
    var conversationID: UUID
    var createdAt: Date
    /// The tool's stable name ("search_files") — display names are
    /// looked up from `ToolCatalog` at render time.
    var toolName: String
    /// The source's raw value, or "" for utilities (calculator, clock).
    var sourceRaw: String
    /// Short human summary of what was asked ("“roof invoice”").
    var querySummary: String
    /// Short human summary of what came back (first line, capped).
    var resultSummary: String

    init(conversationID: UUID,
         toolName: String,
         sourceRaw: String,
         querySummary: String,
         resultSummary: String,
         createdAt: Date = Date()) {
        self.id = UUID()
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.toolName = toolName
        self.sourceRaw = sourceRaw
        self.querySummary = querySummary
        self.resultSummary = resultSummary
    }

    convenience init(event: ToolEvent) {
        self.init(conversationID: event.conversationID,
                  toolName: event.toolName,
                  sourceRaw: event.source?.rawValue ?? "",
                  querySummary: event.querySummary,
                  resultSummary: event.resultSummary,
                  createdAt: event.date)
    }
}
