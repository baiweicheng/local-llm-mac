import Foundation

/// The app's privacy settings (Phase 4), persisted in UserDefaults:
///
/// - **Local Only** — the privacy lock. When on, server backends are
///   refused (in `BackendFactory`, not just hidden in the UI), Auto
///   never routes to a network destination, and only models that run
///   on this Mac may answer.
/// - **Custom redaction terms** — the user's own additions to the
///   privacy check: words or phrases (a project codename, an employer,
///   an address) that `Redactor` hides before anything is sent to a
///   server that isn't on this Mac.
///
/// Same storage pattern as `EndpointStore`: plain UserDefaults keys,
/// saved on every change.
///
/// It also carries the one non-privacy setting that exists so far:
/// the **KV-cache mode** for downloaded MLX models (see
/// `KVCacheMode`) — how much memory a local model's conversation
/// memory may use. It lives here, rather than in a second settings
/// object, because this sheet is the app's settings surface until the
/// Phase 10 settings window arrives.
@MainActor
@Observable
final class AppSettings {

    /// The Local Only lock. Persisted the moment it changes.
    var localOnly: Bool {
        didSet { defaults.set(localOnly, forKey: Self.localOnlyKey) }
    }

    /// The KV-cache mode for MLX models (Off / 8-bit / 4-bit,
    /// default 8-bit). Persisted the moment it changes. Changing it
    /// retires live MLX sessions — the engine rebuilds them under
    /// the new mode on the next send; the built-in model and local
    /// servers are unaffected (they manage their own caches).
    var kvCacheMode: KVCacheMode {
        didSet {
            defaults.set(kvCacheMode.storedValue,
                         forKey: Self.kvCacheModeKey)
        }
    }

    /// The user's custom redaction terms, in the order they added
    /// them. Change via `addRedactionTerm` / `removeRedactionTerm` so
    /// the list stays trimmed and duplicate-free.
    private(set) var customRedactionTerms: [String]

    /// Phase 5: which visibility sources the user has turned on —
    /// the "What this app can see" toggles. Every source starts OFF
    /// and nothing is ever looked at until the user enables it;
    /// persisted as the set of source raw values.
    private(set) var enabledVisibilitySources: Set<VisibilitySource>

    /// Phase 6: the file-writing master switch — separate from the
    /// read toggles above, default OFF. While off, the file-action
    /// tools (rename/move/copy/create/edit/trash/resize) don't exist
    /// for any model; while on, they exist but only PROPOSE changes
    /// inside the shared folders, and every proposal still needs the
    /// user's approval in the chat before anything changes.
    var fileWritingEnabled: Bool {
        didSet { defaults.set(fileWritingEnabled, forKey: Self.fileWritingKey) }
    }

    private let defaults: UserDefaults

    private static let localOnlyKey = "LocalLLM.localOnly.v1"
    private static let redactionTermsKey = "LocalLLM.redactionTerms.v1"
    private static let kvCacheModeKey = "LocalLLM.kvCacheMode.v1"
    private static let visibilitySourcesKey = "LocalLLM.visibilitySources.v1"
    private static let fileWritingKey = "LocalLLM.fileWriting.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.localOnly = defaults.bool(forKey: Self.localOnlyKey)
        self.fileWritingEnabled = defaults.bool(forKey: Self.fileWritingKey)
        self.kvCacheMode = KVCacheMode(
            storedValue: defaults.string(forKey: Self.kvCacheModeKey))
        if let stored = defaults.stringArray(forKey: Self.redactionTermsKey) {
            self.customRedactionTerms = stored
        } else {
            self.customRedactionTerms = []
        }
        let storedSources = defaults.stringArray(forKey: Self.visibilitySourcesKey) ?? []
        self.enabledVisibilitySources = Set(
            storedSources.compactMap(VisibilitySource.init(rawValue:)))
    }

    // MARK: - Visibility sources (Phase 5)

    func isSourceEnabled(_ source: VisibilitySource) -> Bool {
        enabledVisibilitySources.contains(source)
    }

    /// Toggle one source. Turning a source on is what makes its tools
    /// exist for new chat sessions (the Settings panel requests the
    /// system permission at the same moment, when the source has one).
    func setSourceEnabled(_ source: VisibilitySource, _ enabled: Bool) {
        if enabled {
            enabledVisibilitySources.insert(source)
        } else {
            enabledVisibilitySources.remove(source)
        }
        defaults.set(enabledVisibilitySources.map(\.rawValue).sorted(),
                     forKey: Self.visibilitySourcesKey)
    }

    var anyVisibilitySourceEnabled: Bool {
        !enabledVisibilitySources.isEmpty
    }

    /// Adds a term (trimmed; blank entries and duplicates — ignoring
    /// case — are refused). Terms shorter than
    /// `Redactor.minimumCustomTermLength` are accepted here but the
    /// redactor ignores them, and Settings says so.
    func addRedactionTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !customRedactionTerms.contains(
                where: { $0.lowercased() == trimmed.lowercased() })
        else { return }
        customRedactionTerms.append(trimmed)
        persistTerms()
    }

    func removeRedactionTerm(_ term: String) {
        customRedactionTerms.removeAll { $0 == term }
        persistTerms()
    }

    private func persistTerms() {
        defaults.set(customRedactionTerms, forKey: Self.redactionTermsKey)
    }
}
