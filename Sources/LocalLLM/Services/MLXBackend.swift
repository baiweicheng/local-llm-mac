import Foundation
import MLXFoundationModels
import MLXLMCommon

// ============================================================
//  THE ONLY FILE THAT TALKS TO MLX.
//
//  Every MLX-specific symbol in the app lives in this file, so if
//  the MLX libraries' APIs need adjusting at first compile, the fix
//  is contained here. Everything downstream — sessions, streaming,
//  compaction — only ever sees the app's own `ChatSession` protocol.
//
//  WHY THE SESSION NO LONGER GOES THROUGH THE FRAMEWORK BRIDGE
//  (checked against the pinned mlx-swift-lm 3.32.3 sources,
//  2026-10-23): Phases 3–4 built the session as
//  `LanguageModelSession(model: MLXLanguageModel(...))`. That bridge
//  is convenient, but it builds its `GenerateParameters` internally
//  from Foundation Models' `GenerationOptions` — response length,
//  temperature, sampling, seed — and nothing else. There is no
//  surface on `MLXLanguageModel`, on its executor configuration, or
//  on `GenerationOptions` for KV-cache configuration, so the
//  Settings KV-cache mode could never reach the cache that way.
//
//  So the session is now the MLX library's own `ChatSession`
//  (MLXLMCommon), created with `GenerateParameters` that carry the
//  cache configuration from the start. The model *loading* still
//  goes through the bridge value: `MLXLanguageModel.loadContainer()`
//  is public, shares the bridge's process-wide model cache, and
//  resolves LLM/VLM factories exactly as the framework path did —
//  downloads, disk checks, and load behavior are unchanged from
//  Phase 3. Only the conversation object changed hands.
//
//  If `MLXLanguageModel(modelID:)` doesn't resolve in the shipped
//  bridge version, the documented alternative construction is:
//
//      import MLXLMCommon // for ModelConfiguration
//      let model = #huggingFaceLanguageModel(
//          configuration: ModelConfiguration(id: info.repoID),
//          capabilities: [.guidedGeneration])
//
//  (a macro from the same package). It produces the same
//  `MLXLanguageModel` value, so `loadContainer()` below is
//  unaffected by which construction is used.
// ============================================================

/// A downloaded local MLX model as a backend.
struct MLXBackend: ModelBackend {

    let info: MLXModelInfo

    /// The Settings KV-cache mode these sessions are created with.
    /// Fixed at creation: a mode change produces a new backend (via
    /// `BackendFactory`) and the engine retires the old session, so
    /// a session's cache configuration can never change under it —
    /// the library forbids that too (see `MLXChatSession`).
    var kvCacheMode: KVCacheMode = .defaultMode

    var selection: ModelSelection { .mlx(repoID: info.repoID) }
    var displayName: String { info.displayName }
    var budget: ContextBudget { .mlxLocal }
    /// Phase 5: MLX sessions take tools natively (see the tool wiring
    /// in `MLXChatSession` / `MLXToolSupport` below).
    var supportsTools: Bool { true }

    @MainActor
    func makeSession(instructions: String, tools: SessionTools?) -> ChatSession {
        MLXChatSession(
            model: MLXLanguageModel(modelID: info.repoID),
            instructions: instructions,
            generateParameters: Self.generateParameters(for: kvCacheMode),
            tools: tools)
    }

