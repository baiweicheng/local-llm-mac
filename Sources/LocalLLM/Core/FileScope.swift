import Foundation

/// Phase 5: the shared-folder scope check — the security boundary of
/// the file tools, and the same scope the Phase 6 write tools
/// reuse. A path is readable only if it is a designated folder itself
/// or strictly inside one.
///
/// The check is deliberately conservative:
///  - both sides are standardized first (`.` / `..` / doubled slashes
///    resolved, `~` expanded) so `folder/../secret` can't sneak past;
///  - the prefix test requires a path-boundary match, so a sibling
///    like `Documents2` never counts as inside `Documents`;
///  - comparison is case-insensitive, matching macOS's default
///    case-insensitive volumes (on a case-sensitive volume this can
///    only over-admit a differently-cased spelling of a path the user
///    already shared — never a different folder);
///  - an empty root list admits nothing.
///
/// The service layer additionally resolves symlinks on both sides
/// before calling this, so a symlink inside a shared folder that
/// points outside it is refused too.
enum FileScope {

    /// Standardized form used for comparisons: `..`/`.` resolved, no
    /// trailing slash (except the filesystem root itself).
    static func normalizedPath(_ path: String) -> String {
        var standardized = (path as NSString).standardizingPath
        if standardized.count > 1 && standardized.hasSuffix("/") {
            standardized = String(standardized.dropLast())
        }
        return standardized
    }

    static func isPath(_ path: String, insideAnyRoot roots: [String]) -> Bool {
        let candidate = normalizedPath(path)
        guard candidate.hasPrefix("/") else { return false }
        for root in roots {
            let normalizedRoot = normalizedPath(root)
            guard normalizedRoot.hasPrefix("/") else { continue }
            let candidateFolded = candidate.lowercased()
            let rootFolded = normalizedRoot.lowercased()
            if candidateFolded == rootFolded { return true }
            let prefix = rootFolded == "/" ? "/" : rootFolded + "/"
            if candidateFolded.hasPrefix(prefix) { return true }
        }
        return false
    }
}
