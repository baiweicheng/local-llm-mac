import Foundation
import Photos
import Vision

/// Phase 5: photos via PhotoKit, text-in-a-photo via Vision.
///
/// Two strictly separate capabilities:
///  - listing is METADATA ONLY (date, dimensions, favorite, album) —
///    the images themselves never leave the library;
///  - OCR reads one specific recent photo's image data locally,
///    on-device, with network access explicitly disallowed, and
///    returns only the recognized text.
enum PhotosService {

    static func recentPhotos(albumName: String?, limit: Int) -> String {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let assets: PHFetchResult<PHAsset>
        if let albumName, !albumName.isEmpty {
            guard let collection = findAlbum(named: albumName) else {
                return "There's no album named “\(albumName)”."
            }
            assets = PHAsset.fetchAssets(in: collection, options: options)
            guard assets.count > 0 else {
                return "The album “\(albumName)” has no photos."
            }
            var lines = ["Photos in “\(albumName)” (most recent first):"]
            assets.enumerateObjects { asset, _, _ in lines.append("• \(line(for: asset))") }
            return lines.joined(separator: "\n")
        }

        assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > 0 else {
            return "No photos were found in the library."
        }
        var lines = ["Most recent photos:"]
        assets.enumerateObjects { asset, _, _ in lines.append("• \(line(for: asset))") }
        return lines.joined(separator: "\n")
    }

    static func photoText(index: Int) async -> String {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = index + 1
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > index else {
            return index == 0
                ? "No photos were found in the library."
                : "There aren't that many recent photos — only \(assets.count) found."
        }
        let asset = assets.object(at: index)
        guard let data = await imageData(for: asset) else {
            return "That photo's image couldn't be loaded (it may only exist in iCloud, and downloads are off for this tool)."
        }
        return recognizeText(in: data)
    }

    // MARK: - Phase 6: shared fetch points for the resize tool

    /// The asset with a stable `PHAsset.localIdentifier`, or nil
    /// when no such asset exists anymore (deleted since the
    /// proposal, or an identifier that never existed).
    ///
    /// Review finding 14: this is the execution-time existence
    /// check for approved library resizes — the identifier the
    /// proposal captured is looked up again, never reinterpreted
    /// through a possibly-shifted recent-photos index.
    static func asset(withLocalIdentifier identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier],
                            options: nil).firstObject
    }

    /// Whether an asset with this identifier still exists.
    static func assetExists(localIdentifier identifier: String) -> Bool {
        asset(withLocalIdentifier: identifier) != nil
    }

    /// A recent photo's stable identifier AND its original file
    /// name, resolved in ONE fetch — so the proposal's name and
    /// identifier can never describe two different photos (two
    /// separate fetches could straddle an import). Nil when the
    /// library has fewer photos than the index.
    ///
    /// Review finding 14: the resize proposal resolves the model's
    /// recent-photo index to this identifier immediately, at
    /// proposal time; from then on the identifier — not the
    /// index — is what approval and execution carry.
    static func recentPhotoIdentity(index: Int)
        -> (identifier: String, filename: String?)? {
        guard let asset = asset(atRecentIndex: index) else { return nil }
        let filename = PHAssetResource.assetResources(for: asset)
            .first?.originalFilename
        return (identifier: asset.localIdentifier, filename: filename)
    }

    /// A recent photo's image data by stable identifier — nil when
    /// the asset is gone or is iCloud-only (local copies only, as
    /// with every other reader here).
    static func imageData(forLocalIdentifier identifier: String) async -> Data? {
        guard let asset = asset(withLocalIdentifier: identifier) else {
            return nil
        }
        return await imageData(for: asset)
    }

    /// The asset at a "recent" index (0 = most recent), or nil when
    /// the library has fewer photos than that.
    static func asset(atRecentIndex index: Int) -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = index + 1
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > index else { return nil }
        return assets.object(at: index)
    }

    /// A recent photo's original file name, for deriving the resized
    /// copy's name ("IMG_1234.jpg" → "IMG_1234-resized.jpg").
    static func recentPhotoFilename(index: Int) -> String? {
        guard let asset = asset(atRecentIndex: index) else { return nil }
        return PHAssetResource.assetResources(for: asset)
            .first?.originalFilename
    }

    /// A recent photo's full image data — the same local-copies-only
    /// rule as the text reader: iCloud-only photos return nil rather
    /// than triggering a download.
    static func imageData(atRecentIndex index: Int) async -> Data? {
        guard let asset = asset(atRecentIndex: index) else { return nil }
        return await imageData(for: asset)
    }

    // MARK: - Helpers

    private static func line(for asset: PHAsset) -> String {
        let date = asset.creationDate.map { DateDisplay.dayAndTime($0) } ?? "unknown date"
        var line = "\(date) — \(asset.pixelWidth)×\(asset.pixelHeight)"
        if asset.isFavorite { line += " · ★ favorite" }
        return line
    }

    private static func findAlbum(named name: String) -> PHAssetCollection? {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        var found: PHAssetCollection?
        albums.enumerateObjects { collection, _, stop in
            if collection.localizedTitle?.caseInsensitiveCompare(name) == .orderedSame {
                found = collection
                stop.pointee = true
            }
        }
        if let found { return found }
        let smart = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil)
        smart.enumerateObjects { collection, _, stop in
            if collection.localizedTitle?.caseInsensitiveCompare(name) == .orderedSame {
                found = collection
                stop.pointee = true
            }
        }
        return found
    }

    private static func imageData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false // local copies only, by design
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func recognizeText(in data: Data) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return "Reading the text in that photo failed."
        }
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        guard !lines.isEmpty else {
            return "No readable text was found in that photo."
        }
        return "Text in that photo:\n" + lines.joined(separator: "\n")
    }
}
