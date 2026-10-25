import Foundation
import FoundationModels

/// One send, as a backend sees it: the prompt text (for a fresh session
/// the engine has already prepended the seed — summary + recent turns —
/// exactly as in Phase 2), plus any image files riding along. Framework
/// backends forward the images; local servers get the text only in
/// Phase 3 (see `EndpointBackend`).
struct ChatReplyRequest: Sendable {
    let promptText: String
    // `var`, not `let`: a `let` property with a default value is
    // omitted from the synthesized memberwise initializer, so the
    // engine's `imageURLs:` argument at the call site was rejected
    // as an extra argument. `var` keeps the default AND the argument.
    var imageURLs: [URL] = []
    /// Review finding 6: the CURRENT custom redaction terms for
    /// this send, plus whether the destination is remote. HTTP
    /// sessions use them to scrub their COMPLETE outgoing payload
    /// (instructions + saved history + new message) immediately
    /// before transport — the engine's prompt scrub alone can't
    /// reach a reused session's cached assistant turns, and terms
    /// added after the session was created must still apply. Local
    /// destinations leave both at their defaults (no scrub), so a
    /// localhost server keeps receiving text exactly as written.
    /// Framework sessions ignore both fields: their prompt text
    /// arrives already scrubbed by the engine, and their history
    /// never leaves this Mac (on-device) or is outside this app's
    /// transport to intercept (PCC).
    var redactionTerms: [String] = []
    var scrubOutgoingPayload: Bool = false
}

/// A live conversation session against one backend. Implementations
/// remember the conversation their own way — a framework
/// `LanguageModelSession` natively, a local server session by keeping
/// the message list and resending it (those servers are stateless).
///
/// `streamReply` yields the reply text *so far* on every update, the
/// same cumulative shape the framework's streaming uses, so the engine
/// handles every backend identically.
@MainActor
protocol ChatSession: AnyObject {
    func streamReply(to request: ChatReplyRequest)
        -> AsyncThrowingStream<String, Error>
}

/// Phase 8: a session that can say what its last reply actually
/// cost. Only the OpenRouter session conforms — it's the one
/// backend that charges per reply and reports the figure. The
/// engine reads this after a stream finishes and puts the real
/// cost on the message's telemetry pill; a conforming session
/// whose report is missing (the service sent none) leaves the
/// pill at "cost unknown" for that reply.
@MainActor
protocol UsageReportingChatSession: ChatSession {
    var lastUsageReport: UsageReport? { get }
}

/// A model backend: a factory for sessions, plus the identity and
/// context budget the engine plans against. Backends are cheap values;
/// sessions are the stateful part.
protocol ModelBackend: Sendable {
    var selection: ModelSelection { get }
    var displayName: String { get }
    var budget: ContextBudget { get }
    /// Phase 5: whether this backend's sessions can call the app's
    /// visibility tools. The on-device framework and MLX backends can;
    /// local servers can't (Phase 5 ships no tool protocol for them),
    /// so their chats simply never receive a tool set and the UI says
    /// so plainly.
    var supportsTools: Bool { get }
    @MainActor func makeSession(instructions: String, tools: SessionTools?) -> ChatSession
}

extension ModelBackend {
    var supportsTools: Bool { false }
}

/// Backend failures with explanations written for the user, not for a
/// log file. The engine surfaces `errorDescription` verbatim.
enum BackendError: LocalizedError {
    /// The local server didn't answer (not running, wrong address).
    case endpointUnreachable(name: String, address: String)
    /// The server answered, but with an HTTP error.
    case endpointHTTPError(name: String, status: Int)
    /// A chat's MLX model isn't downloaded (anymore).
    case mlxModelUnavailable(displayName: String)
    /// Phase 8: OpenRouter couldn't be reached at all (offline,
    /// DNS, a dropped connection).
    case openRouterUnreachable
    /// Phase 8: OpenRouter rejected the API key (HTTP 401/403).
    case openRouterKeyRejected
    /// Phase 8: OpenRouter says the account is out of credit
    /// (HTTP 402).
    case openRouterOutOfCredit
    /// Phase 8: OpenRouter rate-limited the request (HTTP 429).
    case openRouterRateLimited
    /// Phase 8: any other OpenRouter HTTP error.
    case openRouterHTTPError(status: Int)
    /// The server accepted the request but reported an error
    /// inside the reply stream itself (audit B-08).
    case endpointStreamError(name: String, message: String)
    /// OpenRouter reported an error inside the reply stream
    /// itself (audit B-08).
    case openRouterStreamError(message: String)

