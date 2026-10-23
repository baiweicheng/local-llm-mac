import Foundation
import FoundationModels
import Observation
import SwiftData

/// Runs conversations against the on-device model.
///
/// One `LanguageModelSession` per conversation, kept alive for as long as
/// the app runs — that's what gives the model memory within a conversation.
/// A session's memory is finite (4,096 tokens), so Phase 2 manages it for
/// real (see `ContextManager`):
///
/// - Before each send, the conversation is checked against its context
///   budget. If it no longer fits, the oldest turns are folded into a
///   running summary — written by the on-device model itself — and the
///   session is rebuilt, seeded with [summary + recent turns verbatim].
/// - A session is also rebuilt when the chat's instructions change, and
///   after an app relaunch (seeded from storage the same way).
/// - Stored messages are never deleted by any of this. The summary lives
///   on the `Conversation` record; the transcript the user sees is whole.
///
/// All state here is main-actor: the UI reads `streamingText`,
/// `respondingIDs`, and `errorMessages` directly.
@MainActor
@Observable
final class ChatEngine {

    // MARK: - Observable state for the UI

    /// Partial reply text, per conversation, while a reply is streaming.
    private(set) var streamingText: [UUID: String] = [:]
    /// Conversations with a reply currently in flight (including the
    /// brief compaction step that can precede one).
    private(set) var respondingIDs: Set<UUID> = []
    /// Last error per conversation, in plain English, shown as a banner.
    var errorMessages: [UUID: String] = [:]

    // MARK: - Sessions

