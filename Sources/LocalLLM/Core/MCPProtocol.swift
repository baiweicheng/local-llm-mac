import Foundation

/// Phase 9: the MCP wire format, as pure logic.
///
/// MCP servers launched by the app speak JSON-RPC 2.0 over stdio:
/// one JSON object per line (newline-delimited) on the process's
/// stdin and stdout. This file is everything about that format —
/// encoding requests, parsing the incoming byte stream back into
/// messages, and decoding the `tools/list` and `tools/call` results
/// — with no Process or FileHandle in sight, so the whole protocol
/// is unit-testable. `MCPClient.swift` is the thin plumbing that
/// feeds bytes in and writes lines out.
///
/// The conversation the app has with each server:
///   1. → request  `initialize`   (protocol version + client info)
///   2. ← response (server info; contents not required by the app)
///   3. → notification `notifications/initialized`
///   4. → request  `tools/list`   → the tool catalog for the session
///   5. → request  `tools/call`   (only for user-approved calls)

// MARK: - JSON values

/// A JSON value in the app's own type — the MCP payloads are
/// arbitrary JSON, and this keeps the protocol layer off
/// `Any`/NSDictionary casting. Codable both ways (property lists of
/// MCP results map straight onto it).
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers encode without a trailing ".0" so ids
            // and integer arguments stay the shape servers expect.
            if value == value.rounded(), abs(value) < 9.0e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Parses arbitrary JSON text into a value (nil when it isn't
    /// valid JSON — including fragments like a bare word).
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return value
    }

    /// Canonical text form: object keys sorted, so two equal
    /// argument sets always print identically (plan items dedupe
    /// and display on it). Compact except inside strings.
    func canonicalText() -> String {
        switch self {
        case .string(let value): return Self.quote(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 9.0e15 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values):
            return "[" + values.map { $0.canonicalText() }.joined(separator: ", ") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                Self.quote(key) + ": " + (object[key]?.canonicalText() ?? "null")
            }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }

    private static func quote(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\(string)\""
        }
        return text
    }

    /// The string for a key in an object value, when it is one.
    func string(forKey key: String) -> String? {
        guard case .object(let object) = self,
              case .string(let value)? = object[key] else { return nil }
        return value
    }
}

// MARK: - MCP arguments from the model

/// The model's half of an MCP call: it hands the app the tool's
/// arguments as a JSON object STRING (the shared argument shape's
/// `argumentsJSON` field). The proposal path canonicalizes that
/// string once, here — what lands on the approval card, what gets
/// deduped, and what is finally sent are the same text, re-parsed
/// at execution.
enum MCPArguments {

    enum Outcome: Sendable, Equatable {
        case ok(canonicalJSON: String)
        case refused(reason: String)
    }

    /// Empty/missing arguments are fine — plenty of tools take
    /// none — and mean `{}`. Anything present must BE a JSON object;
    /// an array or a bare string is refused in plain English the
    /// model can relay.
    static func canonicalize(_ raw: String?) -> Outcome {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ok(canonicalJSON: "{}") }
        guard let value = JSONValue.parse(trimmed) else {
            return .refused(reason: "The arguments for that tool weren't valid JSON, so nothing was proposed. Arguments must be one JSON object in the argumentsJSON field, like {\"path\": \"/some/file\"}.")
        }
        guard case .object = value else {
            return .refused(reason: "The arguments for that tool must be a JSON object (like {\"path\": \"/some/file\"}), not a list or a bare value — nothing was proposed.")
        }
        return .ok(canonicalJSON: value.canonicalText())
    }

    /// The object form of a canonical string, for the wire. A
    /// canonical string always parses; anything else yields the
    /// empty object rather than failing at execution time.
    static func object(fromCanonical canonical: String) -> JSONValue {
        JSONValue.parse(canonical) ?? .object([:])
    }
}

// MARK: - JSON-RPC encoding

enum MCPJSONRPC {

    /// The MCP protocol version the app offers in `initialize`.
    /// Servers that speak an older revision answer with their own
    /// version and the app proceeds — the methods used here
    /// (initialize / tools/list / tools/call over stdio) are stable
    /// across the revisions in the wild.
    static let protocolVersion = "2025-03-26"

    static let clientName = "LocalLLM"
    static let clientVersion = "1.0"

    /// One request line (no trailing newline — the transport adds
    /// it): {"jsonrpc":"2.0","id":N,"method":M,"params":{…}}.
    static func encodeRequest(id: Int, method: String,
                              params: JSONValue?) -> String {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return JSONValue.object(object).canonicalText()
    }

    /// One notification line (no id).
    static func encodeNotification(method: String) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]).canonicalText()
    }

    /// The `initialize` request's params: the offered protocol
    /// version, an empty capabilities object (the app uses only
    /// tools, and advertises nothing fancier), and client info.
    static func initializeParams() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ])
    }
}

// MARK: - JSON-RPC parsing

