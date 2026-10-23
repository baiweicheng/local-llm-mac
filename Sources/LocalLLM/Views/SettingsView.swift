import AppKit
import SwiftData
import SwiftUI

/// Privacy settings (Phase 4): the Local Only lock and the custom
/// terms for the privacy check — plus, below them, the one
/// performance setting that exists so far: how much memory a
/// downloaded MLX model's conversation memory may use. Opened from
/// the gear button in the chat header. (General app settings —
/// default model, instructions library — arrive with the Phase 10
/// polish pass; this sheet is the privacy page of that future
/// settings window.)
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
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let fileScopeStore: FileScopeStore
    let permissionCenter: PermissionCenter
    let openRouterKeyStore: OpenRouterKeyStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The access log, newest first. The engine rotates it to
    /// `AccessLogPolicy.maxRecords`; the panel shows the latest few.
    @Query(sort: \ToolActivityRecord.createdAt, order: .reverse)
    private var recentRecords: [ToolActivityRecord]

    @State private var newTerm = ""
    /// The OpenRouter key as typed, held only until Save hands it
    /// to the Keychain; the field then clears. The saved key is
    /// never read back into this field.
    @State private var keyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Privacy")
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
                    quickPanelSection
                    Divider()
                    accessLogSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 620)
        .task { permissionCenter.refresh() }
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
                      text: $settings.openRouterCustomModelID)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func saveKey() {
        openRouterKeyStore.setKey(keyDraft)
        keyDraft = ""
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
                if !recentRecords.isEmpty {
                    Button("Clear Log", role: .destructive) {
                        for record in recentRecords {
                            modelContext.delete(record)
                        }
                        try? modelContext.save()
                    }
                    .font(.callout)
                }
            }
            Text("Everything a model does is recorded here — every lookup, and every proposed, approved, discarded, or undone file change. The newest \(AccessLogPolicy.maxRecords) are kept; older ones fall off.")
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
