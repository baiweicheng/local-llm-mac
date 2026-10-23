import Foundation
import SwiftData

/// Who wrote a message. Stored in ``Message`` as its raw string value so the
/// on-disk format stays obvious and stable.
enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

/// One chat conversation: a title, optional system instructions of its own,
/// and its messages. Persisted locally with SwiftData — nothing about a
/// conversation ever leaves this Mac in Phase 1.
@Model
final class Conversation {
    var id: UUID
    var title: String
    /// Per-chat system instructions. Empty means "use the built-in default"
    /// (see `PromptHistory.defaultInstructions`).
    var systemInstructions: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "New Chat", systemInstructions: String = "") {
        self.id = UUID()
        self.title = title
        self.systemInstructions = systemInstructions
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Messages in the order they were written. (SwiftData relationships
    /// have no inherent order, so sorting lives here in one place.)
    var sortedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

/// A single message inside a conversation.
@Model
final class Message {
    var id: UUID
    /// `MessageRole.rawValue` — "user" or "assistant".
    var role: String
    var text: String
    var createdAt: Date
    var conversation: Conversation?

    init(role: MessageRole, text: String, conversation: Conversation? = nil) {
        self.id = UUID()
        self.role = role.rawValue
        self.text = text
        self.createdAt = Date()
        self.conversation = conversation
    }

    var messageRole: MessageRole {
        MessageRole(rawValue: role) ?? .assistant
    }
}