    /// Translates the pure `KVCacheMode` mapping into the library's
    /// generation parameters. Only the cache fields differ from the
    /// defaults; everything else keeps the library's standard chat
    /// behavior — including the response-length cap: the framework
    /// bridge capped replies at 4,096 tokens when the app set no
    /// limit of its own (its executor's default), so the same cap is
    /// set here to keep reply behavior unchanged by the move.
    ///
    /// Cache configuration notes (mlx-swift-lm 3.32.3):
    /// - The typed `kvCache` field is the library's canonical path;
    ///   it must not be combined with the legacy `kvBits`-style
    ///   fields, and this function never sets both.
    /// - `.eightBit` / `.fourBit` are the library's presets for the
    ///   exact numbers `KVCacheMode.parameters` specifies (that many
    ///   bits, group size 64, compress from token 0).
    /// - Compatibility is `.allowPartial`: quantize the layers that
    ///   support it and leave the rest unchanged. That matters for
    ///   Gemma — its sliding-window attention layers keep their
    ///   architecture-defined window (their cache is bounded by
    ///   design), while the full-attention layers, whose cache is
    ///   the part that grows to several GB, take the compression.
    ///   The strict policies would instead refuse to generate on a
    ///   hybrid model unless every (or at least one) layer matched.
    /// - Off means `kvCache` stays nil: the library's default,
    ///   a full-precision cache.
    static func generateParameters(for mode: KVCacheMode)
        -> GenerateParameters {
        var parameters = GenerateParameters(maxTokens: 4096)
        let mapping = mode.parameters
        if let bits = mapping.bits {
            let affine: AffineKVCacheConfiguration =
                bits == 4 ? .fourBit : .eightBit
            parameters.kvCache = KVCacheConfiguration(
                strategy: .affine(affine),
                compatibility: .allowPartial)
        }
        return parameters
    }
}

/// A `ChatSession` over the MLX library's own `ChatSession`.
///
/// The wrapper exists because the two session shapes differ in
/// exactly three ways, all absorbed here:
///
/// - **Creation timing.** The engine creates sessions synchronously,
///   but a `ModelContainer` loads asynchronously. Like the framework
///   session (which also deferred the real load to first use), the
///   container load and the library session's creation happen lazily
///   on the first `streamReply`; a load failure surfaces as that
///   reply's error, in the engine's usual plain-English banner.
/// - **Streaming shape.** The library yields *new text chunks*; the
///   app's protocol yields the reply *so far*. The wrapper
///   accumulates, so downstream everything is identical.
/// - **Images.** Framework backends take a `Prompt` with attachments;
///   the library takes `UserInput.Image` values. The same temporary
///   file URLs the engine already writes map straight across.
///
/// The cache configuration is baked into `generateParameters` at
/// creation and never mutated afterwards: the library pins the cache
/// plan to the session and throws `kvCacheConfigurationChanged` if a
/// later send disagrees — one more reason the engine retires the
/// whole session when the Settings mode changes.
@MainActor
final class MLXChatSession: ChatSession {

    private let model: MLXLanguageModel
    private let instructions: String
    private let generateParameters: GenerateParameters
    /// Phase 5: the session's tool set, if any. Handed to the library
    /// session at creation (its specs + dispatch below); changing the
    /// tool set means a new session, which is exactly how the engine
    /// treats a settings change (the live-session signature covers it).
    private let tools: SessionTools?

    /// The library session, created on first use; also the in-flight
    /// container load, shared so two first sends in a row can't load
    /// or create twice.
    private var librarySession: MLXLMCommon.ChatSession?
    /// The shared container load, tagged with an identity so a
    /// FAILED load can be cleared by its own waiters — and only by
    /// them (audit B-42): a waiter resuming late must not clear a
    /// newer retry's task.
    private var containerLoad: (id: UUID, task: Task<ModelContainer, Error>)?

    init(model: MLXLanguageModel,
         instructions: String,
         generateParameters: GenerateParameters,
         tools: SessionTools? = nil) {
        self.model = model
        self.instructions = instructions
        self.generateParameters = generateParameters
        self.tools = tools
    }

