import SwiftUI
import SwiftData

/// Phase 8: compare mode — one prompt, two models, side by side.
///
/// Deliberately ONE-SHOT and separate from the chat engine: no
/// conversation history, no compaction, no lookups or file changes —
/// each column is a fresh session asked the same question once, so
/// the comparison is about the models, not the machinery. Both
/// answers stream at the same time, each with its own telemetry
/// pill (cloud answers show their real cost, like in a chat).
///
/// "Continue with this one" is the bridge back: it creates an
/// ordinary conversation seeded with the question and the chosen
/// answer (see `CompareSeeding`), on the backend that produced it,
/// and the main window switches to it — from there it's a full
/// chat with sessions, compaction, and tools where supported.
struct CompareView: View {
    let descriptors: [BackendDescriptor]
    /// Resolves a picker selection to a live backend — the same
    /// factory path the chat engine uses, supplied by the app shell.
    let resolver: (ModelSelection) -> ResolvedBackend
    /// Hands the seeded conversation to the main window, which
    /// selects it in the sidebar.
    let onContinue: (Conversation) -> Void
    /// Audit S-01: the privacy context compare mode scrubs with —
    /// the saved servers (for the remote test) and the user's custom
    /// redaction terms, supplied by the chat pane from the same live
    /// stores the engine reads. Without these, compare sent its
    /// prompt to cloud/remote columns with NO privacy check at all.
    let endpoints: [EndpointConfig]
    let customRedactionTerms: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var prompt = ""
    @State private var leftColumn: CompareColumn
    @State private var rightColumn: CompareColumn

