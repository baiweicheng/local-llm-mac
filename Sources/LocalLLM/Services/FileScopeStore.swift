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

    /// The scope roots for the tool layer: resolved + symlink-
    /// standardized where resolution worked (so a symlinked root is
    /// checked in its real form), the picked path otherwise.
    var rootPaths: [String] {
        folders.map { folder in
            if let url = accessedURLs[folder.id] {
                return url.resolvingSymlinksInPath().standardizedFileURL.path
            }
            return (folder.path as NSString).standardizingPath
        }
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
        else { return }
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
    /// deleted simply fails to resolve — its picked path still shows
    /// in Settings so the user can remove and re-add it.
    private func resolve(_ folder: DesignatedFolder) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        else { return }
        _ = url.startAccessingSecurityScopedResource()
        accessedURLs[folder.id] = url
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
