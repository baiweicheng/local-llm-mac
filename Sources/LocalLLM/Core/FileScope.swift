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
///  - case handling follows the VOLUME, not a blanket rule
///    (review finding 5): on the default case-insensitive macOS
///    volume, `Shared` and `shared` are one folder and a
///    differently-cased spelling still matches; on a
///    case-sensitive APFS volume they are different sibling
///    directories and must not match. The volume's actual
///    case sensitivity is read from the filesystem (see
///    `caseSensitivityProvider`), and tests inject it — no
///    case-sensitive volume can be created in this workspace, so
///    the provider is the seam that makes both semantics testable;
///  - an empty root list admits nothing.
///
/// The service layer additionally resolves symlinks on both sides
/// before calling this, so a symlink inside a shared folder that
/// points outside it is refused too.
enum FileScope {

    /// Whether the volume containing `path` is case-sensitive.
    /// The default reads the volume's own answer
    /// (`volumeSupportsCaseSensitiveNames`); a path whose volume
    /// can't be determined falls back to case-insensitive, the
    /// default macOS volume, so existing behavior on ordinary
    /// volumes is unchanged. Tests replace this to cover both
    /// semantics and restore it afterwards.
    nonisolated(unsafe) static var caseSensitivityProvider: (String) -> Bool = { path in
        if let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
           let supports = values.volumeSupportsCaseSensitiveNames {
            return supports
        }
        return false
    }

    /// Whether the volume containing `path` treats differently-cased
    /// spellings as different paths.
    static func isCaseSensitive(atPath path: String) -> Bool {
        caseSensitivityProvider(path)
    }

    /// `path` folded for comparison under a known case rule:
    /// unchanged on a case-sensitive volume, lowercased otherwise.
    static func folded(_ path: String, caseSensitive: Bool) -> String {
        caseSensitive ? path : path.lowercased()
    }

    /// Whether two paths name the same place, under the case rule
    /// of the first path's volume (both paths are in the same
    /// shared tree in every real use).
    static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedPath(lhs)
        let b = normalizedPath(rhs)
        let sensitive = isCaseSensitive(atPath: a)
        return folded(a, caseSensitive: sensitive)
            == folded(b, caseSensitive: sensitive)
    }

    /// Whether `path` is `folder` itself or strictly inside it,
    /// under the case rule of `folder`'s volume.
    static func isSameOrInside(_ path: String, folder: String) -> Bool {
        let candidate = normalizedPath(path)
        let root = normalizedPath(folder)
        let sensitive = isCaseSensitive(atPath: root)
        let candidateFolded = folded(candidate, caseSensitive: sensitive)
        let rootFolded = folded(root, caseSensitive: sensitive)
        if candidateFolded == rootFolded { return true }
        let prefix = rootFolded == "/" ? "/" : rootFolded + "/"
        return candidateFolded.hasPrefix(prefix)
    }

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
            let sensitive = isCaseSensitive(atPath: normalizedRoot)
            let candidateFolded = folded(candidate, caseSensitive: sensitive)
            let rootFolded = folded(normalizedRoot, caseSensitive: sensitive)
            if candidateFolded == rootFolded { return true }
            let prefix = rootFolded == "/" ? "/" : rootFolded + "/"
            if candidateFolded.hasPrefix(prefix) { return true }
        }
        return false
    }
}
