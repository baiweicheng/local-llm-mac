import Foundation
import FoundationModels
import Observation
import SwiftData

/// Runs conversations against the on-device model.
///
/// One `LanguageModelSession` per conversation, kept alive for as long as
/// the app runs — that's what gives the model memory within a conversation.
/// Sessions are recreated when a chat's instructions change, and a fresh
/// session for a conversation that already has history gets a written recap
/// with its first prompt (see `PromptHistory`).
///
/// All state here is main-actor: the UI reads `streamingText`,
/// `respondingIDs`, and `errorMessages` directly.
@MainActor
@Observable
final class ChatEngine {

    // MARK: - Observable state for the UI

    /// Partial reply text, per conversation, while a reply is streaming.
    private(set) var streamingText: [UUID: String] = [:]
    /// Conversations with a reply currently in flight.
    private(set) var respondingIDs: Set<UUID> = []
    /// Last error per conversation, in plain English, shown as a banner.
    var errorMessages: [UUID: String] = [:]

    // MARK: - Sessions

    private var sessions: [UUID: LanguageModelSession] = [:]
    /// The instructions each live session was created with, so an edit in
    /// the UI can retire the stale session instead of surprising the model.
    private var sessionInstructions: [UUID: String] = [:]
    /// Conversations whose live session was created fresh in this app run
    /// even though stored history exists — they still owe the model a recap.
    private var owesRecap: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isResponding(_ conversationID: UUID) -> Bool {
        respondingIDs.contains(conversationID)
    }

    func stop(conversationID: UUID) {
        tasks[conversationID]?.cancel()
    }

    /// The conversation was deleted — forget its session and any stream.
    func forget(conversationID: UUID) {
        tasks[conversationID]?.cancel()
        tasks[conversationID] = nil
        sessions[conversationID] = nil
        sessionInstructions[conversationID] = nil
        owesRecap.remove(conversationID)
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        errorMessages[conversationID] = nil
    }

    // MARK: - Sending

    /// Appends the user's message, then streams the model's reply and saves
    /// it as an assistant message when the stream finishes (or partially, if
    /// the user stops generation or something goes wrong).
    func send(text: String, in conversation: Conversation, context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding(conversation.id) else { return }

        let userMessage = Message(role: .user, text: trimmed, conversation: conversation)
        context.insert(userMessage)
        if conversation.title == "New Chat" {
            conversation.title = String(trimmed.prefix(48))
        }
        conversation.updatedAt = Date()
        try? context.save()

        startStreaming(conversation: conversation, context: context)
    }

    private func startStreaming(conversation: Conversation, context: ModelContext) {
        let conversationID = conversation.id
        errorMessages[conversationID] = nil

        // History is everything stored except the just-sent last user turn,
        // which becomes the prompt.
        let storedTurns = conversation.sortedMessages.map {
            ChatTurn(role: $0.messageRole, text: $0.text)
        }
        guard let lastTurn = storedTurns.last, lastTurn.role == .user else { return }
        let priorTurns = Array(storedTurns.dropLast())

        let instructions = PromptHistory.mergedInstructions(
            userInstructions: conversation.systemInstructions)
        let session = session(for: conversationID,
                              instructions: instructions,
                              hasStoredHistory: !priorTurns.isEmpty)
        let prompt = PromptHistory.promptForModel(
            userText: lastTurn.text,
            priorTurns: priorTurns,
            sessionIsFresh: owesRecap.contains(conversationID))
        owesRecap.remove(conversationID)

        respondingIDs.insert(conversationID)
        streamingText[conversationID] = ""

        let stream = session.streamResponse(to: prompt)
        tasks[conversationID] = Task { [weak self] in
            var received = ""
            do {
                for try await partial in stream {
                    received = partial.content
                    self?.streamingText[conversationID] = received
                }
            } catch is CancellationError {
                // Stopped by the user — whatever arrived is kept below.
            } catch {
                self?.errorMessages[conversationID] =
                    "The model couldn't finish that reply: \(error.localizedDescription)"
            }

            guard let self else { return }
            let finalText = received.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                let reply = Message(role: .assistant, text: finalText,
                                    conversation: conversation)
                context.insert(reply)
                conversation.updatedAt = Date()
                try? context.save()
            }
            self.streamingText[conversationID] = nil
            self.respondingIDs.remove(conversationID)
            self.tasks[conversationID] = nil
        }
    }

    /// Returns the live session for a conversation, creating (or recreating)
    /// it when needed.
    private func session(for conversationID: UUID,
                         instructions: String,
                         hasStoredHistory: Bool) -> LanguageModelSession {
        if let existing = sessions[conversationID],
           sessionInstructions[conversationID] == instructions {
            return existing
        }
        let session = LanguageModelSession(instructions: instructions)
        sessions[conversationID] = session
        sessionInstructions[conversationID] = instructions
        if hasStoredHistory {
            owesRecap.insert(conversationID)
        }
        return session
    }
}