    private var sessions: [UUID: LanguageModelSession] = [:]
    /// The instructions each live session was created with, so an edit in
    /// the UI can retire the stale session instead of surprising the model.
    private var sessionInstructions: [UUID: String] = [:]
    /// The conversation summary each live session's context reflects
    /// ("" when none), so a compaction retires the stale session.
    private var sessionSummaries: [UUID: String] = [:]
    /// Whether the live session has been seeded with the stored context
    /// (summary + live turns). A brand-new chat needs no seed; a rebuilt
    /// or relaunched one does, with its first prompt.
    private var sessionSeeded: [UUID: Bool] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// The budget all Phase 2 sends plan against. Later phases pick the
    /// row matching the selected backend (see `ContextBudget.table`).
    private let budget = ContextBudget.onDevice

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
        retireSession(conversationID)
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        errorMessages[conversationID] = nil
    }

    // MARK: - Sending

    /// Appends the user's message (with any prepared image attachments),
    /// then prepares the context — compacting first if needed — and
    /// streams the model's reply, saving it as an assistant message when
    /// the stream finishes (or partially, if stopped or interrupted).
    func send(text: String,
              attachments: [ImageAttachment] = [],
              in conversation: Conversation,
              context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              !isResponding(conversation.id) else { return }

        let userMessage = Message(role: .user, text: trimmed,
                                  conversation: conversation)
        if !attachments.isEmpty {
            userMessage.attachmentsData = ImageAttachmentCodec.encode(attachments)
        }
        context.insert(userMessage)
        if conversation.title == "New Chat" {
            conversation.title = trimmed.isEmpty
                ? "Image chat"
                : String(trimmed.prefix(48))
        }
        conversation.updatedAt = Date()
        try? context.save()

        let conversationID = conversation.id
        errorMessages[conversationID] = nil
        respondingIDs.insert(conversationID)
        streamingText[conversationID] = ""
        tasks[conversationID] = Task { [weak self] in
            await self?.prepareAndStream(conversation: conversation,
                                         context: context)
        }
    }

    /// Compaction (if the plan calls for it), session selection, and the
    /// streaming call itself. Runs inside the send task, so Stop cancels
    /// it at any stage.
    private func prepareAndStream(conversation: Conversation,
                                  context: ModelContext) async {
        let conversationID = conversation.id
        let instructions = PromptHistory.mergedInstructions(
            userInstructions: conversation.systemInstructions)

        let stored = conversation.sortedMessages
        guard let lastMessage = stored.last,
              lastMessage.messageRole == .user else {
            finish(conversationID: conversationID)
            return
        }
        let newPromptTurn = lastMessage.chatTurn

        // Live turns: stored history minus the summarized prefix and
        // minus the message about to be sent.
        func liveTurns() -> [ChatTurn] {
            let all = conversation.sortedMessages.dropLast()
            let prefix = min(conversation.summarizedMessageCount, all.count)
            return Array(all.dropFirst(prefix)).map { $0.chatTurn }
        }

        // Compaction passes — always before streaming, never mid-stream.
        // One pass summarizes a bounded chunk; a very long history can
        // need several, so loop (with a sane cap) until the plan fits.
        var plan = ContextManager.plan(budget: budget,
                                       instructions: instructions,
                                       existingSummary: conversation.contextSummary,
                                       liveTurns: liveTurns(),
                                       newPrompt: newPromptTurn)
        var passes = 0
        while plan.needsCompaction, passes < 4 {
            passes += 1
            let newSummary = await summarize(
                existingSummary: conversation.contextSummary,
                turns: plan.turnsToSummarize)
            if Task.isCancelled {
                finish(conversationID: conversationID)
                return
            }
            conversation.contextSummary = newSummary
            conversation.summarizedMessageCount += plan.turnsToSummarize.count
            conversation.updatedAt = Date()
            try? context.save()
            retireSession(conversationID) // its context is now stale
            plan = ContextManager.plan(budget: budget,
                                       instructions: instructions,
                                       existingSummary: conversation.contextSummary,
                                       liveTurns: liveTurns(),
                                       newPrompt: newPromptTurn)
        }

        // Session selection and seeding.
        let summaryKey = conversation.contextSummary ?? ""
        let canReuse = sessions[conversationID] != nil
            && sessionInstructions[conversationID] == instructions
            && sessionSummaries[conversationID] == summaryKey
            && sessionSeeded[conversationID] == true

        let session: LanguageModelSession
        var promptText = lastMessage.text
        if canReuse, let existing = sessions[conversationID] {
            session = existing
        } else {
            session = LanguageModelSession(instructions: instructions)
            sessions[conversationID] = session
            sessionInstructions[conversationID] = instructions
            sessionSummaries[conversationID] = summaryKey
            // The fresh session knows nothing yet: prepend the stored
            // context (summary + live turns) to this prompt. For a
            // brand-new chat the seed is empty and the prompt stands
            // alone.
            let seed = ContextManager.seedText(
                existingSummary: conversation.contextSummary,
                recentTurns: liveTurns())
            if !seed.isEmpty {
                promptText = seed + "\n\n" + lastMessage.text
            }
            sessionSeeded[conversationID] = true
        }

        // Streaming. Images ride along as file attachments in the
        // prompt; the temporary files must outlive the stream, so they
        // are deleted only after it finishes.
        let imageFiles = writeTemporaryImages(lastMessage.attachments)
        defer {
            if let dir = imageFiles.directory {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        var received = ""
        do {
            if imageFiles.urls.isEmpty {
                let stream = session.streamResponse(to: promptText)
                for try await partial in stream {
                    received = partial.content
                    streamingText[conversationID] = received
                }
            } else {
                let stream = session.streamResponse(
                    to: multimodalPrompt(text: promptText,
                                         imageURLs: imageFiles.urls))
                for try await partial in stream {
                    received = partial.content
                    streamingText[conversationID] = received
                }
            }
        } catch is CancellationError {
            // Stopped by the user — whatever arrived is kept below.
        } catch {
            errorMessages[conversationID] =
                "The model couldn't finish that reply: \(error.localizedDescription)"
        }

        let finalText = received.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            let reply = Message(role: .assistant, text: finalText,
                                conversation: conversation)
            context.insert(reply)
            conversation.updatedAt = Date()
            try? context.save()
        }
        finish(conversationID: conversationID)
    }

    // MARK: - Compaction helpers

    /// One summarization pass with a throwaway session. On any failure,
    /// falls back to the mechanical summary so compaction — and the send
    /// that triggered it — still succeeds.
    private func summarize(existingSummary: String?,
                           turns: [ChatTurn]) async -> String {
        let input = ContextManager.summarizerInput(
            existingSummary: existingSummary,
            turns: turns,
            targetTokens: budget.summaryTargetTokens)
        let session = LanguageModelSession(
            instructions: ContextManager.summarizerInstructions)
        do {
            let response = try await session.respond(to: input)
            let text = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        } catch {
            // Fall through to the mechanical summary.
        }
        return ContextManager.mechanicalFallbackSummary(
            existing: existingSummary, droppedTurns: turns)
    }

    private func retireSession(_ conversationID: UUID) {
        sessions[conversationID] = nil
        sessionInstructions[conversationID] = nil
        sessionSummaries[conversationID] = nil
        sessionSeeded[conversationID] = nil
    }

    private func finish(conversationID: UUID) {
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        tasks[conversationID] = nil
    }

    // MARK: - Image attachments

    /// Builds the multimodal prompt: the text, then one `Attachment` per
    /// image file — the framework's documented route for image input
    /// (macOS 27). The framework reads the files itself, so they must
    /// outlive the stream; the caller deletes them afterwards.
    private func multimodalPrompt(text: String, imageURLs: [URL]) -> Prompt {
        Prompt {
            text
            for url in imageURLs {
                Attachment(imageURL: url)
            }
        }
    }

    /// Writes a message's stored images to a private temporary folder so
    /// they can be handed to the model as file URLs. Images that fail to
    /// write are skipped; if none can be written, the caller falls back
    /// to a text-only prompt.
    private func writeTemporaryImages(
        _ attachments: [ImageAttachment]
    ) -> (urls: [URL], directory: URL?) {
        guard !attachments.isEmpty else { return ([], nil) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLLM-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            return ([], nil)
        }
        var urls: [URL] = []
        for (index, attachment) in attachments.enumerated() {
            let url = directory.appendingPathComponent("image-\(index).jpg")
            if (try? attachment.data.write(to: url, options: .atomic)) != nil {
                urls.append(url)
            }
        }
        return (urls, directory)
    }
}