    init(descriptors: [BackendDescriptor],
         resolver: @escaping (ModelSelection) -> ResolvedBackend,
         onContinue: @escaping (Conversation) -> Void,
         endpoints: [EndpointConfig] = [],
         customRedactionTerms: [String] = []) {
        self.descriptors = descriptors
        self.resolver = resolver
        self.onContinue = onContinue
        self.endpoints = endpoints
        self.customRedactionTerms = customRedactionTerms
        _leftColumn = State(initialValue: CompareColumn(
            selection: .onDevice))
        // The interesting comparison is usually local vs cloud:
        // default the right column to a ready cloud row when one
        // exists (PCC first — it's free), else Apple's cloud row so
        // the user sees what it would take.
        let cloudDefault = descriptors
            .first { $0.selection.isCloud && $0.isReady }?.selection
            ?? descriptors.first { $0.selection.isCloud }?.selection
            ?? .privateCloudCompute
        _rightColumn = State(initialValue: CompareColumn(
            selection: cloudDefault))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare two models")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("One question, asked of two models at once — a single fresh question with no chat history, no lookups, and no file changes. When an answer wins, continue with it: that starts a normal chat with that model, with this question and answer already in it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask both models…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { runBoth() }
                Button("Ask both") { runBoth() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
            HStack(alignment: .top, spacing: 12) {
                columnView(leftColumn)
                Divider()
                columnView(rightColumn)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(width: 860, height: 560)
        .onDisappear {
            leftColumn.cancel()
            rightColumn.cancel()
        }
    }

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !leftColumn.isRunning && !rightColumn.isRunning
    }

    private func runBoth() {
        guard canRun else { return }
        let text = prompt
        leftColumn.run(prompt: text, resolver: resolver,
                       endpoints: endpoints,
                       customRedactionTerms: customRedactionTerms)
        rightColumn.run(prompt: text, resolver: resolver,
                        endpoints: endpoints,
                        customRedactionTerms: customRedactionTerms)
    }

    // MARK: - One column

    private func columnView(_ column: CompareColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(descriptors) { descriptor in
                    Button {
                        column.selection = descriptor.selection
                    } label: {
                        if descriptor.selection == column.selection {
                            Label(descriptor.displayName, systemImage: "checkmark")
                        } else {
                            Text(descriptor.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: column.selection.isCloud ? "cloud" : "cpu")
                    Text(descriptorName(column.selection))
                        .font(.callout)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose this column's model")

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let notice = column.privacyNotice {
                        Label(notice, systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = column.errorText {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if column.text.isEmpty {
                        if column.isRunning {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Its answer will appear here.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        MarkdownText(content: column.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let telemetry = column.telemetry {
                        TelemetryPill(telemetry: telemetry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .frame(maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))

            Button("Continue with this one") {
                continueWith(column)
            }
            .disabled(column.isRunning
                      || !CompareSeeding.canContinue(answer: column.text)
                      || column.errorText != nil)
            .help("Start a normal chat with this model, seeded with this question and answer")
        }
        .frame(maxWidth: .infinity)
    }

    private func descriptorName(_ selection: ModelSelection) -> String {
        descriptors.first { $0.selection == selection }?.displayName
            ?? "Choose a model"
    }

    /// Seeds a normal conversation from the winning column and
    /// hands it to the main window.
    private func continueWith(_ column: CompareColumn) {
        let seed = CompareSeeding.seed(
            prompt: prompt, answer: column.text,
            selection: column.effectiveSelection)
        let conversation = Conversation()
        conversation.title = seed.title
        conversation.modelSelection = seed.selection
        modelContext.insert(conversation)
        let userMessage = Message(role: .user, text: seed.userText,
                                  conversation: conversation)
        let assistantMessage = Message(role: .assistant,
                                       text: seed.assistantText,
                                       conversation: conversation)
        // Keep the order exact even if both land in the same instant.
        assistantMessage.createdAt =
            userMessage.createdAt.addingTimeInterval(0.001)
        assistantMessage.telemetry = column.telemetry
        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        conversation.updatedAt = Date()
        try? modelContext.save()
        onContinue(conversation)
        dismiss()
    }
}

/// One side of the comparison: the chosen model, its streamed
/// answer, and its telemetry. A small observable class (not view
/// state) because a run outlives any single render — two of these
/// stream concurrently, each in its own task.
@MainActor
@Observable
final class CompareColumn {
    var selection: ModelSelection
    /// The selection the resolver actually produced for the last
    /// run (a removed model or a locked cloud falls back to the
    /// built-in model, and the seeded chat must use what answered).
    private(set) var effectiveSelection: ModelSelection
    private(set) var text = ""
    private(set) var errorText: String?
    /// Audit S-01: the privacy-check notice for the last run, when
    /// the prompt had to be scrubbed for this column's destination
    /// (same wording pattern as the chat engine's banner).
    private(set) var privacyNotice: String?
    private(set) var telemetry: MessageTelemetry?
    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    init(selection: ModelSelection) {
        self.selection = selection
        self.effectiveSelection = selection
    }

    func cancel() {
        task?.cancel()
    }

    func run(prompt: String,
             resolver: (ModelSelection) -> ResolvedBackend,
             endpoints: [EndpointConfig] = [],
             customRedactionTerms: [String] = []) {
        task?.cancel()
        text = ""
        errorText = nil
        telemetry = nil
        privacyNotice = nil
        isRunning = true
        let resolved = resolver(selection)
        effectiveSelection = resolved.effectiveSelection
        let backend = resolved.backend
        // Audit S-01: the same privacy firewall the chat engine
        // applies — a column whose EFFECTIVE destination is remote
        // (cloud, or a server that isn't on this Mac) receives the
        // scrubbed prompt, never the raw one; a local column gets
        // the text exactly as written.
        let scrubbed = RemoteDestination.scrubbed(
            prompt, selection: effectiveSelection,
            endpoints: endpoints, customTerms: customRedactionTerms)
        if scrubbed.didRedact {
            privacyNotice = RemoteDestination.noticeText(
                redactions: scrubbed.replacementCount,
                backendDisplayName: backend.displayName,
                selection: effectiveSelection)
        }
        let session = backend.makeSession(
            instructions: PromptHistory.mergedInstructions(
                userInstructions: ""),
            tools: nil)
        let started = Date()
        task = Task { [weak self] in
            var received = ""
            var failure: String?
            do {
                for try await partial in session.streamReply(
                    to: ChatReplyRequest(promptText: scrubbed.text)) {
                    received = partial
                    self?.text = received
                }
            } catch is CancellationError {
                // Dismissed or re-run — keep whatever arrived.
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.isRunning = false
            if let failure {
                self.errorText = failure
                return
            }
            let finalText = received.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else { return }
            // Same cost honesty as the chat engine: the real figure
            // from a usage-reporting session, "cost unknown" when a
            // paid route sent none.
            var costUSD = 0.0
            var costKnown = true
            if case .openRouter = self.effectiveSelection {
                if let report = (session as? UsageReportingChatSession)?
                    .lastUsageReport,
                   let reportedCost = report.costUSD {
                    costUSD = reportedCost
                } else {
                    costKnown = false
                }
            }
            self.telemetry = MessageTelemetry(
                backendLabel: TelemetryFormat.label(
                    for: self.effectiveSelection,
                    displayName: backend.displayName),
                seconds: Date().timeIntervalSince(started),
                estimatedTokens: PromptHistory.approximateTokenCount(
                    for: finalText),
                costUSD: costUSD,
                costKnown: costKnown)
        }
    }
}
