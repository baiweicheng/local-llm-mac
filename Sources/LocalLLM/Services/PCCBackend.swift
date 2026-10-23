import Foundation
import FoundationModels

// ============================================================
//  Phase 8: Apple's Private Cloud Compute as a backend.
//
//  PCC is the framework's own cloud model: a
//  `PrivateCloudComputeLanguageModel` in an ordinary
//  `LanguageModelSession` — the same shape as the on-device
//  backend, with a 32K context budget and Apple's server model
//  behind it. No API key, no account: macOS decides eligibility
//  (Apple Intelligence on, an eligible device and region), and
//  the framework enforces PCC's privacy design — requests are
//  processed on Apple's servers without being stored or used
//  for training.
//
//  Two app-level rules sit on top of that, both enforced before
//  anything reaches this file: Local Only refuses PCC outright
//  (it is off-device — "local" means local), and the privacy
//  firewall scrubs everything sent to it, tool results included,
//  exactly like any other cloud destination (see `ChatEngine`).
//
//  This file and `PCCAvailabilityReader` are the only places
//  that name the PCC model type, so if its construction or
//  availability surface needs adjusting at first compile, the
//  fix is contained here.
// ============================================================

/// Whether Private Cloud Compute can chat right now, in the same
/// plain terms the app shell feeds the picker and the router.
enum PCCAvailabilityReader {

    /// True when macOS offers PCC. Mirrors how
    /// `ModelAvailabilityState` reads the on-device model: the
    /// model value's availability, with anything unrecognized
    /// treated as "not ready" rather than guessed at.
    static var isReady: Bool {
        switch PrivateCloudComputeLanguageModel.default.availability {
        case .available:
            return true
        default:
            return false
        }
    }
}

/// Apple's Private Cloud Compute — the no-key cloud backend.
struct PCCBackend: ModelBackend {
    var selection: ModelSelection { .privateCloudCompute }
    var displayName: String { "Apple Private Cloud" }
    var budget: ContextBudget { .privateCloudCompute }
    /// PCC sessions are framework sessions, so they take the app's
    /// tools like the on-device model's do — with one difference
    /// the ENGINE owns: tool results bound for this backend pass
    /// the privacy check first (the runtime's redaction flag),
    /// because the results are leaving the Mac.
    var supportsTools: Bool { true }

    @MainActor
    func makeSession(instructions: String, tools: SessionTools?) -> ChatSession {
        let model = PrivateCloudComputeLanguageModel()
        if let tools, !tools.descriptors.isEmpty {
            let frameworkTools: [any Tool] = tools.descriptors.map { descriptor in
                FrameworkTool(name: descriptor.name,
                              description: descriptor.modelDescription,
                              runtime: tools.runtime)
            }
            return FrameworkChatSession(session: LanguageModelSession(
                model: model, tools: frameworkTools,
                instructions: instructions))
        }
        return FrameworkChatSession(session: LanguageModelSession(
            model: model, instructions: instructions))
    }
}
