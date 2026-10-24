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
    /// The server's own error report, when a stream payload carried
    /// a top-level `error` object (audit B-08). OpenAI-compatible
    /// servers can deliver one of these inside an HTTP 200 stream;
    /// without this state it was dropped like a keep-alive and the
    /// partial (or empty) text looked like a finished reply. Callers
    /// throw when this is set.
    private(set) var errorMessage: String?
    /// The `data:` lines of the event currently being assembled
    /// (audit B-13): an event's payload may be split across several
    /// consecutive `data:` lines. Lines are held here until together
    /// they parse as one JSON object (or the event/stream ends).
    private var pendingDataLines: [String] = []

    /// Consumes one raw stream line. Returns the new cumulative text
    /// when the line completed an event carrying a content piece,
    /// nil otherwise (blank lines that complete a contentless event,
    /// keep-alives, role-only first chunks, still-incomplete
    /// multi-line payloads, the [DONE] marker itself).
    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // A blank line is the SSE event boundary: whatever is
            // buffered is the whole event, parseable or not.
            return flush()
        }
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            _ = flush()
            isDone = true
            return nil
        }
        pendingDataLines.append(String(payload))
        // Most events are a single line: if the buffered lines now
        // form a complete JSON object, the event is complete. If
        // not, the payload may be a multi-line event still in
        // flight — keep buffering instead of dropping the halves.
        if let complete = Self.completedPayload(from: pendingDataLines) {
            pendingDataLines = []
            return process(payload: complete)
        }
        // The buffered lines never completed, but THIS line is a
        // whole event by itself: the buffered ones were a single
        // malformed event (a stray "data: {not json"), and holding
        // onto them would poison every event that follows.
        if pendingDataLines.count > 1,
           let single = Self.completedPayload(from: [String(payload)]) {
            pendingDataLines = []
            return process(payload: single)
        }
        // A payload that is not even a plausible JSON PREFIX (its
        // brackets balance and it ends outside any string) is a
        // complete — if garbled — event, not half of one: drop it
        // now rather than buffering forever.
        let joined = pendingDataLines.joined(separator: "\n")
        if !Self.couldBeJSONPrefix(joined) {
            pendingDataLines = []
        }
        return nil
    }

    /// Whether `text` could still grow into valid JSON by appending
    /// more lines: it ends inside a string, or with brackets open.
    /// (A negative depth — more closers than openers — never can.)
    private static func couldBeJSONPrefix(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\", inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return inString || depth > 0
    }

    /// Ends the stream: processes a trailing event that never got
    /// its blank line, if the buffered lines form a payload. Returns
    /// the cumulative text when that event carried content.
    mutating func flush() -> String? {
        guard !pendingDataLines.isEmpty else { return nil }
        let lines = pendingDataLines
        pendingDataLines = []
        guard let complete = Self.completedPayload(from: lines)
        else { return nil }
        return process(payload: complete)
    }

    /// Applies one complete event payload: records an error report
    /// or a usage report when present, and appends any content
    /// piece. Returns the cumulative text when content arrived.
    private mutating func process(payload: String) -> String? {
        if let message = Self.errorMessage(fromPayload: payload) {
            if errorMessage == nil { errorMessage = message }
            return nil
        }
        if let report = UsageReport.parse(payload: payload) {
            usage = report
        }
        guard let delta = Self.contentDelta(fromPayload: payload) else {
            return nil
        }
        text += delta
        return text
    }

    /// Joins buffered `data:` lines into a payload once they form a
    /// complete JSON object — nil while the event is still split.
    /// Lines are joined with "\n" first (the SSE rule, right for
    /// payloads split between tokens); if that doesn't parse, the
    /// raw concatenation is tried (right for payloads split in the
    /// middle of a token or string).
    private static func completedPayload(from lines: [String]) -> String? {
        for candidate in [lines.joined(separator: "\n"),
                          lines.joined(separator: "")] {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  object is [String: Any] else { continue }
            return candidate
        }
        return nil
    }

    /// Extracts a human-readable message from a payload carrying a
    /// top-level `error` — an object with a `message`, or a bare
    /// string. Nil when the payload carries no error.
    static func errorMessage(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let error = dictionary["error"] else {
            return nil
        }
        if let message = error as? String, !message.isEmpty {
            return message
        }
        if let errorObject = error as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            return message
        }
        return "The server reported an error without details."
    }

    /// Extracts `choices[0].delta.content` from one data payload.
    /// Returns nil when there's no content piece (a role announcement,
    /// a finish-reason chunk, usage stats, or unparseable JSON). An
    /// explicitly empty string is a real (if boring) piece and is
    /// returned as "".
    ///
    /// The content may also arrive as an ARRAY of parts
    /// (`[{"type":"text","text":"…"}, …]`, the shape some newer
    /// servers emit): the parts' text is concatenated (audit B-13).
    static func contentDelta(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return nil
        }
        if let string = delta["content"] as? String {
            return string
        }
        if let parts = delta["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }
                .joined(separator: "")
        }
        return nil
    }
}
