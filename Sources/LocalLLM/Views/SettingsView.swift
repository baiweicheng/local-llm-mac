import SwiftUI

/// Privacy settings (Phase 4): the Local Only lock and the custom
/// terms for the privacy check. Opened from the gear button in the
/// chat header. (General app settings — default model, instructions
/// library — arrive with the Phase 10 polish pass; this sheet is the
/// privacy page of that future settings window.)
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var newTerm = ""

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
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 520)
    }

    // MARK: - Local Only

    private var localOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.localOnly) {
                Label("Local Only", systemImage: "lock.fill")
                    .font(.headline)
            }
            Text("When this is on, only models that run on this Mac may answer — the built-in model and downloaded MLX models. Server backends (even ones on this Mac) are refused, Auto never routes to a server, and a chat that was using a server switches to the built-in model with a note explaining why. Nothing is sent anywhere while the lock is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy check terms

    private var redactionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy check")
                .font(.headline)
            Text("If a chat ever talks to a server that isn't on this Mac (a server address you added that points somewhere else — and, in a later phase, cloud models), the app first hides things that look like secrets or personal details: API keys, passwords after a label like \u{201C}password:\u{201D}, email addresses, phone numbers, and card numbers. Your saved messages are never changed — only the copy that gets sent.")
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
}
