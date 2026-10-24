import Foundation

/// A saved local model server: an OpenAI-compatible HTTP endpoint
/// running on this Mac — Ollama and LM Studio both speak this protocol.
/// Phase 3 talks to these as another backend type; the user configures
/// the address and model name in the Models panel.
struct EndpointConfig: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// Display name, e.g. "Ollama".
    var name: String
    /// Base API address, e.g. "http://localhost:11434/v1".
    var baseURL: String
    /// The model name the server should run, e.g. "llama3.1". The name
    /// must match a model that server has (Ollama: `ollama list`).
    var modelName: String

    /// The chat-completions URL: the base address with any trailing
    /// slash removed, plus "/chat/completions". Nil when the base
    /// address doesn't parse as a URL at all.
    var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/chat/completions")
    }

    /// The host portion for small print, e.g. "localhost:11434".
    var hostDescription: String {
        guard let url = URL(string: baseURL), let host = url.host,
              !host.isEmpty else {
            return baseURL
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    /// True when this server runs on this very Mac — its address is
    /// `localhost` or a loopback IP. Phase 4's privacy check draws its
    /// line here: a message to a loopback server never leaves the
    /// machine, so it is sent exactly as written; a server at any
    /// other address counts as "somewhere else", and the prompt is
    /// scrubbed by `Redactor` first. Anything unparseable counts as
    /// NOT local — when in doubt, scrub.
    var isLocalhost: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased()
        else { return false }
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// True when the address uses plaintext HTTP (no TLS).
    var usesPlainHTTP: Bool {
        URL(string: baseURL)?.scheme?.lowercased() == "http"
    }

    /// Audit S-09: the warning the server editor shows for the one
    /// genuinely exposed combination — a server that isn't on this
    /// Mac, reached over plaintext HTTP. Nil for local servers and
    /// for HTTPS addresses (a remote HTTPS server is the user's
    /// explicit choice, and the privacy check still runs first).
    var remoteHTTPWarning: String? {
        guard !isLocalhost, usesPlainHTTP else { return nil }
        return "This server isn't on this Mac and its address uses "
            + "http://, so anything sent to it travels without "
            + "encryption — anyone along the network path could "
            + "read it. Use an https:// address if the server "
            + "supports one."
    }

    /// Picker small print: "llama3.1 · localhost:11434".
    var pickerDetail: String {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? hostDescription : "\(model) · \(hostDescription)"
    }

    // MARK: - Presets

    /// Fixed ids for the two presets, so re-seeding first-run defaults
    /// is deterministic (and testable).
    static let ollamaPresetID = UUID(uuidString: "0E1A0000-0000-4000-8000-000000000001")!
    static let lmStudioPresetID = UUID(uuidString: "0E1A0000-0000-4000-8000-000000000002")!

    static let ollamaPreset = EndpointConfig(
        id: ollamaPresetID,
        name: "Ollama",
        baseURL: "http://localhost:11434/v1",
        modelName: "llama3.1")

    static let lmStudioPreset = EndpointConfig(
        id: lmStudioPresetID,
        name: "LM Studio",
        baseURL: "http://localhost:1234/v1",
        modelName: "")

    /// What a fresh install starts with: both presets, Ollama first.
    static let defaultConfigs: [EndpointConfig] = [ollamaPreset, lmStudioPreset]
}

/// Encoding/decoding the saved server list (stored as JSON in
/// UserDefaults by the services layer). Pure and deterministic — keys
/// sorted — so a config list round-trips exactly.
enum EndpointConfigCodec {

    static func encode(_ configs: [EndpointConfig]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding these plain structs cannot realistically fail; an
        // empty payload is the honest fallback.
        return (try? encoder.encode(configs)) ?? Data()
    }

    /// Decodes a stored list; anything missing or unreadable means "no
    /// saved servers" rather than a crash.
    static func decode(_ data: Data?) -> [EndpointConfig] {
        guard let data, !data.isEmpty,
              let configs = try? JSONDecoder().decode([EndpointConfig].self,
                                                      from: data) else {
            return []
        }
        return configs
    }
}

/// One message in the OpenAI chat-completions shape.
struct ChatMessagePayload: Codable, Equatable, Sendable {
    let role: String // "system", "user", or "assistant"
    let content: String
}

/// Building chat-completions requests (pure): given the chat's
/// instructions, the session's remembered history, and the new user
/// message, produce the messages array and the JSON body.
enum OpenAIRequestBuilder {

    /// System instructions first (skipped when empty), then history in
    /// order, then the new user message. Instructions travel as their
    /// own system message — the stateless server has no other place to
    /// keep them between sends.
    static func messages(instructions: String,
                         history: [ChatMessagePayload],
                         newUserMessage: String) -> [ChatMessagePayload] {
        var result: [ChatMessagePayload] = []
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(ChatMessagePayload(role: "system", content: trimmed))
        }
        result.append(contentsOf: history)
        result.append(ChatMessagePayload(role: "user", content: newUserMessage))
        return result
    }

    /// The request body: streaming chat completions for `model`.
    /// `includeUsage` (Phase 8, OpenRouter) asks the service to
    /// attach a usage report — tokens and the real cost — to the
    /// stream's final chunk; `SSEAccumulator` picks it up. Local
    /// servers never set it: they don't charge, and some would
    /// reject an unknown field.
    static func bodyData(model: String,
                         instructions: String,
                         history: [ChatMessagePayload],
                         newUserMessage: String,
                         includeUsage: Bool = false) -> Data {
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages(instructions: instructions,
                                 history: history,
                                 newUserMessage: newUserMessage)
                .map { ["role": $0.role, "content": $0.content] },
        ]
        if includeUsage {
            payload["usage"] = ["include": true]
        }
        // The payload is built from strings and arrays only, so
        // serialization cannot fail; the empty-object fallback exists
        // only to keep this function total.
        return (try? JSONSerialization.data(withJSONObject: payload,
                                            options: [.sortedKeys])) ?? Data()
    }
}

/// Accumulates a chat-completions SSE stream (pure): feed it one line
/// at a time; it hands back the reply text so far whenever a content
/// piece arrives, mirroring how the framework's own streaming reports
/// cumulative text.
struct SSEAccumulator: Equatable, Sendable {
    /// The reply text received so far.
    private(set) var text: String = ""
    /// True once the server sent the [DONE] marker.
    private(set) var isDone: Bool = false
    /// Phase 8: the latest usage report seen in the stream, when the
    /// request asked for one (OpenRouter sends it in the final
    /// chunk, which usually carries no content at all — so this is
    /// captured independently of the content path below).
    private(set) var usage: UsageReport?

    /// Consumes one raw stream line. Returns the new cumulative text
    /// when the line carried a content piece, nil otherwise (blank
    /// lines, keep-alives, role-only first chunks, malformed JSON, the
    /// [DONE] marker itself).
    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            isDone = true
            return nil
        }
        if let report = UsageReport.parse(payload: String(payload)) {
            usage = report
        }
        guard let delta = Self.contentDelta(fromPayload: String(payload)) else {
            return nil
        }
        text += delta
        return text
    }

    /// Extracts `choices[0].delta.content` from one data payload.
    /// Returns nil when there's no content piece (a role announcement,
    /// a finish-reason chunk, usage stats, or unparseable JSON). An
    /// explicitly empty string is a real (if boring) piece and is
    /// returned as "".
    static func contentDelta(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return nil
        }
        return delta["content"] as? String
    }
}
