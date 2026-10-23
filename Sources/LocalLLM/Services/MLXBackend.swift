import Foundation
import FoundationModels
import MLXFoundationModels

// ============================================================
//  THE ONLY FILE THAT TALKS TO MLX.
//
//  Every MLX-specific symbol in the app lives in `makeSession` below,
//  so if the MLX bridge's API needs adjusting at first compile, the
//  fix is contained to this one function. Everything downstream —
//  sessions, streaming, compaction — only ever sees the framework's
//  `LanguageModelSession`, identical to the on-device backend.
//
//  What the bridge is (checked against the package's own docs,
//  2026-10-23): `MLXFoundationModels`, a product of the open-source
//  `mlx-swift-lm` package (github.com/ml-explore/mlx-swift-lm),
//  provides `MLXLanguageModel`, which conforms to the framework's
//  `LanguageModel` protocol. Build one from a Hugging Face repo id,
//  hand it to `LanguageModelSession(model:)`, and from there the
//  session behaves exactly like the built-in model's.
//
//  If `MLXLanguageModel(modelID:)` doesn't resolve in the shipped
//  bridge version, the documented alternative construction is:
//
//      import MLXLMCommon // for ModelConfiguration
//      let model = #huggingFaceLanguageModel(
//          configuration: ModelConfiguration(id: info.repoID),
//          capabilities: [.guidedGeneration])
//
//  (a macro from the same package; MLXLMCommon is already a target
//  dependency for exactly this reason).
// ============================================================

/// A downloaded local MLX model as a backend.
struct MLXBackend: ModelBackend {

    let info: MLXModelInfo

    var selection: ModelSelection { .mlx(repoID: info.repoID) }
    var displayName: String { info.displayName }
    var budget: ContextBudget { .mlxLocal }

    @MainActor
    func makeSession(instructions: String) -> ChatSession {
        let model = MLXLanguageModel(modelID: info.repoID)
        let session = LanguageModelSession(model: model,
                                           instructions: instructions)
        return FrameworkChatSession(session: session)
    }
}
