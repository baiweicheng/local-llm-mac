import Foundation

/// A local model server (Ollama, LM Studio) as a backend.
///
/// These servers speak the OpenAI chat-completions protocol over HTTP
/// and are *stateless* — they remember nothing between requests — so
/// the session below keeps the message list itself and resends it with
/// every message. The engine's seeding works unchanged: a fresh
/// session's first prompt already carries [summary + recent turns], so
/// the session's history simply starts there.
///
/// Phase 3 sends text only: image attachments in a message are not
/// forwarded to local servers (framework backends do get them). Local
/// servers also can't be asked "are you there?" cheaply, so a down
/// server is discovered at send time and reported in plain English.
struct EndpointBackend: ModelBackend {

    let config: EndpointConfig

    var selection: ModelSelection { .endpoint(id: config.id) }
    var displayName: String { config.name }
    var budget: ContextBudget { .mlxLocal } // conservative local default

    // Phase 5: local servers get no tools — the OpenAI-compatible
    // protocol this backend speaks has no tool-calling in this app
    // yet, and pretending otherwise would be worse than saying so
    // (the chat UI shows a plain note when tools are enabled here).
    // `supportsTools` stays false (the protocol default), so the
    // engine never builds a tool set for this backend at all.
    @MainActor
    func makeSession(instructions: String, tools: SessionTools?) -> ChatSession {
        EndpointChatSession(config: config, instructions: instructions)
    }
}

/// A live session against one local server: remembers the exchange
/// (user text as sent — including any seed — and the replies) and
/// streams replies from the server's SSE stream, accumulating deltas
/// into the same "text so far" shape the engine expects.
@MainActor
final class EndpointChatSession: ChatSession {

    private let config: EndpointConfig
    private let instructions: String
    private var history: [ChatMessagePayload] = []

    init(config: EndpointConfig, instructions: String) {
        self.config = config
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
                    // Only a completed exchange joins the history, so
                    // a failed or stopped send doesn't leave a dangling
                    // user message the next send would trip over.
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

    /// One HTTP round trip: builds the request with the pure builder,
    /// streams the SSE lines through the pure accumulator, and returns
    /// the full reply text.
    private func performSend(promptText: String,
                             onText: @escaping (String) -> Void) async throws -> String {
        guard let url = config.chatCompletionsURL else {
            throw BackendError.endpointUnreachable(
                name: config.name, address: config.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = OpenAIRequestBuilder.bodyData(
            model: config.modelName,
            instructions: instructions,
            history: history,
            newUserMessage: promptText)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            // Connection refused, timeout, DNS — in local terms: the
            // server isn't answering.
            throw BackendError.endpointUnreachable(
                name: config.name, address: config.hostDescription)
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw BackendError.endpointHTTPError(
                name: config.name, status: http.statusCode)
        }

        var accumulator = SSEAccumulator()
        for try await line in bytes.lines {
            if let text = accumulator.consume(line: line) {
                onText(text)
            }
            if accumulator.isDone { break }
        }
        return accumulator.text
    }
}

/// The user's saved local servers, persisted as JSON in UserDefaults.
/// Seeded with the Ollama and LM Studio presets on first run so the
/// picker is useful immediately; every edit saves straight away.
@MainActor
@Observable
final class EndpointStore {

    private(set) var configs: [EndpointConfig]

    private let defaultsKey = "LocalLLM.endpointConfigs.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: defaultsKey) {
            // Something was saved before — honor it exactly, even if
            // the user deleted every server.
            configs = EndpointConfigCodec.decode(raw)
        } else {
            configs = EndpointConfig.defaultConfigs
            persist()
        }
    }

    func add(_ config: EndpointConfig) {
        configs.append(config)
        persist()
    }

    func update(_ config: EndpointConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id })
        else { return }
        configs[index] = config
        persist()
    }

    func remove(id: UUID) {
        configs.removeAll { $0.id == id }
        persist()
    }

    func config(for id: UUID) -> EndpointConfig? {
        configs.first { $0.id == id }
    }

    private func persist() {
        defaults.set(EndpointConfigCodec.encode(configs), forKey: defaultsKey)
    }
}
