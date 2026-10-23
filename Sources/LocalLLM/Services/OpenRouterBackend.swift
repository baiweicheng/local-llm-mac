import Foundation

/// Phase 8: OpenRouter as a backend — the frontier cloud route.
///
/// OpenRouter speaks the same OpenAI chat-completions protocol as
/// the local servers in Phase 3, so this backend reuses the pure
/// transport (`OpenAIRequestBuilder`, `SSEAccumulator`) with the
/// three differences a paid cloud service needs:
///
/// - **Authentication.** The user's own API key — read from the
///   Keychain by the app shell and handed to this backend at
///   resolution time — travels as a Bearer token. It is never
///   stored anywhere else, and this type never logs it.
/// - **Usage accounting.** Requests ask for a usage report
///   (`usage: {include: true}`), and the session keeps the latest
///   one, so the engine can put the reply's REAL cost on its
///   telemetry pill (`UsageReportingChatSession`). When a reply
///   comes back without a report, the pill says "cost unknown" —
///   never a pretend $0.00.
/// - **Cloud error wording.** A rejected key, an empty balance, and
///   a rate limit each get their own plain-English message
///   (`BackendError`).
///
/// Like local servers, OpenRouter sessions keep their own history
/// (the service is stateless per request) and get NO local tools —
/// the same parity Phase 3/5 set for server backends, and the chat
/// UI says so. The privacy firewall is the engine's job and runs
/// before anything reaches this type (see `ChatEngine`): by the
/// time text arrives here it has already been scrubbed.
struct OpenRouterBackend: ModelBackend {

    let modelID: String
    let apiKey: String

    var selection: ModelSelection { .openRouter(modelID: modelID) }
    var displayName: String { OpenRouterCatalog.displayName(forModelID: modelID) }
    var budget: ContextBudget { .openRouterCloud }

    @MainActor
    func makeSession(instructions: String, tools: SessionTools?) -> ChatSession {
        OpenRouterChatSession(modelID: modelID, apiKey: apiKey,
                              instructions: instructions)
    }
}

/// A live OpenRouter session: remembers the exchange and streams
/// replies, mirroring `EndpointChatSession` — with auth, usage
/// capture, and cloud error mapping added.
@MainActor
final class OpenRouterChatSession: ChatSession, UsageReportingChatSession {

    private let modelID: String
    private let apiKey: String
    private let instructions: String
    private var history: [ChatMessagePayload] = []

    /// The usage report from the most recent completed reply —
    /// what it actually cost. Nil when the service sent none.
    private(set) var lastUsageReport: UsageReport?

    init(modelID: String, apiKey: String, instructions: String) {
        self.modelID = modelID
        self.apiKey = apiKey
        self.instructions = instructions
    }

    func streamReply(to request: ChatReplyRequest)
        -> AsyncThrowingStream<String, Error> {
        let promptText = request.promptText
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let reply = try await self.performSend(
                        promptText: promptText,
                        onText: { continuation.yield($0) })
                    if !reply.isEmpty {
                        self.history.append(ChatMessagePayload(
                            role: "user", content: promptText))
                        self.history.append(ChatMessagePayload(
                            role: "assistant", content: reply))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performSend(promptText: String,
                             onText: @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: OpenRouterCatalog.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)",
                         forHTTPHeaderField: "Authorization")
        // OpenRouter asks apps to identify themselves; it affects
        // nothing but their public app rankings.
        request.setValue("LocalLLM", forHTTPHeaderField: "X-Title")
        request.httpBody = OpenAIRequestBuilder.bodyData(
            model: modelID,
            instructions: instructions,
            history: history,
            newUserMessage: promptText,
            includeUsage: true)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw BackendError.openRouterUnreachable
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw BackendError.openRouterHTTP(status: http.statusCode)
        }

        var accumulator = SSEAccumulator()
        for try await line in bytes.lines {
            if let text = accumulator.consume(line: line) {
                onText(text)
            }
            if accumulator.isDone { break }
        }
        if let usage = accumulator.usage {
            lastUsageReport = usage
        }
        return accumulator.text
    }
}
