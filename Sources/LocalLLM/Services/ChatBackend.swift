import Foundation
import FoundationModels

/// One send, as a backend sees it: the prompt text (for a fresh session
/// the engine has already prepended the seed — summary + recent turns —
/// exactly as in Phase 2), plus any image files riding along. Framework
/// backends forward the images; local servers get the text only in
/// Phase 3 (see `EndpointBackend`).
struct ChatReplyRequest: Sendable {
    let promptText: String
    let imageURLs: [URL] = []
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

/// The outcome of resolving a chat's stored selection against what
/// actually exists right now: the backend to talk to, and the selection
/// it effectively is (a chat whose model was deleted resolves to the
/// built-in model, and the engine tells the user that happened).
struct ResolvedBackend {
    let backend: ModelBackend
    let effectiveSelection: ModelSelection
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
                return ResolvedBackend(backend: EndpointBackend(config: config),
                                       effectiveSelection: selection)
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
                effectiveSelection: selection)
        }
    }
}
