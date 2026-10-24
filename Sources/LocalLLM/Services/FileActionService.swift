import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Phase 6: doing the approved changes — the one place file actions
/// touch the disk, and they only run from the engine's approve/undo
/// paths, never from a tool call.
///
/// The wrapper is deliberately thin: every decision (what may run,
/// what undo means) lives in the pure `FileActions.swift` and is
/// made before this file is called. What lives here is the
/// FileManager/ImageIO mechanics, each operation guarded by the
/// pure pre-check and returning the per-item record the transcript
/// card and the audit log are built from. A failure here fails one
/// item, in plain English; the rest of the plan still runs.
enum FileActionService {

    /// The probe production code answers disk questions with.
    struct FileManagerProbe: FileSystemProbe {
        func exists(atPath path: String) -> Bool {
            FileManager.default.fileExists(atPath: path)
        }
        func isDirectory(atPath path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static var probe: FileSystemProbe { FileManagerProbe() }

    // MARK: - Execution

    /// Runs one approved action and reports what happened. The
    /// pre-check runs first, against the disk as it is right now —
    /// a plan approved an hour after it was proposed is still safe.
    static func execute(_ action: PlannedAction,
                        roots: [String],
                        backupDirectory: URL) async -> ExecutedActionItem {
        // Audit S-02: the pre-check re-resolves every path NOW —
        // a component swapped for an outward symlink since the
        // proposal must fail here, not be followed.
        if let refusal = ActionExecution.preCheck(
            action, roots: roots, probe: FileManagerProbe(),
            resolve: { FileAccessService.resolvedPath($0) ?? $0 },
            resolveDestination: {
                FileAccessService.resolvedDestinationPath($0) ?? $0
            }) {
            return ExecutedActionItem(action: action,
                                      outcome: .failed(refusal),
                                      resultNote: refusal)
        }
        switch action.kind {
        case .rename, .move:
            return moveItem(action)
        case .copy:
            return copyItem(action)
        case .createFolder:
            return createFolder(action)
        case .editText:
            return editText(action, backupDirectory: backupDirectory)
        case .trash:
            return trashItem(action)
        case .resizePhoto:
            return await resizePhoto(action)
        case .runCommand, .mcpCall:
            // Phase 9: power-tool items are executed by their own
            // services from the engine's approve path — never here.
            // Reaching this case would be an engine wiring mistake;
            // fail the item plainly rather than touching anything.
            return failed(action, "That item was routed to the wrong executor.")
        }
    }

    private static func moveItem(_ action: PlannedAction) -> ExecutedActionItem {
        guard let source = action.sourcePath,
              let destination = action.destinationPath else {
            return failed(action, "The change was missing its paths.")
        }
        do {
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            let note = action.kind == .rename
                ? "Renamed to “\(PathDisplay.fileName(destination))”."
                : "Moved to \(PathDisplay.fileName(PathDisplay.parentPath(destination)))."
            return ExecutedActionItem(action: action, outcome: .done,
                                      resultNote: note)
        } catch {
            return failed(action, "Couldn't do it — \(error.localizedDescription)")
        }
    }

    private static func copyItem(_ action: PlannedAction) -> ExecutedActionItem {
        guard let source = action.sourcePath,
              let destination = action.destinationPath else {
            return failed(action, "The change was missing its paths.")
        }
        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            // Folders can be copied too; their "size" attribute is
            // the directory entry, not the contents — the chip just
            // shows the name for those.
            let isFolder = FileManagerProbe().isDirectory(atPath: destination)
            return ExecutedActionItem(
                action: action, outcome: .done,
                resultNote: "Copied — the original is where it was.",
                artifactPath: destination,
                artifactBytes: isFolder ? nil : fileSize(destination))
        } catch {
            return failed(action, "Couldn't do it — \(error.localizedDescription)")
        }
    }

    private static func createFolder(_ action: PlannedAction) -> ExecutedActionItem {
        guard let path = action.destinationPath else {
            return failed(action, "The change was missing its path.")
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: false)
            return ExecutedActionItem(action: action, outcome: .done,
                                      resultNote: "Folder created.")
        } catch {
            return failed(action, "Couldn't do it — \(error.localizedDescription)")
        }
    }

    /// The identity of the file an edit is about to touch, captured
    /// when its backup is taken and re-checked immediately before
    /// the write (audit B-59): modification date + size + the
    /// filesystem file number (inode), which together distinguish
    /// "the file that was backed up" from "a different file that
    /// now sits at the same path".
    private struct FileIdentity: Equatable {
        let modifiedAt: Date?
        let size: Int
        let fileNumber: Int
    }