    /// Maps an OpenRouter HTTP status to the error whose wording
    /// fits it — a rejected key and an empty balance need different
    /// advice, so they aren't lumped into one generic failure.
    static func openRouterHTTP(status: Int) -> BackendError {
        switch status {
        case 401, 403: return .openRouterKeyRejected
        case 402: return .openRouterOutOfCredit
        case 429: return .openRouterRateLimited
        default: return .openRouterHTTPError(status: status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let name, let address):
            return "Couldn't reach \(name) at \(address). Make sure the "
                + "app is running and its local server is turned on, "
                + "then try again."
        case .endpointHTTPError(let name, let status):
            return "\(name) answered with an error (HTTP \(status)). "
                + "Check that the model name in Models matches a model "
                + "the server actually has."
        case .mlxModelUnavailable(let displayName):
            return "\(displayName) isn't downloaded anymore, so this "
                + "chat can't use it. Download it again in Models, or "
                + "pick a different model above."
        case .openRouterUnreachable:
            return "Couldn't reach OpenRouter — check this Mac's "
                + "internet connection, then try again."
        case .openRouterKeyRejected:
            return "OpenRouter didn't accept your API key. Open "
                + "Settings → Cloud models (gear button) and paste "
                + "the key again — if it was revoked on openrouter.ai, "
                + "make a fresh one there first."
        case .openRouterOutOfCredit:
            return "OpenRouter says your account is out of credit, so "
                + "the model couldn't answer. Add credit on "
                + "openrouter.ai, then try again."
        case .openRouterRateLimited:
            return "OpenRouter is rate-limiting requests right now. "
                + "Wait a moment, then try again."
        case .openRouterHTTPError(let status):
            return "OpenRouter answered with an error (HTTP \(status)). "
                + "If it keeps happening, the model may be unavailable "
                + "on OpenRouter right now — try a different one."
        case .endpointStreamError(let name, let message):
            return "\(name) reported an error while answering: "
                + "\(message)"
        case .openRouterStreamError(let message):
            return "OpenRouter reported an error while answering: "
                + "\(message)"
        }
    }
}

/// A `ChatSession` over a framework `LanguageModelSession` — the
/// built-in on-device backend's session. (MLX models used to share
/// this wrapper through the framework bridge; they now run on the MLX
/// library's own session so the KV-cache setting in Settings can
/// actually reach the cache — see `MLXBackend.swift` for why.)
@MainActor
final class FrameworkChatSession: ChatSession {

    private let session: LanguageModelSession

    init(session: LanguageModelSession) {
        self.session = session
    }

