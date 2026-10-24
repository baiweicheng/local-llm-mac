import SwiftUI

/// The Models panel: download and manage local MLX models, and
/// configure local model servers (Ollama, LM Studio). Opened from the
/// chat header; whatever is downloaded or configured here is what the
/// per-chat model picker can offer.
struct ModelsView: View {
    let mlxStore: MLXModelStore
    let endpointStore: EndpointStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingEndpoint: EndpointConfig?
    @State private var showingNewEndpoint = false

    private var memoryGB: Double { MLXCatalog.thisMacMemoryGB }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Models")
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
                    mlxSection
                    Divider()
                    endpointsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
        .sheet(item: $editingEndpoint) { config in
            EndpointEditorView(store: endpointStore, config: config)
        }
        .sheet(isPresented: $showingNewEndpoint) {
            EndpointEditorView(store: endpointStore, config: nil)
        }
    }

    // MARK: - MLX models

    private var mlxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local models (MLX)")
                .font(.headline)
            Text("Bigger open models that run entirely on your Mac, downloaded from Hugging Face. Nothing is sent anywhere. Your Mac has \(Int(memoryGB.rounded())) GB of memory — the badges show what fits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(MLXCatalog.models) { info in
                mlxRow(info)
            }
        }
    }

    private func mlxRow(_ info: MLXModelInfo) -> some View {
        let fit = MLXCatalog.fit(bytes: info.approximateBytes,
                                 totalMemoryGB: memoryGB)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                fitBadge(fit)
                Spacer()
                Text("≈ \(MLXCatalog.formatBytes(info.approximateBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(info.blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
            mlxRowControls(info)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func fitBadge(_ fit: MemoryFit) -> some View {
        let color: Color = switch fit {
        case .comfortable: .green
        case .fits: .orange
        case .tooBig: .red
        }
        return Text(fit.badgeText)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func mlxRowControls(_ info: MLXModelInfo) -> some View {
        switch mlxStore.state(for: info) {
        case .notDownloaded:
            HStack {
                Button("Download") { mlxStore.startDownload(info) }
                Text("Free · from Hugging Face (mlx-community)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            HStack(spacing: 10) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 180)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { mlxStore.cancelDownload(info) }
            }
        case .downloaded:
            HStack(spacing: 10) {
                Label("Downloaded · \(MLXCatalog.formatBytes(mlxStore.diskSizes[info.repoID] ?? info.approximateBytes)) on disk",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Button("Delete", role: .destructive) {
                    mlxStore.deleteModel(info)
                }
                .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Try Again") { mlxStore.startDownload(info) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Local servers

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Local servers")
                    .font(.headline)
                Spacer()
                Button {
                    showingNewEndpoint = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .controlSize(.small)
            }
            Text("If you run Ollama or LM Studio on this Mac, chats can use the models they serve instead. The server app must be running — if it isn't, sending a message says so and nothing breaks.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if endpointStore.configs.isEmpty {
                Text("No servers configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(endpointStore.configs) { config in
                endpointRow(config)
            }
        }
    }

    private func endpointRow(_ config: EndpointConfig) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(config.baseURL) · model: \(config.modelName.isEmpty ? "(none set)" : config.modelName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { editingEndpoint = config }
                .controlSize(.small)
            Button("Remove", role: .destructive) {
                endpointStore.remove(id: config.id)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Add/edit form for one local server configuration.
struct EndpointEditorView: View {
    let store: EndpointStore
    /// The server being edited; nil means "add a new one".
    let config: EndpointConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var modelName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(config == nil ? "Add a Local Server" : "Edit Server")
                .font(.headline)
            Text("Any app that serves the OpenAI chat API on this Mac works — Ollama (http://localhost:11434/v1) and LM Studio (http://localhost:1234/v1) are the usual two. The model name must match a model the server has; for Ollama, run \u{201C}ollama list\u{201D} in Terminal to see yours.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                TextField("Model name", text: $modelName)
            }
            .formStyle(.grouped)
            if let warning = draftWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if config == nil {
                    Button("Use Ollama Defaults") {
                        name = "Ollama"
                        baseURL = EndpointConfig.ollamaPreset.baseURL
                        modelName = EndpointConfig.ollamaPreset.modelName
                    }
                    Button("Use LM Studio Defaults") {
                        name = "LM Studio"
                        baseURL = EndpointConfig.lmStudioPreset.baseURL
                        modelName = ""
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(config == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            if let config {
                name = config.name
                baseURL = config.baseURL
                modelName = config.modelName
            }
        }
    }

    /// Audit S-09: the plaintext-HTTP warning for the address as
    /// currently typed — shown live, before the server is saved.
    private var draftWarning: String? {
        EndpointConfig(
            id: config?.id ?? UUID(), name: name,
            baseURL: baseURL.trimmingCharacters(
                in: .whitespacesAndNewlines),
            modelName: modelName).remoteHTTPWarning
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let config {
            var updated = config
            updated.name = trimmedName
            updated.baseURL = trimmedURL
            updated.modelName = trimmedModel
            store.update(updated)
        } else {
            store.add(EndpointConfig(id: UUID(), name: trimmedName,
                                     baseURL: trimmedURL,
                                     modelName: trimmedModel))
        }
        dismiss()
    }
}
