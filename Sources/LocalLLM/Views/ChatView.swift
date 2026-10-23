import SwiftUI
import SwiftData
import AppKit

/// The chat pane: header with model status, the message list, and the
/// composer. Return sends, Shift+Return adds a line.
struct ChatView: View {
    @Bindable var conversation: Conversation
    let engine: ChatEngine
    @Environment(\.modelContext) private var modelContext

    @State private var input = ""
    @State private var showingInstructions = false
    /// Re-read on appear and after each send; the system state can change
    /// while the app is open (e.g. the model finishes downloading).
    @State private var availability: ModelAvailabilityState = .current

    private var conversationID: UUID { conversation.id }
    private var isResponding: Bool { engine.isResponding(conversationID) }

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
    /// approximate on purpose (see `PromptHistory`) and labeled as such.
    private var contextMeterText: String {
        let turns = conversation.sortedMessages.map {
            ChatTurn(role: $0.messageRole, text: $0.text)
        }
        let used = PromptHistory.estimatedContextTokens(
            instructions: PromptHistory.mergedInstructions(
                userInstructions: conversation.systemInstructions),
            turns: turns)
        return "≈ \(used) / \(PromptHistory.contextWindowTokens) tokens"
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.sortedMessages.isEmpty && !isResponding {
                        emptyState
                    }
                    ForEach(conversation.sortedMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
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
        HStack(alignment: .bottom, spacing: 10) {
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
                .disabled(!availability.canChat
                          || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return)")
            }
        }
        .padding(12)
    }

    private func send() {
        guard availability.canChat, !isResponding else { return }
        let text = input
        input = ""
        availability = .current
        engine.send(text: text, in: conversation, context: modelContext)
    }

    private func stop() {
        engine.stop(conversationID: conversationID)
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