    func streamReply(to request: ChatReplyRequest)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = try await self.librarySession()
                    let images = request.imageURLs.map {
                        UserInput.Image.url($0)
                    }
                    var fullText = ""
                    for try await chunk in session.streamResponse(
                        to: request.promptText, images: images) {
                        fullText += chunk
                        continuation.yield(fullText)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Loads the container (through the bridge value, so the shared
    /// model cache and download state are the same ones the rest of
    /// the app uses) and builds the library session, once.
    private func librarySession() async throws -> MLXLMCommon.ChatSession {
        if let librarySession { return librarySession }
        let container = try await loadContainer()
        // Another send may have created the session while this one
        // was loading; the check-and-set has no suspension between,
        // so exactly one session is ever created.
        if let librarySession { return librarySession }
        let created = MLXLMCommon.ChatSession(
            container,
            instructions: instructions,
            generateParameters: generateParameters,
            tools: toolSpecs,
            toolDispatch: toolDispatch)
        librarySession = created
        return created
    }

    /// The library's tool specs for this session's tool set, or nil
    /// when there is no tool set — or when spec construction fails,
    /// which degrades this session to no-tools rather than no-chat
    /// (the documented Phase 5 fallback; the on-device model remains
    /// the primary tools engine).
    private var toolSpecs: [ToolSpec]? {
        guard let tools, !tools.descriptors.isEmpty else { return nil }
        return MLXToolSupport.specs(for: tools.descriptors)
    }

    /// Dispatches the library's tool calls into the shared app
    /// runtime — the same logging/gating/clamping path the framework
    /// backend uses. Only installed when specs exist.
    private var toolDispatch: (@Sendable (ToolCall) async throws -> String)? {
        guard let tools, toolSpecs != nil else { return nil }
        let runtime = tools.runtime
        return { call in
            await runtime.execute(
                toolName: call.function.name,
                arguments: MLXToolSupport.arguments(from: call))
        }
    }

    private func loadContainer() async throws -> ModelContainer {
        // Audit B-42: a failed load is NOT cached. The old code kept
        // the completed, failed task forever, so every later send
        // re-threw the same transient error and the conversation's
        // MLX route never recovered. On failure the waiter clears
        // the entry (only if it is still the load it awaited) and
        // the next send retries from scratch. The success path is
        // unchanged: one shared task, created once — the
        // double-checked single creation in `librarySession()` is
        // preserved.
        let load: (id: UUID, task: Task<ModelContainer, Error>)
        if let containerLoad {
            load = containerLoad
        } else {
            let model = self.model
            let created = (id: UUID(),
                           task: Task { try await model.loadContainer() })
            containerLoad = created
            load = created
        }
        do {
            return try await load.task.value
        } catch {
            if containerLoad?.id == load.id {
                containerLoad = nil
            }
            throw error
        }
    }
}

/// Phase 5: bridging the app's tool definitions to the MLX library's
/// tool support.
///
/// The library's `ChatSession` accepts `tools: [ToolSpec]?` and a
/// `toolDispatch` closure — and it is fail-closed: only calls naming a
/// function declared in the specs reach the dispatch. Verified against
/// the pinned mlx-swift-lm sources (Libraries/MLXLMCommon/
/// ChatSession.swift): dispatch "is required for toolcalls if
/// streaming strings rather than details", which is exactly this
/// session's shape.
///
/// `ToolSpec` is Codable in the library (it's what gets rendered into
/// the chat template), so specs are built by JSON-decoding the
/// standard function shape rather than depending on a memberwise
/// initializer. If that decode ever fails, `specs(for:)` returns nil
/// and the session runs without tools — chatting is never held
/// hostage to tool plumbing.
enum MLXToolSupport {

    static func specs(for descriptors: [ToolDescriptor]) -> [ToolSpec]? {
        var specs: [ToolSpec] = []
        for descriptor in descriptors {
            var properties: [String: Any] = [:]
            for field in descriptor.argumentFields {
                properties[field.rawValue] = [
                    "type": field.jsonType,
                    "description": field.fieldDescription
                ]
            }
            let object: [String: Any] = [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.modelDescription,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": [String]()
                    ]
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let spec = try? JSONDecoder().decode(ToolSpec.self, from: data)
            else { return nil }
            specs.append(spec)
        }
        return specs.isEmpty ? nil : specs
    }

    /// The library's call arguments (`[String: AnyCodable]`) in the
    /// app's one argument shape.
    static func arguments(from call: ToolCall) -> ToolArguments {
        var values: [String: ToolArgumentValue] = [:]
        for (key, wrapped) in call.function.arguments {
            if let value = argumentValue(wrapped.value) {
                values[key] = value
            }
        }
        return ToolArguments(values: values)
    }

    private static func argumentValue(_ any: Any) -> ToolArgumentValue? {
        switch any {
        case let string as String: return .string(string)
        case let bool as Bool: return .bool(bool)
        case let int as Int: return .int(int)
        case let double as Double: return .double(double)
        case let number as NSNumber: return .double(number.doubleValue)
        default: return nil
        }
    }
}
