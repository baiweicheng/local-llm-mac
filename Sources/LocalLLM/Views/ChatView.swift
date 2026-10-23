import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// The chat pane: header with model status, the message list, and the
/// composer. Return sends, Shift+Return adds a line. Images can be
/// attached with the paperclip button, by dragging files into the
/// window, or by pasting (⌘V) while the composer is focused.
struct ChatView: View {
    @Bindable var conversation: Conversation
    let engine: ChatEngine
    @Environment(\.modelContext) private var modelContext

    @State private var input = ""
    @State private var showingInstructions = false
    @State private var showingFileImporter = false
    /// Images staged in the composer, waiting to go with the next send.
    @State private var pendingAttachments: [ImageAttachment] = []
    /// Re-read on appear and after each send; the system state can change
    /// while the app is open (e.g. the model finishes downloading).
    @State private var availability: ModelAvailabilityState = .current

    private var conversationID: UUID { conversation.id }
    private var isResponding: Bool { engine.isResponding(conversationID) }
    private var canAttachMore: Bool {
        pendingAttachments.count < ImageAttachmentCodec.maxAttachmentsPerMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = engine.errorMessages[conversationID] {
                errorBanner(error)
            }
            if !availability.canChat {
                availabilityBanner
            }
            Divider()
            composer
        }
        .onAppear { availability = .current }
        .sheet(isPresented: $showingInstructions) {
            instructionsSheet
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { attachImage(fromFile: url) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imageURLs = urls.filter { $0.isFileURL }
            guard !imageURLs.isEmpty else { return false }
            for url in imageURLs { attachImage(fromFile: url) }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(contextMeterText)
                .font(.caption)
                .foregroundStyle(.secondary)
            availabilityPill
            Button {
                showingInstructions = true
            } label: {
                Image(systemName: "text.quote")
            }
            .buttonStyle(.borderless)
            .help("System instructions for this chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var availabilityPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(availability.canChat ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(availability.headline)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .help(availability.explanation)
    }

    /// A rough "how full is the model's memory" meter. The estimate is
    /// approximate on purpose (see `PromptHistory`) and labeled as such;
    /// it counts the summary plus the live turns, which is what the
    /// model actually holds.
    private var contextMeterText: String {
        let instructions = PromptHistory.mergedInstructions(
            userInstructions: conversation.systemInstructions)
        let all = conversation.sortedMessages
        let prefix = min(conversation.summarizedMessageCount, all.count)
        let turns = all.dropFirst(prefix).map { $0.chatTurn }
        var used = PromptHistory.estimatedContextTokens(
            instructions: instructions, turns: turns)
        if let summary = conversation.contextSummary {
            used += PromptHistory.approximateTokenCount(for: summary)
        }
        return "≈ \(used) / \(ContextBudget.onDevice.windowTokens) tokens"
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.sortedMessages.isEmpty && !isResponding {
                        emptyState
                    }
                    ForEach(Array(conversation.sortedMessages.enumerated()),
                            id: \.element.id) { index, message in
                        // The summarized prefix ends here: everything
                        // above the divider has been folded into the
                        // model's running summary.
                        if index == conversation.summarizedMessageCount,
                           conversation.summarizedMessageCount > 0 {
                            SummarizedDivider()
                        }
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if conversation.summarizedMessageCount > 0,
                       conversation.summarizedMessageCount
                        >= conversation.sortedMessages.count {
                        SummarizedDivider()
                    }
                    if isResponding {
                        StreamingBubble(text: engine.streamingText[conversationID] ?? "")
                            .id("streaming")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.sortedMessages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: engine.streamingText[conversationID]) {
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ask anything")
                .font(.title3)
            Text("This chat runs on the model built into your Mac. Nothing you type leaves the machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if isResponding {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let last = conversation.sortedMessages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .font(.callout)
            Spacer()
            Button {
                engine.errorMessages[conversationID] = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }

    private var availabilityBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(availability.explanation)
                .font(.callout)
            Spacer()
            Button("Check Again") { availability = .current }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                pendingStrip
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showingFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!canAttachMore)
                .help(canAttachMore
                      ? "Attach images (up to \(ImageAttachmentCodec.maxAttachmentsPerMessage))"
                      : "Up to \(ImageAttachmentCodec.maxAttachmentsPerMessage) images per message")
                TextEditor(text: $input)
                    .font(.body)
                    .frame(minHeight: 24, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.3)))
                    .onKeyPress(.return) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored // Shift+Return: newline, as usual.
                        }
                        send()
                        return .handled
                    }
                if isResponding {
                    Button(action: stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!availability.canChat || !canSend)
                    .help("Send (Return)")
                }
            }
        }
        .padding(12)
        .onPasteCommand(of: [.image, .fileURL]) { _ in
            handlePaste()
        }
    }

    /// Staged images above the composer, each removable before sending.
    private var pendingStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                if let image = NSImage(data: attachment.data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                pendingAttachments.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.borderless)
                            .offset(x: 5, y: -5)
                            .help("Remove image")
                        }
                }
            }
            Spacer()
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingAttachments.isEmpty
    }

    private func send() {
        guard availability.canChat, !isResponding, canSend else { return }
        let text = input
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        availability = .current
        engine.send(text: text, attachments: attachments,
                    in: conversation, context: modelContext)
    }

    private func stop() {
        engine.stop(conversationID: conversationID)
    }

    // MARK: - Attaching images

    /// Reads an image file (picker, drag-and-drop) and stages it,
    /// downscaled, in the composer.
    private func attachImage(fromFile url: URL) {
        guard canAttachMore else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let prepared = ImagePreparer.prepare(data) else { return }
        pendingAttachments.append(prepared)
    }

    /// Stages whatever image a paste delivered. `onPasteCommand` fires
    /// while the content is on the general pasteboard, so it can simply
    /// be read synchronously: file URLs first (Finder copies), then raw
    /// image data (screenshots and copied pictures).
    private func handlePaste() {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: options) as? [URL],
           !urls.isEmpty {
            for url in urls where url.isFileURL {
                attachImage(fromFile: url)
            }
            return
        }
        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = pasteboard.data(forType: type),
               let prepared = ImagePreparer.prepare(data) {
                if canAttachMore { pendingAttachments.append(prepared) }
                return
            }
        }
    }

    // MARK: - Instructions sheet

    private var instructionsSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System Instructions")
                .font(.headline)
            Text("Tell the model how to behave in this chat — for example, \u{201C}Answer like I'm a beginner\u{201D} or \u{201C}Be brief\u{201D}. Leave it empty to use the built-in default. Changing this starts a fresh session for the chat; the visible history stays.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $conversation.systemInstructions)
                .font(.body)
                .frame(minHeight: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Done") { showingInstructions = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