/// One thing that arrived on a server's stdout.
enum MCPIncoming: Sendable, Equatable {
    /// A response to one of the app's requests, matched by id.
    case response(id: Int, result: JSONValue?, error: String?)
    /// A notification (no id) — servers send log/progress notes;
    /// the app notes the method and moves on.
    case notification(method: String)
    /// A request FROM the server (it has an id and a method) — the
    /// app answers none of these in this phase; the client replies
    /// with a method-not-found error so a well-behaved server isn't
    /// left hanging.
    case serverRequest(id: Int, method: String)
    /// A line that wasn't a JSON-RPC object at all. Servers
    /// sometimes print stray text; it must never kill the parser.
    case malformed(text: String)
}

/// The incoming byte stream → messages. Newline-delimited: bytes
/// are buffered until a full line arrives (a message can straddle
/// reads; several can arrive in one). Stateful and deliberately
/// small — feed it chunks, get back completed messages.
struct MCPStreamParser {

    /// Buffered BYTES, not text (audit B-01): read boundaries are
    /// arbitrary, so a multi-byte UTF-8 character can straddle two
    /// chunks — decoding whole chunks dropped the straddling chunk
    /// (and any complete lines in it) entirely. Bytes are split on
    /// the newline byte and only completed lines are decoded.
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [MCPIncoming] {
        buffer.append(chunk)
        var messages: [MCPIncoming] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            // A completed line from a conforming server is valid
            // UTF-8; decode lossily so a damaged line surfaces as
            // one `.malformed` message instead of vanishing.
            let line = String(decoding: lineData, as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                messages.append(Self.parseLine(trimmed))
            }
        }
        return messages
    }

    mutating func feed(_ text: String) -> [MCPIncoming] {
        feed(Data(text.utf8))
    }

    /// Whatever is left when the stream ends — a final message
    /// without its newline still counts.
    mutating func finish() -> [MCPIncoming] {
        let leftover = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = Data()
        return leftover.isEmpty ? [] : [Self.parseLine(leftover)]
    }

    static func parseLine(_ line: String) -> MCPIncoming {
        guard let value = JSONValue.parse(line),
              case .object(let object) = value else {
            return .malformed(text: line)
        }
        // Audit B-03: `Int(number)` traps on a huge id, and a
        // fractional id would silently truncate and risk matching
        // the wrong pending request. Only an integral id inside a
        // safely representable range is an id at all — anything
        // else makes the whole line malformed, never a crash.
        let id: Int?
        if case .number(let number)? = object["id"] {
            guard number.isFinite, number == number.rounded(),
                  abs(number) < 9.0e15 else {
                return .malformed(text: line)
            }
            id = Int(number)
        } else {
            id = nil
        }
        let method = object.string(forKey: "method")
        if let id, let method {
            return .serverRequest(id: id, method: method)
        }
        if let method {
            return .notification(method: method)
        }
        guard let id else { return .malformed(text: line) }
        if case .object(let errorObject)? = object["error"] {
            let message = errorObject.string(forKey: "message")
                ?? "the server reported an error"
            return .response(id: id, result: nil, error: message)
        }
        return .response(id: id, result: object["result"] ?? .null,
                         error: nil)
    }
}

// MARK: - Result decoding

/// One tool from a `tools/list` result, before it's tied to a
/// server (see `MCPToolInfo`).
struct MCPRemoteTool: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchemaJSON: String?
}

enum MCPResultDecoding {

    /// tools/list result → the tools. Entries without a name are
    /// skipped; a missing description becomes "" (the app fills a
    /// generic one in the descriptor).
    static func tools(from result: JSONValue) -> [MCPRemoteTool] {
        guard case .object(let object) = result,
              case .array(let entries)? = object["tools"] else { return [] }
        return entries.compactMap { entry in
            guard case .object(let tool) = entry,
                  let name = tool.string(forKey: "name") else { return nil }
            return MCPRemoteTool(
                name: name,
                description: tool.string(forKey: "description") ?? "",
                inputSchemaJSON: tool["inputSchema"]
                    .map { $0.canonicalText() })
        }
    }

    /// tools/call result → display text for the model + card.
    /// Content items: text items are quoted verbatim; other kinds
    /// (images, resources) become a one-line placeholder — this
    /// phase moves text. `isError` results are prefixed so the
    /// failure isn't mistaken for output.
    static func callText(from result: JSONValue) -> (text: String, isError: Bool) {
        guard case .object(let object) = result else {
            return (result.canonicalText(), false)
        }
        let isError: Bool = {
            if case .bool(let flag)? = object["isError"] { return flag }
            return false
        }()
        var parts: [String] = []
        if case .array(let content)? = object["content"] {
            for item in content {
                guard case .object(let block) = item else { continue }
                let type = block.string(forKey: "type") ?? ""
                if type == "text", let text = block.string(forKey: "text") {
                    parts.append(text)
                } else if !type.isEmpty {
                    parts.append("[the tool returned a \(type) item, which this app doesn't display]")
                }
            }
        }
        let text = parts.isEmpty ? "(the tool returned no text)" : parts.joined(separator: "\n")
        return (isError ? "The tool reported an error: " + text : text, isError)
    }
}
