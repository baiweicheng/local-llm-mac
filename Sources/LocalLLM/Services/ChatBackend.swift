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

/// A model backend: a factory for sessions, plus the identity and
/// context budget the engine plans against. Backends are cheap values;
/// sessions are the stateful part.
protocol ModelBackend: Sendable {
    var selection: ModelSelection { get }
    var displayName: String { get }
    var budget: ContextBudget { get }
    @MainActor func makeSession(instructions: String) -> ChatSession
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
/// `LanguageModelSession` over `SystemLanguageModel`.
struct OnDeviceBackend: ModelBackend {
    var selection: ModelSelection { .onDevice }
    var displayName: String { "Apple On-Device" }
    var budget: ContextBudget { .onDevice }

    @MainActor
    func makeSession(instructions: String) -> ChatSession {
        FrameworkChatSession(
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
    static func resolve(selection: ModelSelection,
                        downloadedMLXRepoIDs: Set<String>,
                        endpoints: [EndpointConfig],
                        localOnly: Bool = false,
                        kvCacheMode: KVCacheMode = .defaultMode)
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
        }
    }
}