    func streamReply(to request: ChatReplyRequest)
        -> AsyncThrowingStream<String, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if request.imageURLs.isEmpty {
                        let stream = session.streamResponse(to: request.promptText)
                        for try await partial in stream {
                            continuation.yield(partial.content)
                        }
                    } else {
                        let stream = session.streamResponse(
                            to: Self.multimodalPrompt(text: request.promptText,
                                                      imageURLs: request.imageURLs))
                        for try await partial in stream {
                            continuation.yield(partial.content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The framework's documented route for image input (macOS 27):
    /// the text, then one `Attachment` per image file.
    private static func multimodalPrompt(text: String, imageURLs: [URL]) -> Prompt {
        Prompt {
            text
            for url in imageURLs {
                Attachment(imageURL: url)
            }
        }
    }
}

/// The built-in on-device model — Phase 1's backend, unchanged: a
/// `LanguageModelSession` over `SystemLanguageModel`. Phase 5 makes
/// it the primary tools engine (the brief's triage already routes
/// "do something on my Mac" intents here): when the session carries a
/// tool set, the wrappers are bound at construction, as the framework
/// requires, and the framework itself invokes them.
struct OnDeviceBackend: ModelBackend {
    var selection: ModelSelection { .onDevice }
    var displayName: String { "Apple On-Device" }
    var budget: ContextBudget { .onDevice }
    var supportsTools: Bool { true }

    @MainActor
    func makeSession(instructions: String, tools: SessionTools?) -> ChatSession {
        if let tools, !tools.descriptors.isEmpty {
            let frameworkTools: [any Tool] = tools.descriptors.map { descriptor in
                FrameworkTool(name: descriptor.name,
                              description: descriptor.modelDescription,
                              runtime: tools.runtime)
            }
            return FrameworkChatSession(session: LanguageModelSession(
                tools: frameworkTools, instructions: instructions))
        }
        return FrameworkChatSession(
            session: LanguageModelSession(instructions: instructions))
    }
}

/// Audit B-47: a fingerprint of a resolved backend's CONFIGURATION,
/// folded into the engine's live-session signature. A session is
/// keyed by selection alone (`.endpoint(id:)`,
/// `.openRouter(modelID:)`), but the session object captures the
/// full endpoint config (base URL, model name) or the OpenRouter
/// API key at creation — so editing a server, or rotating a revoked
/// key, changed nothing for live chats until this digest joined
/// the reuse check.
///
/// Pure composition, so the rules are unit-testable:
/// - Endpoints: the base URL + model name, verbatim apart from
///   trimming — any edit produces a different digest.
/// - OpenRouter: a one-way FNV-1a digest of the key. The key VALUE
///   is never stored in the digest, never printed, and digests live
///   only in memory (`LiveSession` is an in-memory engine value,
///   never persisted) — the digest exists solely so "the key
///   changed" is visible to the reuse check.
enum SessionConfigDigest {

    static func endpoint(baseURL: String, modelName: String) -> String {
        "endpoint|"
            + baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            + "|" + modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func openRouter(apiKey: String) -> String {
        "openrouter|key:" + oneWayDigest(of: apiKey)
    }

    /// FNV-1a (64-bit) over the value's UTF-8, as hex — the same
    /// deliberate non-`Hasher` choice as `RedactionTermsHash`: a
    /// stable value the tests can pin. One-way for signature
    /// purposes: the input cannot be read back out of it.
    static func oneWayDigest(of value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// The outcome of resolving a chat's stored selection against what
/// actually exists right now: the backend to talk to, and the selection
/// it effectively is (a chat whose model was deleted resolves to the
/// built-in model, and the engine tells the user that happened).
struct ResolvedBackend {
    let backend: ModelBackend
    let effectiveSelection: ModelSelection
    /// Audit B-47: the resolved backend's configuration fingerprint
    /// (`SessionConfigDigest`). Empty for backends whose identity is
    /// fully carried by the selection itself (on-device, MLX, PCC);
    /// set for endpoints and OpenRouter, whose sessions capture
    /// configuration beyond the selection. In-memory only.
    var configDigest: String = ""
}

/// Turns stored selections into live backends. Pure lookups against
/// plain inputs, mirroring `BackendRegistry`, so resolution rules live
/// in exactly one place.
enum BackendFactory {

    /// - Parameter localOnly: the Settings privacy lock (Phase 4).
    ///   When on, server selections are *refused* here in the factory
    ///   — not merely hidden in the UI — and resolve to the built-in
    ///   model, with the effective selection saying so. The engine
    ///   notices the mismatch and explains it to the user.
    /// - Parameter kvCacheMode: the Settings KV-cache mode, handed to
    ///   the MLX backend so its sessions are created with that cache
    ///   configuration. Ignored by every other backend — they manage
    ///   their own caches.
    /// - Parameter openRouterAPIKey: the user's OpenRouter key,
    ///   read from the Keychain by the app shell (the one place the
    ///   key value is ever read). Nil — no key saved — resolves an
    ///   OpenRouter selection to the built-in model, and the engine
    ///   explains why. The factory never sees where the key lives.
    static func resolve(selection: ModelSelection,
                        downloadedMLXRepoIDs: Set<String>,
                        endpoints: [EndpointConfig],
                        localOnly: Bool = false,
                        kvCacheMode: KVCacheMode = .defaultMode,
                        openRouterAPIKey: String? = nil)
        -> ResolvedBackend {
        switch selection {
        case .auto:
            // Auto is classified and routed by the engine before the
            // factory is consulted; arriving here means there was no
            // routing context, and the built-in model is the safe
            // default.
            return ResolvedBackend(backend: OnDeviceBackend(),
                                   effectiveSelection: .onDevice)
        case .onDevice:
            return ResolvedBackend(backend: OnDeviceBackend(),
                                   effectiveSelection: .onDevice)
        case .mlx(let repoID):
            if downloadedMLXRepoIDs.contains(repoID),
               let info = MLXCatalog.info(forRepoID: repoID) {
                return ResolvedBackend(
                    backend: MLXBackend(info: info,
                                        kvCacheMode: kvCacheMode),
                    effectiveSelection: selection)
            }
            return ResolvedBackend(backend: OnDeviceBackend(),
                                   effectiveSelection: .onDevice)
        case .endpoint(let id):
            if localOnly {
                return ResolvedBackend(backend: OnDeviceBackend(),
                                       effectiveSelection: .onDevice)
            }
            if let config = endpoints.first(where: { $0.id == id }) {
                return ResolvedBackend(
                    backend: EndpointBackend(config: config),
                    effectiveSelection: selection,
                    configDigest: SessionConfigDigest.endpoint(
                        baseURL: config.baseURL, modelName: config.modelName))
            }
            return ResolvedBackend(backend: OnDeviceBackend(),
                                   effectiveSelection: .onDevice)
        case .privateCloudCompute:
            // PCC runs on Apple's servers — off this Mac — so the
            // Local Only lock refuses it exactly like a server. The
            // engine sees the effective selection change and says why.
            if localOnly {
                return ResolvedBackend(backend: OnDeviceBackend(),
                                       effectiveSelection: .onDevice)
            }
            return ResolvedBackend(backend: PCCBackend(),
                                   effectiveSelection: selection)
        case .openRouter(let modelID):
            if localOnly {
                return ResolvedBackend(backend: OnDeviceBackend(),
                                       effectiveSelection: .onDevice)
            }
            let key = openRouterAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else {
                // No key saved (or it was removed): the cloud route
                // can't run. Fall back to the built-in model; the
                // engine's message names the missing key as the
                // reason, because it can see the target selection.
                return ResolvedBackend(backend: OnDeviceBackend(),
                                       effectiveSelection: .onDevice)
            }
            return ResolvedBackend(
                backend: OpenRouterBackend(modelID: modelID, apiKey: key),
                effectiveSelection: selection,
                // Audit B-47: a one-way digest of the key — never
                // the key itself — so rotating the key retires live
                // sessions exactly like editing a server does.
                configDigest: SessionConfigDigest.openRouter(apiKey: key))
        }
    }
}
