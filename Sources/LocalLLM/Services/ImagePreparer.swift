import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns image data the user picked, pasted, or dropped into a stored
/// attachment: downscaled and re-encoded as JPEG.
///
/// Why downscale: an attached image costs the model tokens and time in
/// proportion to its size, and the on-device window is only 4,096
/// tokens. ImageIO's thumbnail path does the resize in hardware-friendly
/// code without ever decoding the full-size image into memory. The
/// framework would scale images again at send time; doing it once, here,
/// also keeps what's stored (and shown in the transcript) small.
enum ImagePreparer {

    /// Longest side of a stored image, in pixels — plenty for the model
    /// to reason about a photo or screenshot.
    static let maxPixelDimension = 1024

    static let jpegQuality = 0.8

    /// Prepares raw image bytes (any format ImageIO reads — PNG, JPEG,
    /// HEIC, TIFF, GIF…). Returns nil when the data isn't a readable
    /// image, so callers can simply skip it — a failed thumbnail below
    /// is exactly that test.
    static func prepare(_ rawData: Data) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality]
                as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let data = encoded as Data
        guard ImageAttachmentCodec.isValid(data: data) else { return nil }
        return ImageAttachment(data: data,
                               pixelWidth: image.width,
                               pixelHeight: image.height)
    }
}
