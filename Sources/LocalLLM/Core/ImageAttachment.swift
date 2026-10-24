import Foundation

/// One image attached to a message, as stored data.
///
/// Attachments live with their message: the encoded form of a message's
/// images is a single blob on the `Message` record itself (SwiftData
/// external storage), so deleting a message deletes its images and there
/// is no separate attachment bookkeeping to keep in sync. The images are
/// stored as JPEG, downscaled before saving (see `ImagePreparer`), so a
/// blob stays small — a few hundred KB at most.
///
/// The model's side of this lives in `ChatEngine`: stored files are
/// re-created as temporary files at send time and handed to the session
/// as `Attachment(imageURL:)` in the prompt, the framework's documented
/// multimodal route (macOS 27).
struct ImageAttachment: Codable, Equatable, Sendable {
    /// JPEG data of the (downscaled) image.
    var data: Data
    /// Pixel size, recorded at prepare time for display and estimates.
    var pixelWidth: Int
    var pixelHeight: Int

    init(data: Data, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Encoding/validation rules for a message's attachments, kept pure so
/// they can be unit-tested without any storage or UI.
enum ImageAttachmentCodec {

    /// At most this many images on one message — the on-device model's
    /// window is small, and each image costs real tokens.
    static let maxAttachmentsPerMessage = 4

    /// One stored image may be at most this large. Prepared images are
    /// far smaller in practice; this is a sanity ceiling.
    static let maxStoredBytesPerImage = 2 * 1024 * 1024

    /// Rough token cost of one attached image, for context planning.
    /// Apple's WWDC26 demo showed a photo caption costing ~323 tokens;
    /// 400 keeps a small safety margin. It is an estimate, like all the
    /// app's token math.
    static let estimatedTokensPerImage = 400

    /// Is this candidate acceptable as a stored attachment?
    static func isValid(data: Data) -> Bool {
        !data.isEmpty && data.count <= maxStoredBytesPerImage
    }

    /// Encodes a message's images into the single stored blob. Invalid
    /// images are dropped and the count is capped — encoding never fails.
    static func encode(_ attachments: [ImageAttachment]) -> Data? {
        let usable = attachments
            .filter { isValid(data: $0.data) }
            .prefix(maxAttachmentsPerMessage)
        guard !usable.isEmpty else { return nil }
        return try? JSONEncoder().encode(Array(usable))
    }

    /// Reads a stored blob back. A missing or unreadable blob simply
    /// means "no images" — an old or damaged record must never break the
    /// conversation.
    static func decode(_ blob: Data?) -> [ImageAttachment] {
        guard let blob,
              let decoded = try? JSONDecoder().decode([ImageAttachment].self, from: blob)
        else { return [] }
        return decoded.filter { isValid(data: $0.data) }
    }

    /// How many images a stored blob holds, WITHOUT decoding any
    /// image data (audit E-03). The blob is a JSON array of objects
    /// whose first key is `data` (the JSONEncoder's declaration
    /// order for `ImageAttachment`) — each image contributes exactly
    /// one `"data":` key per object (brace-depth 2: array → object
    /// → key), and base64 image
    /// data can never contain a quote or colon, so counting those
    /// key markers at depth 2 counts images. A blob that isn't the
    /// expected array shape counts 0 (matching `decode`'s "unreadable
    /// means none"). This is a byte scan, not a decode: no `Data`
    /// payloads are materialized, validated, or copied — callers
    /// that need the images themselves still use `decode`.
    static func count(in blob: Data?) -> Int {
        guard let blob, !blob.isEmpty else { return 0 }
        let bytes = [UInt8](blob)
        // Must look like a JSON array.
        var index = 0
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
        guard index < bytes.count, bytes[index] == 0x5B /* [ */ else {
            return 0
        }
        let marker: [UInt8] = [0x22, 0x64, 0x61, 0x74, 0x61, 0x22, 0x3A] // "data":
        var count = 0
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = index
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // backslash
                    escaped = true
                } else if byte == 0x22 { // closing quote
                    inString = false
                }
                cursor += 1
                continue
            }
            switch byte {
            case 0x22: // quote — but first, is it the "data": key?
                if depth == 2,
                   bytes[cursor...].starts(with: marker) {
                    count += 1
                    cursor += marker.count
                    inString = false
                    continue
                }
                inString = true
            case 0x7B, 0x5B: depth += 1 // { [
            case 0x7D, 0x5D: depth -= 1 // } ]
            default: break
            }
            cursor += 1
        }
        return min(count, maxAttachmentsPerMessage)
    }
}
