import SwiftUI
import AppKit

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
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        AttachmentThumbnails(attachments: message.attachments)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    MarkdownText(content: message.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let telemetry = message.telemetry {
                        TelemetryPill(telemetry: telemetry)
                    }
                }
            }
        }
    }
}

/// The Phase 4 execution-telemetry pill under an assistant reply:
/// which backend actually answered, how long it took, roughly how
/// many tokens the reply is, and what it cost — $0.00 while every
/// backend is local. Subtle on purpose; the details are in the help
/// text.
struct TelemetryPill: View {
    let telemetry: MessageTelemetry

    var body: some View {
        Text(TelemetryFormat.line(for: telemetry))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .help("Handled by \(telemetry.backendLabel) in \(TelemetryFormat.durationText(telemetry.seconds)) · about \(telemetry.estimatedTokens) tokens (estimated) · local models are always free")
    }
}

/// The images attached to a message, as a row of thumbnails. Clicking one
/// opens it full-size in Preview — the stored image is what the model saw.
struct AttachmentThumbnails: View {
    let attachments: [ImageAttachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                if let image = NSImage(data: attachment.data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.25)))
                        .onTapGesture { openInPreview(attachment) }
                        .help("Open in Preview")
                }
            }
        }
    }

    private func openInPreview(_ attachment: ImageAttachment) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLLM-preview-\(UUID().uuidString).jpg")
        if (try? attachment.data.write(to: url, options: .atomic)) != nil {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Shown in the transcript at the point where older messages were folded
/// into the running summary — the model's memory was compacted there, but
/// nothing the user sees was deleted.
struct SummarizedDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Divider()
            Label("Earlier messages were summarized to fit the model's memory",
                  systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Divider()
        }
        .padding(.vertical, 2)
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
