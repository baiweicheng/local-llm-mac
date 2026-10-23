import Foundation
import FoundationModels
import Observation
import SwiftData

/// Runs conversations against the model backend each chat has picked.
///
/// Phase 3 shape: the engine no longer talks to the on-device model
/// directly. Every chat has a `ModelSelection` (built-in model, a
/// downloaded MLX model, or a local server); a provider closure —
/// configured by the app from the live model/server stores — resolves
/// it to a `ModelBackend`, and the backend makes the live session. The
/// Phase 2 machinery is unchanged in spirit and mostly in code:
///
/// - One live session per conversation, kept while the app runs.
/// - Before each send, the conversation is planned against the
///   *selected backend's* context budget; if it no longer fits, the
///   oldest turns are folded into a running summary and the session is
///   rebuilt, seeded with [summary + recent turns verbatim].
/// - Switching the picker mid-conversation retires the session; the
///   next send rebuilds it against the new backend and re-seeds it the
///   same way, so the thread carries over and the new budget applies.
///   (Framework backends could swap via Dynamic Profiles, but local
///   servers aren't framework sessions — one rebuild path for every
///   backend keeps switching behavior identical. See the README.)
/// - Summaries are always written by the built-in on-device model,
///   whatever backend the chat uses: it's a background chore the small
///   model is good at, and it keeps compaction working even for a chat
///   pointed at a server that's down. A mechanical fallback covers the
///   on-device model being unavailable.
/// - Stored messages are never deleted. The summary lives on the
///   `Conversation` record; the transcript the user sees is whole.
///
/// Phase 4 adds the routing layer on top of that shape:
///
/// - A chat set to Auto has its outgoing prompt classified by a
///   throwaway on-device session (`IntentClassifier`) and routed by
///   the pure `RoutingPolicy` to a concrete backend before any of the
///   machinery above runs — from there on, an Auto send is an ordinary
///   send against the routed backend, telemetry included. A manual
///   picker choice remains a complete override: no classification.
/// - The privacy firewall: a chat pointed at a server that isn't on
///   this Mac is the one place a prompt can leave the machine, so the
///   outgoing text (instructions + prompt, history included) is
///   scrubbed by `Redactor` first, and the user is told it happened.
///   Stored messages are never touched — only the sent copy. The
///   brief's history-compression half of the firewall needs no new
///   machinery: a session is seeded with [running summary + recent
///   turns] (Phase 2), never the raw stored history, and an endpoint
///   session's memory is exactly the seeded prompt chain it was fed —
///   so a compacted chat's older turns reach a remote destination
///   only as their summary. Phase 8's cloud backend consumes this
///   same hook: it will be a `ModelBackend` like any other, seeded
///   the same way, with `Redactor` applied on the same
///   remote-destination check.
/// - The Local Only lock is enforced in `BackendFactory`: a server
///   selection resolves to the built-in model while it's on, and the
///   engine explains the switch.
/// - Every finished reply records telemetry (backend, seconds,
///   estimated tokens) on its `Message` for the pill in the
///   transcript.
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
    /// Phase 4: the latest Auto routing explanation per conversation
    /// ("Auto: a quick edit or question — Apple On-Device has it."),
    /// shown as a small caption while the chat is on Auto.
    private(set) var routingNotes: [UUID: String] = [:]
    /// Phase 4: informational banners that aren't errors — currently
    /// the privacy-check notice when a prompt was scrubbed before
    /// being sent to a server that isn't on this Mac.
    var infoMessages: [UUID: String] = [:]

    // MARK: - Backends

    /// Resolves a chat's stored selection to a live backend. Configured
    /// by the app shell from the MLX store and the server store; until
    /// then (and for anything unknown) everything resolves to the
    /// built-in model, which is exactly Phase 1–2 behavior.
    private var backendProvider: (ModelSelection) -> ResolvedBackend = { _ in
        ResolvedBackend(backend: OnDeviceBackend(),
                        effectiveSelection: .onDevice)
    }

    func configureBackendProvider(
        _ provider: @escaping (ModelSelection) -> ResolvedBackend
    ) {
        backendProvider = provider
    }

    /// Phase 4: everything routing and the privacy firewall need to
    /// know about the world — what's downloaded, what's configured,
    /// whether Local Only is on, what must never leave unhidden.
    /// Configured by the app shell alongside the backend provider;
    /// until then, empty inputs (Auto routes to the built-in model,
    /// nothing counts as remote).
    private var routingContextProvider: () -> RoutingInputs = {
        RoutingInputs()
    }

    func configureRoutingContextProvider(
        _ provider: @escaping () -> RoutingInputs
    ) {
        routingContextProvider = provider
    }

    // MARK: - Sessions

    /// A conversation's live session and everything needed to know
    /// whether it can be reused for the next send: which backend made
    /// it, the instructions it was created with, the summary its
    /// context reflects, and whether it has been seeded.
    private struct LiveSession {
        let session: ChatSession
        let selection: ModelSelection
        let instructions: String
        let summaryKey: String
        let seeded: Bool
    }

    private var liveSessions: [UUID: LiveSession] = [:]
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
        retireSession(conversationID)
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        errorMessages[conversationID] = nil
        routingNotes[conversationID] = nil
        infoMessages[conversationID] = nil
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
        infoMessages[conversationID] = nil
        respondingIDs.insert(conversationID)
        streamingText[conversationID] = ""
        tasks[conversationID] = Task { [weak self] in
            await self?.prepareAndStream(conversation: conversation,
                                         context: context)
        }
    }

    /// Backend resolution, compaction (if the plan calls for it),
    /// session selection, and the streaming call itself. Runs inside
    /// the send task, so Stop cancels it at any stage.
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

        // Phase 4 routing: an Auto chat's prompt is classified and
        // routed to a concrete backend first; a manual selection is
        // already concrete and skips this entirely.
        let routingInputs = routingContextProvider()
        var targetSelection = conversation.modelSelection
        if conversation.modelSelection.isAuto {
            let intent = await IntentClassifier.classify(
                prompt: lastMessage.text) ?? .quickTransform
            if Task.isCancelled {
                finish(conversationID: conversationID)
                return
            }
            let decision = RoutingPolicy.decide(intent: intent,
                                                inputs: routingInputs)
            targetSelection = decision.selection
            var noteText = decision.reason
            if let note = decision.note {
                noteText += " " + note
            }
            routingNotes[conversationID] = noteText
        }

        let resolved = backendProvider(targetSelection)
        let backend = resolved.backend
        let selection = resolved.effectiveSelection
        let budget = backend.budget
        if selection != targetSelection {
            // The picked (or routed) model can't run: it was deleted,
            // its server was removed, or the Local Only lock refuses
            // servers right now. The chat falls back to the built-in
            // model — say which happened, once, rather than silently
            // switching.
            if routingInputs.localOnly, case .endpoint(_) = targetSelection {
                errorMessages[conversationID] =
                    "Local Only is on, so this chat can't use its "
                    + "server right now — it switched to a model that "
                    + "runs entirely on this Mac."
            } else {
                errorMessages[conversationID] =
                    "The model this chat was using isn't available anymore, "
                    + "so it switched back to the built-in on-device model."
            }
        }

        // Phase 4 privacy firewall. A chat pointed at a server that
        // isn't on this Mac is the one place a prompt can leave the
        // machine in this phase, so everything bound for it — the
        // instructions now, the prompt (seeded history included)
        // further below — is scrubbed by `Redactor` first. Local
        // destinations (built-in model, MLX, a localhost server) get
        // the text exactly as written. Stored messages are never
        // touched; only the sent copy is edited.
        let isRemoteDestination: Bool = {
            guard case .endpoint(let id) = selection,
                  let config = routingInputs.endpoints
                    .first(where: { $0.id == id }) else { return false }
            return !config.isLocalhost
        }()
        var effectiveInstructions = instructions
        var redactions = 0
        if isRemoteDestination {
            let scrubbed = Redactor.redact(
                instructions,
                customTerms: routingInputs.customRedactionTerms)
            effectiveInstructions = scrubbed.text
            redactions += scrubbed.replacementCount
        }

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
            // The summarizer is the on-device model (4K window) even
            // when the chat's backend is bigger, so cap each chunk to
            // what the summarizer can actually read; later passes fold
            // the rest.
            let chunk = summarizerChunk(plan.turnsToSummarize,
                                        existingSummary: conversation.contextSummary)
            let newSummary = await summarize(
                existingSummary: conversation.contextSummary,
                turns: chunk,
                targetTokens: budget.summaryTargetTokens)
            if Task.isCancelled {
                finish(conversationID: conversationID)
                return
            }
            conversation.contextSummary = newSummary
            conversation.summarizedMessageCount += chunk.count
            conversation.updatedAt = Date()
            try? context.save()
            retireSession(conversationID) // its context is now stale
            plan = ContextManager.plan(budget: budget,
                                       instructions: instructions,
                                       existingSummary: conversation.contextSummary,
                                       liveTurns: liveTurns(),
                                       newPrompt: newPromptTurn)
        }

        // Session selection and seeding. A live session is reused only
        // when backend, instructions, and summary all still match —
        // anything else (first send, picker switch, instructions edit,
        // compaction, relaunch) rebuilds and re-seeds.
        // Note the session identity uses the *effective* instructions
        // (the scrubbed copy for a remote destination), so a session
        // is never reused across a change in what would be sent.
        let summaryKey = conversation.contextSummary ?? ""
        let existing = liveSessions[conversationID]
        let canReuse = existing != nil
            && existing!.selection == selection
            && existing!.instructions == effectiveInstructions
            && existing!.summaryKey == summaryKey
            && existing!.seeded

        let session: ChatSession
        var promptText = lastMessage.text
        if canReuse, let existing {
            session = existing.session
        } else {
            session = backend.makeSession(instructions: effectiveInstructions)
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
            liveSessions[conversationID] = LiveSession(
                session: session, selection: selection,
                instructions: effectiveInstructions, summaryKey: summaryKey,
                seeded: true)
        }

        // The firewall's second half: with the outgoing prompt fully
        // assembled (seeded history included), scrub it too, and say
        // so — once per send, counting the instructions with it.
        if isRemoteDestination {
            let scrubbed = Redactor.redact(
                promptText,
                customTerms: routingInputs.customRedactionTerms)
            promptText = scrubbed.text
            redactions += scrubbed.replacementCount
            if redactions > 0 {
                let noun = redactions == 1 ? "item" : "items"
                infoMessages[conversationID] =
                    "Privacy check: \(redactions) \(noun) that looked "
                    + "like secrets or personal details were hidden "
                    + "before this was sent to \(backend.displayName), "
                    + "because that server isn't on this Mac. Your "
                    + "saved chat is unchanged — only the copy that "
                    + "was sent was edited."
            }
        }

        // Streaming. Images ride along as temporary files (framework
        // backends read them; local servers get the text only), and the
        // files must outlive the stream, so they are deleted only after
        // it finishes.
        let imageFiles = writeTemporaryImages(lastMessage.attachments)
        defer {
            if let dir = imageFiles.directory {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        var received = ""
        let generationStarted = Date()
        do {
            let request = ChatReplyRequest(promptText: promptText,
                                           imageURLs: imageFiles.urls)
            for try await text in session.streamReply(to: request) {
                received = text
                streamingText[conversationID] = received
            }
        } catch is CancellationError {
            // Stopped by the user — whatever arrived is kept below.
        } catch {
            errorMessages[conversationID] =
                "The model couldn't finish that reply: \(error.localizedDescription)"
        }
        let generationSeconds = Date().timeIntervalSince(generationStarted)

        let finalText = received.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            let reply = Message(role: .assistant, text: finalText,
                                conversation: conversation)
            // Phase 4 telemetry: which backend actually answered, how
            // long it took, roughly how big the reply is. Rendered as
            // the pill under the message; local backends are free, so
            // the cost (not stored) reads $0.00.
            reply.telemetry = MessageTelemetry(
                backendLabel: TelemetryFormat.label(
                    for: selection, displayName: backend.displayName),
                seconds: generationSeconds,
                estimatedTokens: PromptHistory.approximateTokenCount(
                    for: finalText))
            context.insert(reply)
            conversation.updatedAt = Date()
            try? context.save()
        }
        finish(conversationID: conversationID)
    }

    // MARK: - Compaction helpers

    /// The prefix of `turns` that fits the summarizer's own window.
    /// The summarizer runs on the on-device model (4,096 tokens) even
    /// for chats on bigger backends, so a pass planned against a large
    /// budget is folded in a few chunks. Always at least one turn, so
    /// compaction always makes progress.
    private func summarizerChunk(_ turns: [ChatTurn],
                                 existingSummary: String?) -> [ChatTurn] {
        let summarizerBudget = ContextBudget.onDevice
        let summaryTokens = existingSummary.map {
            PromptHistory.approximateTokenCount(for: $0)
        } ?? 0
        let allowance = summarizerBudget.promptAllowanceTokens
            - summaryTokens - ContextManager.summarizerOverheadTokens
        var used = 0
        var kept = 0
        for turn in turns {
            let cost = ContextManager.tokens(for: turn)
            if kept > 0, used + cost > allowance { break }
            used += cost
            kept += 1
        }
        return Array(turns.prefix(max(1, kept)))
    }

    /// One summarization pass with a throwaway on-device session. On
    /// any failure, falls back to the mechanical summary so compaction
    /// — and the send that triggered it — still succeeds.
    private func summarize(existingSummary: String?,
                           turns: [ChatTurn],
                           targetTokens: Int) async -> String {
        let input = ContextManager.summarizerInput(
            existingSummary: existingSummary,
            turns: turns,
            targetTokens: targetTokens)
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
        liveSessions[conversationID] = nil
    }

    private func finish(conversationID: UUID) {
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        tasks[conversationID] = nil
    }

    // MARK: - Image attachments

    /// Writes a message's stored images to a private temporary folder
    /// so they can be handed to the model as file URLs. Images that
    /// fail to write are skipped; if none can be written, the send
    /// falls back to a text-only prompt.
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
