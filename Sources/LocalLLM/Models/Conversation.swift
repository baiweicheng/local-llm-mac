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
/// conversation ever leaves this Mac.
@Model
final class Conversation {
    var id: UUID
    var title: String
    /// Per-chat system instructions. Empty means "use the built-in default"
    /// (see `PromptHistory.defaultInstructions`).
    var systemInstructions: String
    /// Phase 2: the running summary of the oldest messages, written by the
    /// on-device model when the conversation outgrows its context window
    /// (see `ContextManager`). The messages themselves are never deleted —
    /// this is the model's condensed memory of them, and it is what a
    /// rebuilt session is seeded with. Nil until the first compaction.
    var contextSummary: String?
    /// Phase 2: how many of the oldest stored messages have been folded
    /// into `contextSummary`. Those messages form a prefix of
    /// `sortedMessages`; the rest are the "live" turns a session still
    /// sees verbatim.
    var summarizedMessageCount: Int
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "New Chat", systemInstructions: String = "") {
        self.id = UUID()
        self.title = title
        self.systemInstructions = systemInstructions
        self.contextSummary = nil
        self.summarizedMessageCount = 0
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
    /// Phase 2: this message's images, as one encoded blob (see
    /// `ImageAttachmentCodec`). External storage keeps image bytes out of
    /// the main store file; nil means no images. Only user messages ever
    /// carry images.
    @Attribute(.externalStorage) var attachmentsData: Data?
    var createdAt: Date
    var conversation: Conversation?

    init(role: MessageRole, text: String, conversation: Conversation? = nil) {
        self.id = UUID()
        self.role = role.rawValue
        self.text = text
        self.attachmentsData = nil
        self.createdAt = Date()
        self.conversation = conversation
    }

    var messageRole: MessageRole {
        MessageRole(rawValue: role) ?? .assistant
    }

    /// The decoded images attached to this message (empty when none, or
    /// when a stored blob is unreadable — never a crash).
    var attachments: [ImageAttachment] {
        ImageAttachmentCodec.decode(attachmentsData)
    }

    /// This message as a detached turn for the context logic.
    var chatTurn: ChatTurn {
        ChatTurn(role: messageRole, text: text,
                 attachmentCount: attachments.count)
    }
}
