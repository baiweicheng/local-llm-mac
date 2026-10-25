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
        guard let text = String(data: data, encoding: .utf8) else {
            return "That file doesn't look like text (it may be a binary file), so it can't be read into a chat."
        }
        if size > data.count {
            return text + "\n… (the file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) in total; only the beginning was read)"
        }
        return text
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
