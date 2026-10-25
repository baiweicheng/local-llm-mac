import Foundation

/// Phase 5: reading files and listing folders — ONLY inside the
/// folders the user designated in Settings.
///
/// Every request goes through `FileScope` against the designated
/// roots, and the candidate path is symlink-resolved first, so neither
/// `..` escapes nor a symlink planted inside a shared folder can reach
/// outside it. Outside scope, the tool says plainly that it can't see
/// there (and names what IS shared, so the model can tell the user).
enum FileAccessService {

    static func listFolder(path rawPath: String, roots: [String]) -> String {
        guard let resolved = scopedPath(rawPath, roots: roots) else {
            return outsideScopeMessage(roots: roots)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return "There's nothing at \(rawPath) — it may have been moved or deleted."
        }
        guard isDirectory.boolValue else {
            return "\(rawPath) is a file, not a folder. Use read_file to read it."
        }
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: resolved)
                .sorted { $0.lowercased() < $1.lowercased() }
            guard !entries.isEmpty else { return "That folder is empty." }
            let cap = 60
            var lines = ["Contents of \(displayPath(resolved)):"]
            for entry in entries.prefix(cap) {
                let full = (resolved as NSString).appendingPathComponent(entry)
                var entryIsDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &entryIsDirectory)
                lines.append("• \(entry)\(entryIsDirectory.boolValue ? "/" : "")")
            }
            if entries.count > cap {
                lines.append("… and \(entries.count - cap) more — ask for a specific file if you need one.")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Couldn't open that folder — macOS refused the read."
        }
    }

    static func readFile(path rawPath: String, roots: [String]) -> String {
        guard let resolved = scopedPath(rawPath, roots: roots) else {
            return outsideScopeMessage(roots: roots)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return "There's nothing at \(rawPath) — it may have been moved or deleted."
        }
        guard !isDirectory.boolValue else {
            return "\(rawPath) is a folder. Use list_folder to see what's inside it."
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 10_000_000 else {
            return "That file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) — too large to read into a chat."
        }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolved)) else {
            return "Couldn't open that file — macOS refused the read."
        }
        defer { try? handle.close() }
        // Read a slice well past the result cap; the runtime clamps
        // to the context budget and the note below says so honestly.
        let data = (try? handle.read(upToCount: 24_000)) ?? nil
        guard let data, !data.isEmpty else {
            return "That file is empty."
        }
        // Review finding 22: the read stops mid-file, so the last
        // bytes may be the head of a multibyte character whose tail
        // was not read. Requiring the whole 24,000-byte prefix to
        // decode rejected valid text cut exactly there (23,999
        // ASCII chars + € + more text read as "not text"). When
        // more file remains, a trailing INCOMPLETE sequence is
        // trimmed and the rest decodes; genuinely invalid or binary
        // content still fails (see `decodeTextPrefix`).
        guard let text = Self.decodeTextPrefix(
            data, isTruncated: size > data.count) else {
            return "That file doesn't look like text (it may be a binary file), so it can't be read into a chat."
        }
        if size > data.count {
            return text + "\n… (the file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) in total; only the beginning was read)"
        }
        return text
    }

    // MARK: - Text decoding (review finding 22)

    /// Decodes a read prefix as UTF-8 text, or returns nil for
    /// genuinely invalid/binary content.
    ///
    /// - When the prefix is the whole file (`isTruncated` false),
    ///   it must decode exactly: a dangling sequence at end of
    ///   file is invalid content, not a cut.
    /// - When more file remains, a trailing sequence cut by the
    ///   read boundary is trimmed: the bytes from the last
    ///   sequence's lead byte onward form a strict prefix of one
    ///   valid character (a lead byte expecting more continuations
    ///   than are present, followed only by continuation bytes).
    ///   Anything else that fails to decode — a stray continuation
    ///   byte, an impossible lead byte, a complete-but-invalid
    ///   sequence — is rejected, not trimmed away.
    static func decodeTextPrefix(_ data: Data,
                                 isTruncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        guard isTruncated else { return nil }
        guard let cut = incompleteTrailingSequenceLength(in: data) else {
            return nil
        }
        return String(data: data.dropLast(cut), encoding: .utf8)
    }

    /// The length of a trailing INCOMPLETE UTF-8 sequence, or nil
    /// when the tail is not an incomplete sequence (so the decode
    /// failure lies elsewhere and the content is invalid). Scans
    /// back over trailing continuation bytes to their lead byte
    /// and compares the bytes present against the length that
    /// lead byte promises.
    private static func incompleteTrailingSequenceLength(
        in data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        var start = data.count - 1
        while start > 0 && isContinuationByte(data[data.index(
            data.startIndex, offsetBy: start)]) {
            start -= 1
        }
        let lead = data[data.index(data.startIndex, offsetBy: start)]
        let expected: Int
        switch lead {
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: return nil
        }
        let present = data.count - start
        guard present < expected else { return nil }
        // Every byte after the lead must be a continuation byte;
        // the scan-back above guarantees this unless the tail is a
        // lone lead byte (present == 1), which is also incomplete.
        return present
    }

    private static func isContinuationByte(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
    }

    // MARK: - Scope

    /// The symlink-resolved absolute path when it's inside scope,
    /// else nil. Roots are expected pre-resolved (FileScopeStore);
    /// both sides still go through `FileScope`'s standardization.
    private static func scopedPath(_ rawPath: String, roots: [String]) -> String? {
        guard let resolved = resolvedPath(rawPath) else { return nil }
        return FileScope.isPath(resolved, insideAnyRoot: roots) ? resolved : nil
    }

    /// Phase 6: the resolved form on its own — proposal validation
    /// resolves every path a model names through this, then applies
    /// `FileScope` itself, so reads and writes resolve identically.
    static func resolvedPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    /// Audit S-02: the resolved form of a path that may not exist
    /// yet — an action's destination. The parent folder (which does
    /// exist; the pre-checks require it) is resolved, and the final
    /// name is re-attached untouched, so a parent swapped for an
    /// outward symlink since the proposal is seen for what it now
    /// points at.
    ///
    /// Review finding 4: that parent-only rule is NOT enough for
    /// an EXISTING destination. If the leaf itself was swapped for
    /// a symlink to an outside file while the proposal awaited
    /// approval, parent-only resolution still looks in-scope and
    /// the edit would read the outside file. So when the
    /// destination already exists, the FULL leaf is resolved
    /// instead — a leaf pointing outside then fails the scope
    /// check in the pre-check, before any read or backup. A
    /// not-yet-existing destination keeps the parent-only rule
    /// and stays creatable.
    static func resolvedDestinationPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: trimmed) {
            return resolvedPath(trimmed)
        }
        let parent = (trimmed as NSString).deletingLastPathComponent
        let name = (trimmed as NSString).lastPathComponent
        guard !name.isEmpty,
              let resolvedParent = resolvedPath(parent.isEmpty ? "/" : parent)
        else { return nil }
        return (resolvedParent as NSString).appendingPathComponent(name)
    }

    private static func outsideScopeMessage(roots: [String]) -> String {
        guard !roots.isEmpty else {
            return "File access is off — no folders are shared with the app. The user can share folders in Settings → What this app can see → Shared folders."
        }
        let list = roots.map { "• \($0)" }.joined(separator: "\n")
        return "That path is outside the folders shared with the app, so I can't see it. Shared folders:\n\(list)"
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
