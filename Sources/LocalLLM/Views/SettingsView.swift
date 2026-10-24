import AppKit
import SwiftData
import SwiftUI

/// The app's Settings sheet, opened from the gear button in the
/// chat header. It began in Phase 4 as the privacy page (the Local
/// Only lock and the custom terms for the privacy check) and grew a
/// section per phase; Phase 10 completes it with the two general
/// sections on top — **General** (the default model for new chats,
/// open at login) and the **Instructions library** — so everything
/// the app can be told lives in this one sheet.
///
/// Phase 5 adds the visibility panel — "What this app can see": one
/// toggle per source, its permission state with plain-English
/// guidance, the shared-folder picker, and the access log ("Recent
/// lookups"). This sheet is where visibility is granted; chats only
/// ever consume what was granted here.
///
/// Phase 6 adds "File changes": the separate, default-off switch
/// that lets models PROPOSE file changes inside the shared folders
/// (approval still happens in the chat, never here), and the log
/// becomes "Recent activity" — lookups and file changes together.
///
/// Phase 8 adds "Cloud models": what Private Cloud Compute is, the
/// OpenRouter key field (the key goes straight to the Mac's
/// Keychain — this view never displays it back), the curated model
/// list, and the custom model id.
///
/// Phase 9 adds "Power tools": the master switch for the shell tool
/// and the MCP client, the plain-English warnings that belong with
/// it, and the MCP server list (add/remove/enable, per-server
/// status, retry) — servers are configured here; starting them
/// happens lazily, from chats.
///
/// Phase 10 adds "General" (default model for new chats — the same
/// backend registry the chat header's picker uses, supplied by the
/// two model stores passed in here — and open at login, whose state
/// is read live from the system via `LoginItemService`) and the
/// "Instructions library" (named instruction sets, applied to chats
/// from their instructions editor).
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let fileScopeStore: FileScopeStore
    let permissionCenter: PermissionCenter
    let openRouterKeyStore: OpenRouterKeyStore
    let mcpServerStore: MCPServerStore
    let mcpManager: MCPServerManager
    /// Phase 10: the model stores the default-model picker reads,
    /// so its rows are exactly the chat picker's rows.
    let mlxStore: MLXModelStore
    let endpointStore: EndpointStore
    /// Audit B-58: the quick-panel coordinator, read here only for
    /// its hotkey-registration failure state (shown in the Quick
    /// panel section below when the shortcut couldn't be taken).
    let hudCoordinator: HUDCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The access log, newest first. The engine rotates it to
    /// `AccessLogPolicy.maxRecords`; the panel shows the latest few.
    @Query(sort: \ToolActivityRecord.createdAt, order: .reverse)
    private var recentRecords: [ToolActivityRecord]

    /// Audit S-04: decided plan records live beside the access log
    /// and are cleared with it — Clear Log previously left every
    /// plan's full payloads behind.
    @Query(sort: \ActionPlanRecord.createdAt, order: .reverse)
    private var recentPlanRecords: [ActionPlanRecord]

    @State private var newTerm = ""
    /// The OpenRouter key as typed, held only until Save hands it
    /// to the Keychain; the field then clears. The saved key is
    /// never read back into this field.
    @State private var keyDraft = ""
    /// Audit S-10: set when a key save fails in the Keychain, so
    /// the failure is said out loud instead of silently losing it.
    @State private var keySaveError: String?
    /// Audit E-16: the custom OpenRouter model id is edited as a
    /// LOCAL DRAFT and committed to the persisted setting on submit
    /// / when the sheet goes away — binding the field straight to
    /// `settings` wrote UserDefaults (and invalidated every reader
    /// of the id, including the chat header's descriptors) on EVERY
    /// keystroke, and made half-typed ids the live picker value.
    @State private var customModelIDDraft: String?
    /// Phase 9: the MCP add-server form's drafts.
    @State private var mcpName = ""
    @State private var mcpCommand = ""
    @State private var mcpArguments = ""
    /// Phase 10: the instructions-library form's drafts, and which
    /// preset (if any) is loaded into it for editing.
    @State private var presetName = ""
    @State private var presetText = ""
    @State private var editingPresetID: UUID?
    /// Phase 10: the login item's state, read live from the system
    /// (never stored — see `LoginItemService`), plus the last
    /// change's error, if any.
    @State private var loginItemState: LoginItemState = .disabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    generalSection
                    Divider()
                    instructionsLibrarySection
                    Divider()
                    localOnlySection
                    Divider()
                    redactionSection
                    Divider()
                    cloudSection
                    Divider()
                    kvCacheSection
                    Divider()
                    visibilitySection
                    Divider()
                    fileChangesSection
                    Divider()
                    powerToolsSection
                    Divider()
                    quickPanelSection
                    Divider()
                    accessLogSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 620)
        .task {
            permissionCenter.refresh()
            loginItemState = LoginItemService.state
        }
        .onDisappear { commitCustomModelID() }
    }

    // MARK: - General (Phase 10)

    /// The backend rows for the default-model picker — the same
    /// registry the chat header's picker uses, so the two can never
    /// disagree about what exists.
    private var descriptors: [BackendDescriptor] {
        BackendRegistry.descriptors(
            downloadedMLX: mlxStore.downloadedModels,
            endpoints: endpointStore.configs,
            onDeviceReady: ModelAvailabilityState.current.canChat,
            cloud: CloudPickerInputs(
                pccReady: PCCAvailabilityReader.isReady,
                openRouterKeyPresent: openRouterKeyStore.hasKey,
                customOpenRouterModelID: settings.openRouterCustomModelID))
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General")
                .font(.headline)
            Text("Default model for new chats")
                .font(.subheadline)
                .fontWeight(.medium)
            Picker("Default model for new chats", selection: Binding(
                get: { settings.defaultModelSelection },
                set: { settings.defaultModelSelection = $0 }
            )) {
                ForEach(descriptors) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.selection)
                }
            }
            .labelsHidden()
            .fixedSize()
            Text("New chats started from the sidebar begin with this model; chats you already have keep the model they were using, and each chat's picker can still override it. The quick panel always starts on Auto. Auto means the app picks per message — quick things on the built-in model, hard work on a bigger local or cloud model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !descriptors.contains(where: {
                $0.selection == settings.defaultModelSelection }) {
                Text("The saved default isn't in the list right now — the model it points at was removed. New chats will say so in the header and let you pick another.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
                .padding(.vertical, 2)
            Toggle(isOn: Binding(
                get: { loginItemState.isOn },
                set: { newValue in
                    loginItemError = LoginItemService.setEnabled(newValue)
                    loginItemState = LoginItemService.state
                }
            )) {
                Text("Open at login")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .disabled(loginItemState == .unavailable)
            Text(loginItemState.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Instructions library (Phase 10)

    private var instructionsLibrarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions library")
                .font(.headline)
            Text("Named sets of system instructions you can reuse across chats. Apply one from a chat's instructions editor (the quote button in its header) — the chat gets its own copy, so editing or deleting a set here never changes a chat that's already using it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.instructionPresets.isEmpty {
                Text("No instruction sets saved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.instructionPresets) { preset in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(preset.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { loadPresetIntoForm(preset) }
                            .font(.callout)
                        Button(role: .destructive) {
                            if editingPresetID == preset.id {
                                clearPresetForm()
                            }
                            settings.removeInstructionPreset(id: preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \u{201C}\(preset.name)\u{201D}")
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
                .padding(.vertical, 2)
            Text(editingPresetID == nil ? "Add an instruction set"
                                        : "Edit instruction set")
                .font(.subheadline)
                .fontWeight(.medium)
            TextField("Name (e.g. Beginner mode)", text: $presetName)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $presetText)
                .font(.body)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.3)))
            HStack(spacing: 8) {
                Button(editingPresetID == nil ? "Add Instruction Set"
                                              : "Save Changes") {
                    savePresetForm()
                }
                .disabled(!InstructionPresetRules.canSave(
                    name: presetName, text: presetText,
                    existing: settings.instructionPresets,
                    excludingID: editingPresetID))
                if editingPresetID != nil {
                    Button("Cancel Editing") { clearPresetForm() }
                }
                Spacer()
            }
        }
    }

    private func loadPresetIntoForm(_ preset: InstructionPreset) {
        editingPresetID = preset.id
        presetName = preset.name
        presetText = preset.text
    }

    private func savePresetForm() {
        if let id = editingPresetID {
            if settings.updateInstructionPreset(
                id: id, name: presetName, text: presetText) {
                clearPresetForm()
            }
        } else if settings.addInstructionPreset(
            name: presetName, text: presetText) != nil {
            clearPresetForm()
        }
    }

    private func clearPresetForm() {
        editingPresetID = nil
        presetName = ""
        presetText = ""
    }

    // MARK: - Local Only

    private var localOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.localOnly) {
                Label("Local Only", systemImage: "lock.fill")
                    .font(.headline)
            }
            Text("When this is on, only models that run on this Mac may answer — the built-in model and downloaded MLX models. Server backends (even ones on this Mac) and both cloud backends are refused: Local Only means nothing leaves this Mac, and Apple Private Cloud runs on Apple's servers, so it counts as leaving. Auto never routes out, and a chat that was using a server or cloud model switches to the built-in model with a note explaining why.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Power tools are paused while this is on, too: an approved shell command or MCP server call can reach the network itself, so commands and server calls don't exist for any model until the lock is turned off.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy check terms

    private var redactionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy check")
                .font(.headline)
            Text("If a chat ever talks to a destination that isn't on this Mac (a server address you added that points somewhere else, or a cloud model — Apple Private Cloud or OpenRouter), the app first hides things that look like secrets or personal details: API keys, passwords after a label like \u{201C}password:\u{201D}, email addresses, phone numbers, and card numbers. Lookup results headed to a cloud model pass the same check. Your saved messages are never changed — only the copy that gets sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add your own words or phrases to hide — a project codename, an employer, an address. Matching ignores upper/lower case; entries shorter than \(Redactor.minimumCustomTermLength) characters are ignored, since hiding a two-letter word would mangle every message.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Word or phrase to hide", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTerm() }
                Button("Add") { addTerm() }
                    .disabled(newTerm.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
            if settings.customRedactionTerms.isEmpty {
                Text("No custom terms yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.customRedactionTerms, id: \.self) { term in
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                        Text(term)
                        Spacer()
                        Button {
                            settings.removeRedactionTerm(term)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop hiding \u{201C}\(term)\u{201D}")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func addTerm() {
        settings.addRedactionTerm(newTerm)
        newTerm = ""
    }

    // MARK: - Cloud models (Phase 8)

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloud models")
                .font(.headline)
            Text("Two cloud routes, for prompts that outgrow this Mac. Both are off-limits while Local Only is on, and everything sent to either passes the privacy check above first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Apple Private Cloud is Apple's own cloud model: it runs on Apple's servers under Apple's privacy design (nothing stored, nothing used for training), needs no key or account, and appears in the model picker as \u{201C}Apple Private Cloud\u{201D}. macOS decides whether it's available on this Mac. Chats on it can still make lookups — the results pass the privacy check before they leave.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("OpenRouter is one key that opens many frontier models, billed per reply to your OpenRouter account. Your key is stored in this Mac's Keychain — nowhere else — and is only ever sent to OpenRouter itself, as the sign-in for your requests. The app ships with no key; add yours whenever you like, and everything else keeps working without one. Each cloud reply's pill shows what it actually cost, as OpenRouter reports it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if openRouterKeyStore.hasKey {
                HStack(spacing: 8) {
                    Label("A key is saved in your Keychain", systemImage: "key.fill")
                        .font(.callout)
                    Spacer()
                    Button("Remove Key", role: .destructive) {
                        openRouterKeyStore.removeKey()
                    }
                    .font(.callout)
                }
            }
            HStack(spacing: 8) {
                SecureField(openRouterKeyStore.hasKey
                            ? "Paste a new key to replace the saved one"
                            : "Paste your OpenRouter API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }
                Button("Save Key") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
            if let keySaveError {
                Text(keySaveError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Get a key at openrouter.ai (Keys). Saving a key turns on the OpenRouter models in the picker, and lets Auto send its hardest prompts there.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The shortlist in the picker (checked against OpenRouter's model list when this version was built):")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(OpenRouterCatalog.models) { info in
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(info.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
            Text("Want a different one? Type any OpenRouter model id — it's added to the picker as its own row:")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Custom model id (e.g. x-ai/grok-4.7)",
                      text: customModelIDBinding)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitCustomModelID() }
        }
    }

    /// The custom-id field's binding: reads the draft once it
    /// exists (seeded from the persisted value), writes only the
    /// draft (audit E-16).
    private var customModelIDBinding: Binding<String> {
        Binding(
            get: { customModelIDDraft ?? settings.openRouterCustomModelID },
            set: { customModelIDDraft = $0 })
    }

    /// Commits the custom-id draft to the persisted setting — on
    /// submit and when the sheet disappears, the same moments the
    /// MCP and preset forms commit theirs.
    private func commitCustomModelID() {
        if let customModelIDDraft {
            settings.openRouterCustomModelID = customModelIDDraft
        }
    }

    private func saveKey() {
        if openRouterKeyStore.setKey(keyDraft) {
            keySaveError = nil
            keyDraft = ""
        } else {
            // Keep the draft in the field so the user can retry —
            // clearing it would pretend the save worked.
            keySaveError = "That key couldn't be saved to your Keychain — it isn't stored. Try saving again; if it keeps failing, check that your login Keychain is unlocked."
        }
    }

    // MARK: - KV cache (MLX models)

    private var kvCacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local model memory")
                .font(.headline)
            Picker("Model memory", selection: $settings.kvCacheMode) {
                ForEach(KVCacheMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("A downloaded MLX model keeps a working memory of the conversation so far (called a KV cache) so it doesn't have to re-read everything for every word. At full size that memory can grow to several gigabytes on a long chat. 8-bit stores it in half the memory with no noticeable change in answer quality — the recommended balance. 4-bit uses a quarter of the memory, with a little more quality risk. Off keeps the full-size memory.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("This applies to downloaded MLX models only — the built-in model and local servers manage their own memory. Changing it restarts the current MLX chat sessions; the conversation itself is kept and re-read, so nothing is lost.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - What this app can see (Phase 5)

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this app can see")
                .font(.headline)
            Text("Turn on a source and the model in a chat can look things up on this Mac to answer you — find a file, check what's on your calendar, look up a contact. Looking is all these switches allow — changing files is a separate switch, below. Every lookup is written to the log below and shown as a card in the chat, so nothing it sees is invisible to you.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Lookups work with the Apple On-Device model, downloaded MLX models, and Apple Private Cloud. Server chats and OpenRouter chats can't use them. When Apple Private Cloud makes a lookup, what it finds passes the privacy check above before it leaves this Mac — and under Local Only, no network model gets lookups at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(VisibilitySource.allCases, id: \.self) { source in
                sourceRow(source)
            }
            // Audit B-57: a sharing problem (a folder that couldn't
            // be saved, re-opened, or accessed) is said out loud
            // here instead of failing silently.
            if let scopeError = fileScopeStore.lastError {
                Text(scopeError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceRow(_ source: VisibilitySource) -> some View {
        let enabled = settings.isSourceEnabled(source)
        let state = permissionCenter.state(for: source)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { settings.isSourceEnabled(source) },
                set: { newValue in
                    settings.setSourceEnabled(source, newValue)
                    // Asking happens when a source is first enabled —
                    // the moment the user expects the question.
                    if newValue, source.needsSystemPermission,
                       permissionCenter.state(for: source) == .notDetermined {
                        Task { await permissionCenter.request(source) }
                    }
                }
            )) {
                Label(source.displayName, systemImage: source.symbolName)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Text(source.settingsBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
            if source.needsSystemPermission {
                HStack(spacing: 8) {
                    Text(state.settingsLabel)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    if state == .notDetermined {
                        Button("Allow…") {
                            Task { await permissionCenter.request(source) }
                        }
                        .font(.caption)
                    }
                }
                if let guidance = PermissionGuidance.text(source: source, state: state) {
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(state == .denied ? .orange : .secondary)
                }
            } else if enabled {
                Text("No macOS permission needed for this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if source == .files {
                foldersBlock
            }
        }
        .padding(.vertical, 2)
    }

    /// The shared-folder list: the ONLY places the file tools may
    /// read. Folders are granted by picking them (a security-scoped
    /// bookmark is kept), never by typing a path.
    private var foldersBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if fileScopeStore.folders.isEmpty {
                Text("No folders shared yet — file reading can't see anything until you add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fileScopeStore.folders) { folder in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                fileScopeStore.removeFolder(id: folder.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop sharing this folder")
                        }
                        // Audit B-57: a folder whose bookmark no
                        // longer resolves or grants access is OUT
                        // of scope — say so on its row.
                        if !fileScopeStore.isAvailable(folder) {
                            Text("Not available — this folder was moved, deleted, or access wasn't granted. It isn't being shared; remove it and add it again.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Button("Add Folder…") { pickFolder() }
                .font(.callout)
        }
        .padding(.leading, 20)
        .padding(.top, 2)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share Folder"
        panel.message = "The app will be able to read inside this folder — and nowhere else."
        if panel.runModal() == .OK, let url = panel.url {
            fileScopeStore.addFolder(url: url)
        }
    }

    // MARK: - File changes (Phase 6)

    private var fileChangesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File changes")
                .font(.headline)
            Text("With this on, the model can also PROPOSE file changes inside your shared folders: rename, move, copy, create a folder, write a text file, move something to the Trash, or make a smaller copy of a photo. Proposing is all it can do — every change appears as a list in the chat, and nothing happens until you press Approve there. Each change can be taken off the list first, and approved changes can be undone from their card. Changes are never allowed outside the shared folders, and nothing is ever overwritten. Proposals and results are written to the log below, like lookups.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $settings.fileWritingEnabled) {
                Text("Let the model propose file changes")
            }
            if settings.fileWritingEnabled,
               !settings.enabledVisibilitySources.contains(.files),
               !settings.enabledVisibilitySources.contains(.photos) {
                Text("Turn on Files or Photos above as well — file changes work inside the shared folders and the photo library, and both are off right now.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Power tools (Phase 9)

    private var powerToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power tools")
                .font(.headline)
            Text("The riskiest tools in the app — off by default, and off means they don't exist for any model. With this on, the model can also PROPOSE two more kinds of action, on the same approval list as file changes:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("• Run a shell command (zsh) in one of your shared folders — things like inspecting a git diff or querying a local database. You see the exact command text before anything runs; it gets at most 30 seconds.\n• Call a tool on an MCP server you've added below — programs on this Mac that offer their own tools (a filesystem server, a database server) to the model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Approving is the real safeguard, and it has limits worth knowing: there is no sandbox around an approved command or call. A command you approve runs with your own full permissions, from inside the folder shown — what it does from there is up to the command. Commands and server calls CANNOT be undone, and the list says so before you approve. Commands that look obviously destructive (force-deleting, running as root, erasing a disk, piping a download into a shell) start UNCHECKED on the list, with the reason shown — they take a deliberate extra check from you before they can run. Everything proposed, approved, skipped, or discarded is written to the log below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $settings.powerToolsEnabled) {
                Text("Let the model propose commands and server calls")
            }
            if settings.powerToolsEnabled {
                mcpServersBlock
            }
        }
    }

    /// The MCP server list: the user's own servers, each with its
    /// launch recipe, an enable switch, its live status, and a
    /// remove button — plus the add form. Servers start lazily from
    /// chats; nothing here launches one.
    private var mcpServersBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP servers")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("MCP (Model Context Protocol) servers are programs that offer tools to models. This app talks to LOCAL servers over their standard input and output (called stdio) — you give the command that launches one, and the app starts it when a chat first needs its tools, and stops it when you switch it off, remove it, or quit the app. Hosted or HTTP MCP servers aren't supported yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mcpServerStore.configs.isEmpty {
                Text("No servers added yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mcpServerStore.configs) { config in
                    mcpServerRow(config)
                }
            }
            Divider()
            Text("Add a server")
                .font(.subheadline)
                .fontWeight(.medium)
            TextField("Name (e.g. Files)", text: $mcpName)
                .textFieldStyle(.roundedBorder)
            TextField("Launch command (e.g. npx, or /usr/local/bin/uvx)", text: $mcpCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Arguments, separated by spaces", text: $mcpArguments)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Add Server") { addMCPServer() }
                    .disabled(mcpName.trimmingCharacters(in: .whitespaces).isEmpty
                              || mcpCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            Text("Example: name \u{201C}Files\u{201D}, command \u{201C}npx\u{201D}, arguments \u{201C}-y @modelcontextprotocol/server-filesystem /Users/you/Shared\u{201D}. One limit: because arguments are separated by spaces, an argument that itself contains a space can't be entered yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func mcpServerRow(_ config: MCPServerConfig) -> some View {
        let status = mcpManager.status(for: config.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        mcpServerStore.setEnabled(newValue, id: config.id)
                        if newValue {
                            // A re-enabled server deserves a fresh
                            // start (clears a recorded failure too).
                            mcpManager.resetServer(id: config.id)
                        } else {
                            mcpManager.stopServer(id: config.id)
                        }
                    }
                )) {
                    Text(config.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Spacer()
                if status.isFailed {
                    Button("Try Again") {
                        mcpManager.resetServer(id: config.id)
                    }
                    .font(.caption)
                }
                Button(role: .destructive) {
                    mcpManager.stopServer(id: config.id)
                    mcpServerStore.remove(id: config.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this server")
            }
            Text(config.launchSummary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(status.settingsText)
                .font(.caption)
                .foregroundStyle(status.isFailed ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func addMCPServer() {
        let name = mcpName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return }
        mcpServerStore.add(MCPServerConfig(
            name: name, command: command,
            arguments: MCPArgumentsField.parse(mcpArguments),
            isEnabled: true))
        mcpName = ""
        mcpCommand = ""
        mcpArguments = ""
    }

    // MARK: - Quick panel (Phase 7)

    private var quickPanelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick panel")
                .font(.headline)
            Text("A small floating panel you can summon from any app with ⌘⇧Space while this app is running. It starts a chat right there — the same models, lookups, and safeguards as the main window — and quietly notes what you were in the middle of: which app is in front, what kind of thing is on the clipboard, and (only with the Shared folders switch on, above) which files Finder has selected. The note is shown as chips in the panel, and the text is included with your message so \u{201C}resize this\u{201D} can mean the selected file. Two limits are built in: the clipboard's actual text is only ever included when the Clipboard switch above is on, and file changes are never approved from the panel — a proposed change waits for you in the main window. Chats started in the panel are saved in the sidebar like any other, titled \u{201C}Quick — …\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $settings.hudEnabled) {
                Text("Enable the quick panel (⌘⇧Space)")
            }
            // Audit B-58: a failed registration is a visible state,
            // not a silently dead hotkey.
            if settings.hudEnabled, hudCoordinator.hotkeyRegistrationFailed {
                Text(HUDCoordinator.hotkeyFailureText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Turning this off unregisters the shortcut right away; turning it back on re-registers it. No relaunch needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Access log (Phase 5)

    private var accessLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent activity")
                    .font(.headline)
                Spacer()
                if !recentRecords.isEmpty || !recentPlanRecords.isEmpty {
                    Button("Clear Log", role: .destructive) {
                        for record in recentRecords {
                            modelContext.delete(record)
                        }
                        // Audit S-04: plan records clear too —
                        // they hold the full payloads (file text,
                        // commands, server answers) the log only
                        // excerpts.
                        for record in recentPlanRecords {
                            // Audit E-05: their on-disk backup
                            // folders go too — nothing retained can
                            // reach them once the records are gone.
                            ChatEngine.deleteBackupFolder(
                                forRecordID: record.id)
                            modelContext.delete(record)
                        }
                        // Audit E-10: the engine's in-memory log
                        // count re-seeds after this direct deletion.
                        ChatEngine.resetActivityCount(
                            for: modelContext.container)
                        try? modelContext.save()
                    }
                    .font(.callout)
                }
            }
            Text("Everything a model does is recorded here — every lookup, and every proposed, approved, discarded, or undone file change, command, and server call. The newest \(AccessLogPolicy.maxRecords) are kept; older ones fall off. Decided change lists are kept to the same number (\(ActionPlanLogPolicy.maxRecords)), and Clear Log removes both kinds of record.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if recentRecords.isEmpty {
                Text("Nothing has been looked up yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentRecords.prefix(12)) { record in
                    ToolActivityCard(record: record)
                }
                if recentRecords.count > 12 {
                    Text("… and \(recentRecords.count - 12) more in the full log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
