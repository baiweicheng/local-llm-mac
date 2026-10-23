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
    /// Phase 3: which model backend this chat uses, as a
    /// `ModelSelection` storage key ("onDevice", "mlx:<repo id>",
    /// "endpoint:<uuid>"). Stored as a plain string so the on-disk
    /// format stays obvious; the typed value is `modelSelection`. New
    /// property with a default — existing stores migrate in place.
    /// Phase 4 adds "auto" (the routing default for new chats, see
    /// init); chats saved before keep whatever they had.
    var modelSelectionRaw: String
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
        // Phase 4: new chats start on Auto — the app picks the best
        // local model for each message. Chats that already exist keep
        // the explicit selection they were saved with.
        self.modelSelectionRaw = ModelSelection.auto.storageKey
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// The chat's chosen model backend. Setting it persists the choice;
    /// the engine notices on the next send and rebuilds the chat's
    /// session against the new backend, re-seeded with the summary and
    /// recent turns (the Phase 2 machinery). An unrecognized stored
    /// value reads back as the built-in model.
    var modelSelection: ModelSelection {
        get { ModelSelection(storageKey: modelSelectionRaw) }
        set { modelSelectionRaw = newValue.storageKey }
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
    /// Phase 4 telemetry, stored as three optional fields so the store
    /// migrates in place (older messages simply have none): which
    /// backend produced this reply (pill label, e.g. "Apple
    /// On-Device"), how many seconds it took, and its estimated token
    /// count. All three nil for user messages and anything written
    /// before Phase 4; the typed view is `telemetry`.
    var telemetryBackendLabel: String?
    var telemetrySeconds: Double?
    var telemetryTokens: Int?
    var createdAt: Date
    var conversation: Conversation?

    init(role: MessageRole, text: String, conversation: Conversation? = nil) {
        self.id = UUID()
        self.role = role.rawValue
        self.text = text
        self.attachmentsData = nil
        self.telemetryBackendLabel = nil
        self.telemetrySeconds = nil
        self.telemetryTokens = nil
        self.createdAt = Date()
        self.conversation = conversation
    }

    /// This message's execution telemetry, when it has any — assistant
    /// replies written since Phase 4. Cost isn't stored: every backend
    /// so far is local and free, so it's always $0.00; when the cloud
    /// tier lands (Phase 8) it can start recording real costs here.
    var telemetry: MessageTelemetry? {
        get {
            guard let telemetryBackendLabel,
                  let telemetrySeconds,
                  let telemetryTokens else { return nil }
            return MessageTelemetry(backendLabel: telemetryBackendLabel,
                                    seconds: telemetrySeconds,
                                    estimatedTokens: telemetryTokens)
        }
        set {
            telemetryBackendLabel = newValue?.backendLabel
            telemetrySeconds = newValue?.seconds
            telemetryTokens = newValue?.estimatedTokens
        }
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
