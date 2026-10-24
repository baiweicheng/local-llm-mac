import SwiftUI
import AppKit
import ImageIO

/// Audit E-03: decoded attachment thumbnails, cached by identity.
///
/// Rendering a thumbnail used to run `NSImage(data:)` — a FULL
/// JPEG decode to a bitmap (≈4 MB for a 1024² image) — inside
/// `body`, for every attachment, on every re-evaluation (scroll,
/// streaming updates elsewhere, any state change). This cache
/// decodes each attachment ONCE, downscaled to thumbnail size via
/// ImageIO (which decodes at the requested size), and hands the
/// same `NSImage` to every later render. Keyed by the owning
/// message's id + the attachment's index in it; bounded, with
/// simple oldest-first eviction — thumbnails are small (≈72 px)
/// and re-decodable, so eviction is harmless.
///
/// UAT-07: a cache hit is only served when the stored fingerprint
/// matches the DATA being asked for. The composer's staged strip
/// reuses one strip id across edits, so removing an image shifted
/// the rest into earlier indices — and the bare key happily served
/// the REMOVED image's thumbnail for its neighbour. A hit now has
/// to be the same image, not just the same slot.
@MainActor
enum AttachmentThumbnailCache {

    static let maxPixelSize = 72
    private static let maxEntries = 128
    private static var cache: [String: (fingerprint: UInt64,
                                         image: NSImage)] = [:]
    private static var insertionOrder: [String] = []

    static func thumbnail(messageID: UUID, index: Int,
                          data: Data) -> NSImage? {
        let key = "\(messageID.uuidString)-\(index)"
        let fingerprint = dataFingerprint(data)
        if let entry = cache[key], entry.fingerprint == fingerprint {
            return entry.image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width,
                                         height: cgImage.height))
        if cache[key] == nil { insertionOrder.append(key) }
        cache[key] = (fingerprint, image)
        if insertionOrder.count > maxEntries {
            let evicted = insertionOrder.removeFirst()
            cache[evicted] = nil
        }
        return image
    }

    /// A cheap identity for image data: the byte count mixed into
    /// an FNV-1a hash over three samples (head, middle, tail).
    /// Two different photos practically never agree on all of it,
    /// and computing it costs a few KB of scanning instead of a
    /// hash of the whole (possibly 2 MB) blob on every render.
    /// Internal (not private) so the tests can pin its behavior;
    /// nonisolated because it touches no cache state.
    nonisolated static func dataFingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        mix(UInt8(truncatingIfNeeded: data.count))
        mix(UInt8(truncatingIfNeeded: data.count >> 8))
        mix(UInt8(truncatingIfNeeded: data.count >> 16))
        mix(UInt8(truncatingIfNeeded: data.count >> 24))
        let sample = 4096
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?
                    .assumingMemoryBound(to: UInt8.self),
                  raw.count > 0 else { return }
            let count = raw.count
            for i in 0..<min(sample, count) { mix(base[i]) }
            if count > sample {
                let middle = count / 2
                for i in middle..<min(middle + sample, count) {
                    mix(base[i])
                }
                for i in (count - sample)..<count { mix(base[i]) }
            }
        }
        return hash
    }
}

/// One thumbnail slot, shared by the message bubble and the
/// composer's pending strip: cache-first, aspect-fill, fixed frame.
struct AttachmentThumbnailView: View {
    let messageID: UUID
    let index: Int
    let data: Data
    var side: CGFloat = 72

    var body: some View {
        if let image = AttachmentThumbnailCache.thumbnail(
            messageID: messageID, index: index, data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// One message in the transcript.
///
/// User messages sit in a rounded bubble on the right (chat-app convention);
/// assistant replies run full-width in plain text, like ChatGPT — easier to
/// read for long answers and code.
struct MessageBubble: View {
    let message: Message

    var body: some View {
        if message.messageRole == .user {
            // Audit E-03: decode the blob ONCE per body pass and
            // share the result — the emptiness check and the
            // thumbnails used to decode it separately, every pass.
            let attachments = message.attachments
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !attachments.isEmpty {
                        AttachmentThumbnails(messageID: message.id,
                                             attachments: attachments)
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
/// many tokens the reply is, and what it cost. Phase 8: cloud
/// replies carry their real reported cost (or "cost unknown" when
/// the provider reported none). Subtle on purpose; the details are
/// in the help text.
struct TelemetryPill: View {
    let telemetry: MessageTelemetry

    var body: some View {
        Text(TelemetryFormat.line(for: telemetry))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .help(helpText)
    }

    private var helpText: String {
        let base = "Handled by \(telemetry.backendLabel) in "
            + "\(TelemetryFormat.durationText(telemetry.seconds)) · "
            + "about \(telemetry.estimatedTokens) tokens (estimated)"
        if !telemetry.costKnown {
            return base + " · OpenRouter didn't report what this "
                + "reply cost"
        }
        if telemetry.costUSD > 0 {
            return base + " · cost as reported by OpenRouter"
        }
        if telemetry.backendLabel.hasPrefix("Cloud") {
            return base + " · included with Apple — no charge"
        }
        return base + " · local models are always free"
    }
}

/// The images attached to a message, as a row of thumbnails. Clicking one
/// opens it full-size in Preview — the stored image is what the model saw.
struct AttachmentThumbnails: View {
    let messageID: UUID
    let attachments: [ImageAttachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                // Audit E-03: the cached, downscaled thumbnail —
                // not a full-size decode per render.
                AttachmentThumbnailView(messageID: messageID,
                                        index: index,
                                        data: attachment.data)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.25)))
                    .onTapGesture { openInPreview(attachment) }
                    .help("Open in Preview")
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
                // Audit E-04: while streaming, render PLAIN text —
                // the Markdown renderer re-parses the whole reply
                // so far on every chunk (O(reply²) per reply). The
                // moment the stream finishes, the saved message
                // renders through `MessageBubble` with full
                // Markdown, exactly as before.
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
