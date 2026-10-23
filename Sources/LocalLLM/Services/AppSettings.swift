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
/// Alongside the privacy settings it carries the app's general
/// settings as the phases added them: the KV-cache mode for
/// downloaded MLX models (Phase 4, see `KVCacheMode`), the source
/// toggles (Phase 5), the file-changes and power-tools switches
/// (Phases 6 and 9), the quick-panel switch (Phase 7), the custom
/// OpenRouter model id (Phase 8), and — completing the sheet in
/// Phase 10 — the **default model for new chats** and the
/// **instructions library** (`instructionPresets`). "Open at login"
/// deliberately does NOT live here: its truth is the system's
/// login-item state, read live by `LoginItemService`.
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

    /// Phase 9: the power-tools master switch — default OFF, and
    /// separate from every other switch in this file. While off,
    /// the shell tool and every MCP server tool don't exist for any
    /// model. While on, they exist but only PROPOSE: each command
    /// and each server call still lands on the chat's approval list
    /// and runs only when the user approves it there — and neither
    /// can be undone, which the approval list says up front.
    var powerToolsEnabled: Bool {
        didSet { defaults.set(powerToolsEnabled, forKey: Self.powerToolsKey) }
    }

    /// Phase 7: the quick panel's hotkey (⌘⇧Space). Default ON —
    /// but stored via the object-presence check in `init`, because
    /// `UserDefaults.bool` can't tell "never set" from "set to
    /// false". The HUD coordinator watches this property and
    /// (un)registers the Carbon hotkey the moment it changes.
    var hudEnabled: Bool {
        didSet { defaults.set(hudEnabled, forKey: Self.hudEnabledKey) }
    }

    /// Phase 8: a custom OpenRouter model id, typed by the user in
    /// Settings → Cloud models — any model on OpenRouter, beyond
    /// the curated shortlist. Empty means none. (The API KEY never
    /// lives here — it's in the Keychain; see `OpenRouterKeyStore`.)
    var openRouterCustomModelID: String {
        didSet { defaults.set(openRouterCustomModelID,
                              forKey: Self.openRouterCustomModelKey) }
    }

    /// Phase 10: the model new chats start with, stored as a
    /// `ModelSelection` storage key. Auto (the Phase 4 behavior)
    /// unless the user picks a specific backend in Settings →
    /// General. Only the sidebar's New Chat applies it: the quick
    /// panel always starts on Auto (its design), and compare mode
    /// seeds its winner explicitly. Existing chats keep theirs.
    var defaultModelRaw: String {
        didSet { defaults.set(defaultModelRaw,
                              forKey: Self.defaultModelKey) }
    }

    /// The typed view of `defaultModelRaw`. Setting it persists
    /// through the raw string's `didSet`. An unrecognized stored
    /// value reads back as the built-in model — the same forgiving
    /// codec every chat's selection uses.
    var defaultModelSelection: ModelSelection {
        get { ModelSelection(storageKey: defaultModelRaw) }
        set { defaultModelRaw = newValue.storageKey }
    }

    /// Phase 10: the instructions library — named, reusable sets of
    /// system instructions, managed in Settings and applied to a
    /// chat from its instructions editor (applying copies the text
    /// into the chat). Change via the add/update/remove methods so
    /// the naming rules (`InstructionPresetRules`) hold everywhere.
    private(set) var instructionPresets: [InstructionPreset]

    private let defaults: UserDefaults

    private static let localOnlyKey = "LocalLLM.localOnly.v1"
    private static let redactionTermsKey = "LocalLLM.redactionTerms.v1"
    private static let kvCacheModeKey = "LocalLLM.kvCacheMode.v1"
    private static let visibilitySourcesKey = "LocalLLM.visibilitySources.v1"
    private static let fileWritingKey = "LocalLLM.fileWriting.v1"
    private static let powerToolsKey = "LocalLLM.powerTools.v1"
    private static let hudEnabledKey = "LocalLLM.hudEnabled.v1"
    private static let openRouterCustomModelKey = "LocalLLM.openRouterCustomModel.v1"
    private static let defaultModelKey = "LocalLLM.defaultModel.v1"
    private static let instructionPresetsKey = "LocalLLM.instructionPresets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.localOnly = defaults.bool(forKey: Self.localOnlyKey)
        self.fileWritingEnabled = defaults.bool(forKey: Self.fileWritingKey)
        self.powerToolsEnabled = defaults.bool(forKey: Self.powerToolsKey)
        self.openRouterCustomModelID =
            defaults.string(forKey: Self.openRouterCustomModelKey) ?? ""
        // Default ON: only an explicitly stored value can turn the
        // quick panel off.
        self.hudEnabled = defaults.object(forKey: Self.hudEnabledKey) as? Bool
            ?? true
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
        self.defaultModelRaw = defaults.string(forKey: Self.defaultModelKey)
            ?? ModelSelection.auto.storageKey
        if let rawPresets = defaults.data(forKey: Self.instructionPresetsKey) {
            self.instructionPresets = InstructionPresetCodec.decode(rawPresets)
        } else {
            self.instructionPresets = []
        }
    }

    // MARK: - Instructions library (Phase 10)

    /// Adds a preset. Returns the saved preset, or nil when the
    /// naming rules refuse it (blank name or text, or another preset
    /// already carries the name — ignoring case).
    @discardableResult
    func addInstructionPreset(name: String, text: String) -> InstructionPreset? {
        guard InstructionPresetRules.canSave(
                name: name, text: text, existing: instructionPresets)
        else { return nil }
        let preset = InstructionPreset(
            name: InstructionPresetRules.cleanedName(name),
            text: InstructionPresetRules.cleanedText(text))
        instructionPresets.append(preset)
        persistPresets()
        return preset
    }

    /// Replaces a preset's name and text. False when the id is
    /// unknown or the naming rules refuse the edit.
    @discardableResult
    func updateInstructionPreset(id: UUID, name: String, text: String) -> Bool {
        guard let index = instructionPresets.firstIndex(where: { $0.id == id }),
              InstructionPresetRules.canSave(
                name: name, text: text, existing: instructionPresets,
                excludingID: id)
        else { return false }
        instructionPresets[index].name = InstructionPresetRules.cleanedName(name)
        instructionPresets[index].text = InstructionPresetRules.cleanedText(text)
        persistPresets()
        return true
    }

    func removeInstructionPreset(id: UUID) {
        instructionPresets.removeAll { $0.id == id }
        persistPresets()
    }

    private func persistPresets() {
        if let data = InstructionPresetCodec.encode(instructionPresets) {
            defaults.set(data, forKey: Self.instructionPresetsKey)
        }
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
