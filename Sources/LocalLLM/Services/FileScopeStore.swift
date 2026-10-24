import Foundation

/// Phase 5: the folders the user has shared with the app.
///
/// File tools may only read inside these folders. Each entry is a
/// security-scoped bookmark, created when the user picks the folder in
/// Settings and resolved (and access started) when the app launches —
/// the persisted, user-granted form of access, which works whether or
/// not the app ends up sandboxed. The resolved, symlink-standardized
/// root paths are also what `FileScope` checks tool paths against,
/// and the same store is what Phase 6's write tools will reuse.
@MainActor
@Observable
final class FileScopeStore {

    struct DesignatedFolder: Identifiable, Equatable, Codable {
        let id: UUID
        /// The path as picked — shown in Settings and used as the
        /// display fallback if the bookmark can't be resolved.
        let path: String
        let bookmark: Data
    }

    private(set) var folders: [DesignatedFolder] = []
    /// Live, access-started URLs by folder id.
    private var accessedURLs: [UUID: URL] = [:]
    /// Audit B-57: the most recent sharing problem, in plain
    /// English — a folder that couldn't be saved, re-opened, or
    /// accessed. Settings shows it under the folder list; the old
    /// code failed silently at every one of these points (a picked
    /// folder simply never appeared, with no error anywhere).
    private(set) var lastError: String?

    private let defaultsKey = "LocalLLM.fileScope.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([DesignatedFolder].self, from: data) {
            folders = decoded
        }
        for folder in folders {
            resolve(folder)
        }
    }

    /// The scope roots for the tool layer: only folders that
    /// resolved AND granted access, in their resolved + symlink-
    /// standardized form (so a symlinked root is checked in its
    /// real form).
    ///
    /// Audit B-57: there is deliberately NO fallback to the picked
    /// path. The old code returned the original path for a folder
    /// whose bookmark no longer resolved — if anything later
    /// recreated that path, it was in tool scope without ever
    /// having been shared. An unresolvable folder is simply out of
    /// scope (and flagged unavailable in Settings) until the user
    /// removes and re-adds it.
    var rootPaths: [String] {
        folders.compactMap { folder in
            accessedURLs[folder.id].map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
    }

    /// Whether a folder currently resolves and grants access —
    /// Settings marks the ones that don't, so a moved or deleted
    /// folder reads as unavailable instead of silently scoping
    /// nothing (or, before B-57, scoping its stale path).
    func isAvailable(_ folder: DesignatedFolder) -> Bool {
        accessedURLs[folder.id] != nil
    }

    func addFolder(url: URL) {
        let standardized = url.standardizedFileURL.path
        guard !folders.contains(where: {
            ($0.path as NSString).standardizingPath == standardized
        }) else { return }
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        else {
            // Audit B-57: say so out loud — the user picked a
            // folder and nothing happened, with no error anywhere.
            lastError = "That folder couldn't be saved for sharing. "
                + "Try adding it again."
            return
        }
        lastError = nil
        let folder = DesignatedFolder(id: UUID(), path: standardized, bookmark: bookmark)
        folders.append(folder)
        resolve(folder)
        persist()
    }

    func removeFolder(id: UUID) {
        if let url = accessedURLs[id] {
            url.stopAccessingSecurityScopedResource()
            accessedURLs[id] = nil
        }
        folders.removeAll { $0.id == id }
        persist()
    }

    /// Resolve a bookmark and hold the access open for the app's
    /// lifetime (released on remove). A folder that was moved or
    /// deleted fails to resolve — its picked path still shows in
    /// Settings (marked unavailable) so the user can remove and
    /// re-add it, but it contributes NO scope root (audit B-57).
    private func resolve(_ folder: DesignatedFolder) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        else {
            lastError = "One of your shared folders couldn't be "
                + "re-opened — it may have been moved or deleted. "
                + "It isn't being shared until you remove it below "
                + "and add it again."
            return
        }
        // Audit B-57: honor the access result. A `false` means the
        // grant didn't take — registering the URL anyway presented
        // the path as a live scope root while real reads failed
        // elsewhere with unrelated errors.
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "macOS didn't grant access to one of your "
                + "shared folders, so it isn't being shared. Remove "
                + "it below and add it again to grant access."
            return
        }
        accessedURLs[folder.id] = url
        // Audit B-57: refresh a stale bookmark (the folder was
        // moved or renamed) and persist the fresh data, instead of
        // letting resolution degrade until it fails outright.
        if isStale,
           let fresh = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = DesignatedFolder(
                id: folder.id, path: folder.path, bookmark: fresh)
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
