import Foundation
import FoundationModels

/// The on-device model's readiness, translated into plain English.
///
/// `SystemLanguageModel.default.availability` is the source of truth; this
/// enum is what the UI actually renders, so every state the user can hit has
/// a human explanation and a next step — never a raw system code.
enum ModelAvailabilityState: Equatable, Sendable {
    /// Ready to chat.
    case available
    /// Apple Intelligence is turned off in System Settings.
    case appleIntelligenceNotEnabled
    /// This Mac can't run Apple Intelligence at all.
    case deviceNotEligible
    /// The model is still downloading or warming up.
    case modelNotReady
    /// A future/unrecognized system state — chat stays disabled, and the
    /// message says so honestly instead of guessing.
    case unknown

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                self = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                self = .appleIntelligenceNotEnabled
            case .modelNotReady:
                self = .modelNotReady
            default:
                self = .unknown
            }
        default:
            // A future macOS adding an availability case shouldn't break
            // the build — treat anything unrecognized as "unknown".
            self = .unknown
        }
    }

    /// The state of the model on this machine, right now.
    static var current: ModelAvailabilityState {
        ModelAvailabilityState(SystemLanguageModel.default.availability)
    }

    var canChat: Bool {
        self == .available
    }

    /// Short label for the status pill in the chat header.
    var headline: String {
        switch self {
        case .available:
            return "On-device model ready"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off"
        case .deviceNotEligible:
            return "Not available on this Mac"
        case .modelNotReady:
            return "Model is getting ready"
        case .unknown:
            return "Model unavailable"
        }
    }

    /// One or two plain sentences: what's happening and what to do.
    var explanation: String {
        switch self {
        case .available:
            return "Chats run entirely on this Mac — free, offline, and private."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings, then come back here. This app uses the on-device model built into macOS, and it stays off until you enable it."
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence, so the built-in on-device model can't run here."
        case .modelNotReady:
            return "macOS is still downloading or preparing the on-device model. This usually finishes on its own — leave the Mac plugged in and connected, then try again in a little while."
        case .unknown:
            return "The on-device model reports a state this version of the app doesn't recognize. Restarting the app is worth a try."
        }
    }
}
