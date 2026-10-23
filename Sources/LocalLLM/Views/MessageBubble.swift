import SwiftUI

/// One message in the transcript.
///
/// User messages sit in a rounded bubble on the right (chat-app convention);
/// assistant replies run full-width in plain text, like ChatGPT — easier to
/// read for long answers and code.
struct MessageBubble: View {
    let message: Message

    var body: some View {
        if message.messageRole == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                MarkdownText(content: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The model's in-progress reply, shown while it streams in.
struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            if text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(content: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