    private static func fileIdentity(atPath path: String) -> FileIdentity? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: path) else { return nil }
        return FileIdentity(
            modifiedAt: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1)
    }

    /// Writes the text. An existing file is first copied into the
    /// plan's backup folder — that copy is what makes the edit
    /// undoable. Appends work at the byte level so a file's encoding
    /// is never mangled by a decode/re-encode round trip. A file this
    /// action CREATES is written with `.withoutOverwriting`: if
    /// something appeared at that path since the pre-check, the item
    /// fails rather than replacing it.
    private static func editText(_ action: PlannedAction,
                                 backupDirectory: URL) -> ExecutedActionItem {
        guard let path = action.destinationPath else {
            return failed(action, "The change was missing its path.")
        }
        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: path)
        var backupPath: String? = nil
        // Audit B-59: the backed-up file's identity, verified again
        // immediately before writing (below).
        var backedUpIdentity: FileIdentity? = nil
        if existed {
            let backupURL = backupDirectory
                .appendingPathComponent(action.id.uuidString)
            do {
                try fileManager.createDirectory(
                    at: backupDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(atPath: path, toPath: backupURL.path)
                backupPath = backupURL.path
            } catch {
                return failed(action, "Couldn't back up the file first, so it wasn't changed — \(error.localizedDescription)")
            }
            backedUpIdentity = fileIdentity(atPath: path)
        }
        let newText = Data((action.editText ?? "").utf8)
        let data: Data
        if action.appendEdit, existed {
            guard let existing = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return failed(action, "Couldn't read the file to add to it.")
            }
            data = existing + newText
        } else {
            data = newText
        }
        // Audit B-59: re-stat right before writing. The `existed`
        // snapshot above drove the backup, the append read, and the
        // write flavour — if another process replaced the file in
        // between, writing now would overwrite the NEW content
        // while the backup (and the undo story) describes the OLD
        // one. A changed identity aborts this item instead; a file
        // that vanished aborts it too (the create branch's
        // `.withoutOverwriting` guard covers the reverse race).
        if existed {
            guard let currentIdentity = fileIdentity(atPath: path),
                  currentIdentity == backedUpIdentity else {
                return failed(action, "The file changed while the change was being made, so it wasn't overwritten. Ask for the change again if you still want it.")
            }
        }
        do {
            if existed {
                try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            } else {
                try data.write(to: URL(fileURLWithPath: path),
                               options: [.atomic, .withoutOverwriting])
            }
        } catch {
            return failed(action, "Couldn't write the file — \(error.localizedDescription)")
        }
        let note: String
        if action.appendEdit {
            note = existed ? "Text added at the end." : "File created with the text."
        } else {
            note = existed
                ? "Contents replaced — a backup of the old version was kept for undo."
                : "File created."
        }
        return ExecutedActionItem(
            action: action, outcome: .done, resultNote: note,
            artifactPath: existed ? nil : path,
            artifactBytes: existed ? nil : data.count,
            backupPath: backupPath)
    }

    private static func trashItem(_ action: PlannedAction) -> ExecutedActionItem {
        guard let source = action.sourcePath else {
            return failed(action, "The change was missing its path.")
        }
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: source), resultingItemURL: &resultingURL)
            return ExecutedActionItem(
                action: action, outcome: .done,
                resultNote: "Moved to the Trash.",
                trashResultPath: resultingURL?.path)
        } catch {
            return failed(action, "Couldn't do it — \(error.localizedDescription)")
        }
    }

    // MARK: - Photo resize (the brief's reference pipeline)

    /// Loads the source photo (a scoped file, or a library photo by
    /// recent index), walks the pure attempt ladder until a JPEG
    /// fits the byte ceiling, writes the winner as a NEW file (never
    /// overwriting), and puts it on the clipboard — file URL and
    /// image data both, so it pastes into uploaders and editors
    /// alike.
    private static func resizePhoto(_ action: PlannedAction) async -> ExecutedActionItem {
        guard let destination = action.destinationPath else {
            return failed(action, "The change was missing its destination.")
        }
        let sourceData: Data?
        if let sourcePath = action.sourcePath {
            sourceData = try? Data(contentsOf: URL(fileURLWithPath: sourcePath))
        } else if let index = action.sourcePhotoIndex {
            sourceData = await PhotosService.imageData(atRecentIndex: index)
        } else {
            sourceData = nil
        }
        guard let sourceData else {
            return failed(action, "That photo's image couldn't be loaded (it may only exist in iCloud, and downloads are off for this tool).")
        }
        let maxWidth = action.maxWidthPx ?? 1200
        let ceiling = action.byteCeiling ?? 512_000
        guard let encoded = JPEGEncoder.encode(data: sourceData,
                                               maxWidth: maxWidth,
                                               byteCeiling: ceiling) else {
            return failed(action, "That doesn't look like an image this app can resize.")
        }
        do {
            try encoded.data.write(to: URL(fileURLWithPath: destination),
                                   options: [.atomic, .withoutOverwriting])
        } catch {
            return failed(action, "Couldn't save the resized photo — \(error.localizedDescription)")
        }
        copyPhotoToClipboard(fileURL: URL(fileURLWithPath: destination),
                             jpegData: encoded.data)
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(encoded.data.count), countStyle: .file)
        let note: String
        if encoded.metCeiling {
            note = "Resized to \(encoded.width)×\(encoded.height), \(size) — also copied to the clipboard."
        } else {
            let ceilingText = ByteCountFormatter.string(
                fromByteCount: Int64(ceiling), countStyle: .file)
            note = "Resized to \(encoded.width)×\(encoded.height); the smallest JPEG was \(size), still over the \(ceilingText) ceiling — also copied to the clipboard."
        }
        return ExecutedActionItem(action: action, outcome: .done,
                                  resultNote: note,
                                  artifactPath: destination,
                                  artifactBytes: encoded.data.count)
    }

    private static func copyPhotoToClipboard(fileURL: URL, jpegData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setData(jpegData,
                           forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
    }

    // MARK: - Undo execution

    /// Performs one undo step and returns the note the card shows.
    /// Undo holds itself to the same never-overwrite rule as
    /// execution: if the original spot is occupied again, the step
    /// fails with the reason rather than replacing anything.
    ///
    /// Audit S-02: undo also re-checks scope, on RESOLVED paths,
    /// before touching anything (`UndoStepScope`) — it originally
    /// checked existence only, so a path swapped for an outward
    /// symlink after execution would have been followed blindly.
    static func executeUndoStep(_ step: UndoStep,
                                roots: [String]) -> String {
        guard UndoStepScope.isAllowed(
            step, roots: roots, home: NSHomeDirectory(),
            resolve: { FileAccessService.resolvedPath($0) ?? $0 })
        else {
            return "Couldn't undo — that path is no longer inside a shared folder."
        }
        let fileManager = FileManager.default
        switch step.kind {
        case .notUndoable(let reason):
            return "Couldn't undo: \(reason)."
        case .moveBack(let from, let to):
            guard fileManager.fileExists(atPath: from) else {
                return "Couldn't undo — the item isn't where the change left it."
            }
            guard !fileManager.fileExists(atPath: to) else {
                return "Couldn't undo — something is at the original place now, and undo never overwrites it."
            }
            do {
                try fileManager.moveItem(atPath: from, toPath: to)
                return "Undone — it's back where it was."
            } catch {
                return "Couldn't undo — \(error.localizedDescription)"
            }
        case .trashFile(let path):
            guard fileManager.fileExists(atPath: path) else {
                return "Couldn't undo — the file isn't there anymore."
            }
            do {
                try fileManager.trashItem(at: URL(fileURLWithPath: path),
                                          resultingItemURL: nil)
                return "Undone — moved to the Trash."
            } catch {
                return "Couldn't undo — \(error.localizedDescription)"
            }
        case .removeFolderIfEmpty(let path):
            guard fileManager.fileExists(atPath: path) else {
                return "Undone already — the folder is gone."
            }
            let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            guard contents.isEmpty else {
                return "Left in place — the folder isn't empty anymore."
            }
            do {
                try fileManager.removeItem(atPath: path)
                return "Undone — the empty folder was removed."
            } catch {
                return "Couldn't undo — \(error.localizedDescription)"
            }
        case .restoreBackup(let backupPath, let targetPath):
            guard fileManager.fileExists(atPath: backupPath) else {
                return "Couldn't undo — the backup of the old contents is gone."
            }
            do {
                // The edited version goes to the Trash first, so undo
                // itself loses nothing.
                if fileManager.fileExists(atPath: targetPath) {
                    try fileManager.trashItem(
                        at: URL(fileURLWithPath: targetPath),
                        resultingItemURL: nil)
                }
                try fileManager.copyItem(atPath: backupPath, toPath: targetPath)
                try? fileManager.removeItem(atPath: backupPath)
                return "Undone — the earlier contents are back (the edited version went to the Trash)."
            } catch {
                return "Couldn't undo — \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Helpers

    private static func failed(_ action: PlannedAction,
                               _ note: String) -> ExecutedActionItem {
        ExecutedActionItem(action: action, outcome: .failed(note),
                           resultNote: note)
    }

    private static func fileSize(_ path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }
}

/// The ImageIO half of the resize: hardware-downsampled thumbnails
/// (`CGImageSourceCreateThumbnailAtIndex`) re-encoded as JPEG down
/// the pure `PhotoResize` ladder until the byte ceiling is met. The
/// smallest encoding is kept if none fits, so the caller can deliver
/// it with an honest note instead of failing.
enum JPEGEncoder {

    struct EncodedPhoto {
        let data: Data
        let width: Int
        let height: Int
        let metCeiling: Bool
    }

    static func encode(data: Data, maxWidth: Int, byteCeiling: Int) -> EncodedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        var best: EncodedPhoto?
        for attempt in PhotoResize.attempts(sourceWidth: pixelWidth,
                                            sourceHeight: pixelHeight,
                                            maxWidth: maxWidth) {
            guard let encoded = encodeOnce(source: source, attempt: attempt)
            else { continue }
            let candidate = EncodedPhoto(
                data: encoded.data, width: encoded.width,
                height: encoded.height,
                metCeiling: encoded.data.count <= byteCeiling)
            if best == nil || encoded.data.count < best!.data.count {
                best = candidate
            }
            if candidate.metCeiling { return candidate }
        }
        return best
    }

    private static func encodeOnce(source: CGImageSource,
                                   attempt: PhotoResize.Attempt)
        -> (data: Data, width: Int, height: Int)? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: attempt.maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: attempt.quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }
}
