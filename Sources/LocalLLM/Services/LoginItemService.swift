import Foundation
import ServiceManagement

/// Phase 10: "Open at login", backed by `SMAppService` — the one
/// supported way for an app to register itself as a login item.
/// Kept deliberately thin: the truth about whether the app opens
/// at login lives in the system (not in a settings flag that could
/// drift from reality), so this reads `SMAppService.mainApp.status`
/// every time and reports it in plain English.
///
/// Honest limits, surfaced rather than hidden: registration only
/// works for a real app bundle — the packaged app built by
/// Scripts/make-app.sh, sitting in Applications. Running from Xcode
/// (or any unbundled copy) reports `.unavailable`, and the Settings
/// toggle is disabled with the reason shown. macOS may also ask
/// the user to approve the login item in System Settings — that's
/// the `.requiresApproval` state below, with directions.
enum LoginItemState: Equatable {
    case enabled
    case disabled
    /// Registered, but macOS is waiting for the user to approve it
    /// under System Settings → General → Login Items.
    case requiresApproval
    /// The system can't register this copy of the app (not running
    /// as an app bundle, e.g. launched from Xcode).
    case unavailable

    /// What the Settings toggle shows as its position.
    var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .disabled, .unavailable: return false
        }
    }

    /// The plain-English line under the toggle.
    var explanation: String {
        switch self {
        case .enabled:
            return "The app opens when you log in, so the quick panel (⌘⇧Space) is always a keystroke away."
        case .disabled:
            return "The app only runs when you open it yourself."
        case .requiresApproval:
            return "Almost there — macOS wants you to approve the app under System Settings → General → Login Items before it will open at login."
        case .unavailable:
            return "Login items only work for the packaged app (built with Scripts/make-app.sh) sitting in your Applications folder — this copy of the app isn't running as one, so the switch can't be used."
        }
    }
}

enum LoginItemService {

    static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Registers or unregisters the app. Returns nil on success, or
    /// a plain-English explanation of what went wrong.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't change the login setting: \(error.localizedDescription) "
                + "If this keeps happening, check System Settings → General → Login Items."
        }
    }
}
