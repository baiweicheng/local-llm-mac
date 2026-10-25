import Foundation

/// Audit B-41: a per-key generation counter for download attempts.
///
/// Cancelling a download is fire-and-forget — the cancelled task
/// unwinds asynchronously, and the user may immediately start a NEW
/// download of the same model into the SAME staging folder. Every
/// attempt therefore takes the next generation for its repo id, and
/// an unwinding task may only touch shared state (the state map,
/// the task table, the staging folder) while its generation is
/// still the current one. Pure value logic, so the guard decisions
/// are unit-testable without any download running.
struct DownloadGenerationTracker: Equatable {
    private(set) var current: [String: Int] = [:]

    /// Advances and returns the generation for `key` — called when
    /// an attempt starts AND when one is invalidated (cancel /
    /// delete), so a still-unwinding older attempt goes stale at
    /// the moment of invalidation, not whenever it happens to wake.
    @discardableResult
    mutating func advance(for key: String) -> Int {
        let next = (current[key] ?? 0) + 1
        current[key] = next
        return next
    }

    func isCurrent(_ generation: Int, for key: String) -> Bool {
        current[key] == generation
    }
}

/// Downloads, tracks, and deletes local MLX models.
///
/// Files live under Application Support/LocalLLM/Models/<repo folder> —
/// one folder per model, downloaded straight from Hugging Face with
/// plain HTTPS (the repo file list comes from the HF API; the planning
/// of what to fetch is the pure `MLXDownloadPlanner`). Downloads land
/// in a "<repo folder>.partial" staging folder first and are renamed
/// into place only when complete, so a cancelled or failed download
/// never looks like a finished model.
///
/// Note: the MLX bridge no longer loads by repo id from its own
/// Hugging Face cache — `MLXBackend` now constructs it against
/// this store's directory (see that file), so the copy kept here
/// is the one that gets loaded, not a second download. The panel
/// still reports the HF cache total below for transparency.
@MainActor
@Observable
final class MLXModelStore {

    /// Per-model download state, shown in the Models panel.
    enum DownloadState: Equatable {
        case notDownloaded
        /// Fraction received (0...1), or nil when the total size isn't
        /// known yet and the progress bar should spin instead.
        case downloading(fraction: Double?)
        case downloaded
        case failed(message: String)
    }

    private(set) var states: [String: DownloadState] = [:]
    /// Exact on-disk bytes per downloaded model (the app's copy).
    private(set) var diskSizes: [String: Int64] = [:]
    /// UAT-03: exact on-disk bytes per KEPT PARTIAL download (the
    /// staging folder a cancelled or failed attempt left behind,
    /// audit E-11). Before this, a partial was invisible: the row
    /// went back to a plain "Download", the bytes weren't counted
    /// in the panel's on-disk total, and no Delete control could
    /// reach them — a multi-GB partial could sit on disk forever
    /// with no way to see or reclaim it.
    private(set) var partialSizes: [String: Int64] = [:]
    /// Audit E-11: the MLX bridge keeps its OWN copy of each model
    /// in its Hugging Face cache (see the header note), so a model
    /// costs roughly twice what `diskSizes` alone says. The total
    /// size of that cache folder, measured by `refresh()` — the
    /// Models panel shows both figures rather than half the truth.
    private(set) var huggingFaceCacheBytes: Int64 = 0

    /// The standard Hugging Face cache the MLX bridge loads from.
    nonisolated static var huggingFaceCacheDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface", isDirectory: true)
    }

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Audit B-41: the generation stamps behind `downloadTasks` —
    /// see `DownloadGenerationTracker`.
    private var downloadGenerations = DownloadGenerationTracker()

    /// The folder model files live under. Internal (not private) so
    /// tests and future phases can find it.
    nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalLLM/Models",
                                           isDirectory: true)
    }

    init() {
        refresh()
    }

    // MARK: - State queries

    func state(for info: MLXModelInfo) -> DownloadState {
        states[info.repoID] ?? .notDownloaded
    }

    func isDownloaded(_ repoID: String) -> Bool {
        states[repoID] == .downloaded
    }

    /// UAT-03: bytes of this model's kept partial download (its
    /// staging folder), or 0 when there is none worth showing.
    func partialBytes(for info: MLXModelInfo) -> Int64 {
        partialSizes[info.repoID] ?? 0
    }

    /// UAT-03: every kept partial's bytes together — the Models
    /// panel's on-disk total includes them (they live in the same
    /// app folder as finished models).
    var totalPartialBytes: Int64 {
        partialSizes.values.reduce(0, +)
    }

    var downloadedRepoIDs: Set<String> {
        Set(states.filter { $0.value == .downloaded }.map { $0.key })
    }

    /// Catalog entries that are downloaded, in catalog order — the
    /// picker's MLX section.
    var downloadedModels: [MLXModelInfo] {
        MLXCatalog.models.filter { isDownloaded($0.repoID) }
    }

    /// Re-reads the models folder (called at launch and after every
    /// download/delete, so the panel never lies about the disk).
    ///
    /// Audit E-90: the directory walks (per-model sizes + the HF
    /// cache total) run OFF the main actor — `refresh()` used to
    /// walk every downloaded model synchronously on the main actor,
    /// stalling the UI at launch and after each download. The scan
    /// is detached; only the state assignment hops back. Folder
    /// EXISTENCE (cheap) is still checked synchronously, so states
    /// never flicker while sizes are being measured.
    /// Review finding 11: the pure merge behind `refresh()` — the
    /// scan (disk truth) plus the previous states, so the rules are
    /// unit-testable without touching the real models folder:
    /// - A scanned `.downloaded` ALWAYS wins. The old code let a
    ///   previous `.downloading` overwrite it, which is exactly how
    ///   a completed download read as still downloading.
    /// - Otherwise, an in-flight state (its task still registered)
    ///   is preserved — the scan can't know about a download in
    ///   progress, whose folder doesn't exist yet.
    /// - A `.downloading` state with NO task is stale and is
    ///   dropped in favor of the scan. The old code preserved it
    ///   unconditionally, so once a download's task was gone
    ///   (the completion defer) every later refresh still
    ///   reported downloading forever.
    /// - A `.failed` state survives only when the scan says the
    ///   model isn't on disk (a failed attempt's staging is kept,
    ///   but the model itself isn't downloaded).
    static func mergedStates(
        scanned: [String: DownloadState],
        previous: [String: DownloadState],
        inFlightRepoIDs: Set<String>
    ) -> [String: DownloadState] {
        var merged = scanned
        for (repoID, state) in previous {
            if merged[repoID] == .downloaded { continue }
            if inFlightRepoIDs.contains(repoID) {
                merged[repoID] = state
                continue
            }
            if case .failed = state, merged[repoID] == .notDownloaded {
                merged[repoID] = state
            }
        }
        return merged
    }

    func refresh() {
        states = Self.mergedStates(
            scanned: Self.scanModelFolders(),
            previous: states,
            inFlightRepoIDs: Set(downloadTasks.keys))
        Task.detached { [weak self] in
            let sizes = Self.measureSizes()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Don't resurrect a model deleted while measuring.
                self.diskSizes = sizes.sizes.filter {
                    self.states[$0.key] == .downloaded
                }
                // UAT-03: partials for models that aren't finished
                // (a downloaded model's staging was moved into
                // place, so anything measured for it is stale).
                self.partialSizes = sizes.partials.filter {
                    $0.value > 0 && self.states[$0.key] != .downloaded
                }
                self.huggingFaceCacheBytes = sizes.cacheBytes
            }
        }
    }

    /// The synchronous half of a refresh: which models' folders
    /// exist. (Sizes are the detached half — see `refresh()`.)
    private static func scanModelFolders() -> [String: DownloadState] {
        var newStates: [String: DownloadState] = [:]
        for info in MLXCatalog.models {
            let directory = directory(for: info)
            newStates[info.repoID] = FileManager.default
                .fileExists(atPath: directory.path)
                ? .downloaded : .notDownloaded
        }
        return newStates
    }

    /// The detached half of a refresh: the byte totals.
    nonisolated private static func measureSizes()
        -> (sizes: [String: Int64], partials: [String: Int64],
            cacheBytes: Int64) {
        var sizes: [String: Int64] = [:]
        var partials: [String: Int64] = [:]
        for info in MLXCatalog.models {
            let directory = directory(for: info)
            if FileManager.default.fileExists(atPath: directory.path) {
                sizes[info.repoID] = sizeOfDirectory(directory)
            }
            // UAT-03: the staging folder gets measured too, so a
            // kept partial is visible (and countable, and
            // deletable) instead of silent disk usage.
            let staging = stagingDirectory(for: info)
            if FileManager.default.fileExists(atPath: staging.path) {
                partials[info.repoID] = sizeOfDirectory(staging)
            }
        }
        return (sizes, partials, sizeOfDirectory(huggingFaceCacheDirectory))
    }

    // MARK: - Downloading

    func startDownload(_ info: MLXModelInfo) {
        guard downloadTasks[info.repoID] == nil,
              !isDownloaded(info.repoID) else { return }
        // Audit B-41: this attempt's generation stamp. Everything
        // the attempt later does to shared state is gated on it.
        let generation = downloadGenerations.advance(for: info.repoID)
        states[info.repoID] = .downloading(fraction: nil)
        downloadTasks[info.repoID] = Task { [weak self] in
            await self?.performDownload(info, generation: generation)
        }
    }

    func cancelDownload(_ info: MLXModelInfo) {
        // Audit B-41: invalidate the in-flight attempt FIRST, so
        // when it unwinds it can see it no longer owns the state,
        // the staging folder, or the task-table entry — a download
        // restarted a moment later is a different generation, and
        // the old task must not delete its files or clear its entry.
        downloadGenerations.advance(for: info.repoID)
        downloadTasks[info.repoID]?.cancel()
        downloadTasks[info.repoID] = nil
        // Audit E-11: the staging folder is KEPT on cancel — the
        // files already fetched stay for the next attempt, which
        // reuses every one whose size still matches the manifest
        // (see `performDownload`). Reset the visible state right
        // away; `deleteModel` is the path that removes staging.
        states[info.repoID] = .notDownloaded
        // UAT-03: measure the kept partial right away, so the row
        // can show it (with its size, a Resume, and a Delete)
        // instead of silently reverting to a plain "Download".
        refresh()
    }

    func deleteModel(_ info: MLXModelInfo) {
        cancelDownload(info)
        try? FileManager.default.removeItem(at: Self.directory(for: info))
        try? FileManager.default.removeItem(at: Self.stagingDirectory(for: info))
        refresh()
    }

    private func performDownload(_ info: MLXModelInfo,
                                 generation: Int) async {
        let repoID = info.repoID
        // Audit B-41: every touch of shared state below — the task
        // table here, progress and completion further down, and the
        // staging folder in the unwind paths — is gated on this
        // attempt still being the current generation. A superseded
        // attempt (cancelled, then restarted or deleted) just stops:
        // the staging folder and the state now belong to the newer
        // attempt (or to nobody, after a delete).
        func isCurrent() -> Bool {
            downloadGenerations.isCurrent(generation, for: repoID)
        }
        defer {
            if isCurrent() { downloadTasks[repoID] = nil }
        }
        do {
            // 1. Ask Hugging Face what files this repo has.
            guard let listURL = MLXDownloadPlanner.fileListURL(repoID: repoID)
            else { throw StoreFailure.unreachable }
            let (listData, listResponse) = try await URLSession.shared.data(from: listURL)
            if let http = listResponse as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw StoreFailure.notFound
            }
            guard let siblings = MLXDownloadPlanner.parseFileList(jsonData: listData)
            else { throw StoreFailure.notFound }
            let files = MLXDownloadPlanner.filesToDownload(from: siblings)
            guard !files.isEmpty else { throw StoreFailure.notFound }
            let total = MLXDownloadPlanner.totalBytes(of: files)

            // 2. Download each file into the staging folder.
            // Audit E-11: staging is NOT wiped first — a retry
            // (after cancel, failure, or relaunch) reuses every
            // file a previous attempt completed whose size still
            // matches the manifest, instead of discarding a 95%
            // download of a multi-GB model. Only the generation
            // guard (B-41) decides whose staging this is: a stale
            // attempt never reaches this loop (`isCurrent` checks
            // per file), so reuse can't resurrect a cancelled
            // attempt's claim on the folder.
            let staging = Self.stagingDirectory(for: info)
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            var received: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                guard isCurrent() else { return }
                let destination = staging.appendingPathComponent(file.path)
                // Already here, complete, from an earlier attempt?
                if file.size > 0,
                   Self.sizeOfFile(destination) == file.size {
                    received += file.size
                    if total > 0, isCurrent() {
                        states[repoID] = .downloading(
                            fraction: min(1, Double(received) / Double(total)))
                    }
                    continue
                }
                guard let url = MLXDownloadPlanner.downloadURL(
                        repoID: repoID, path: file.path)
                else { throw StoreFailure.unreachable }
                let (tempURL, fileResponse) = try await URLSession.shared.download(from: url)
                if let http = fileResponse as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw StoreFailure.notFound
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                received += file.size > 0 ? file.size
                    : Self.sizeOfFile(destination)
                if total > 0, isCurrent() {
                    states[repoID] = .downloading(
                        fraction: min(1, Double(received) / Double(total)))
                }
            }

            // 3. Complete: staging becomes the model's folder. The
            // generation is re-checked at the last moment (audit
            // B-41): a download cancelled — or a model deleted —
            // while the last file landed must not move staging into
            // place over the newer attempt, or resurrect the model
            // after `deleteModel` removed it.
            guard isCurrent() else { return }
            let destination = Self.directory(for: info)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            // Review finding 11: set the successful state
            // EXPLICITLY — and drop the in-flight marker — BEFORE
            // refreshing. The old code called `refresh()` while
            // the task was still registered, so refresh overwrote
            // the scanned `.downloaded` with the old `.downloading`
            // state, and the defer only removed the task afterwards.
            // (The merge in `refresh()` now also lets disk truth
            // win over a stale downloading state, so either half
            // alone would fix the completion; both are kept so the
            // state is right even before the scan runs.)
            downloadTasks[repoID] = nil
            states[repoID] = .downloaded
            refresh()
        } catch is CancellationError {
            // Audit E-11: staging is KEPT (see step 2) — the files
            // fetched so far are the next attempt's head start.
            // Only the state resets, and only for the current
            // generation (a stale attempt touches nothing, B-41).
            guard isCurrent() else { return }
            if states[repoID] != .notDownloaded {
                states[repoID] = .notDownloaded
            }
        } catch let failure as StoreFailure {
            guard isCurrent() else { return }
            // Staging kept for reuse on retry (E-11), as above.
            // If the task entry is already gone, the user cancelled and
            // set the state themselves — don't overwrite it with a
            // failure that was really just the cancellation landing.
            if downloadTasks[repoID] != nil {
                states[repoID] = .failed(message: failure.message)
                // UAT-03: measure the kept partial for the row.
                refresh()
            }
        } catch {
            guard isCurrent() else { return }
            if downloadTasks[repoID] != nil {
                states[repoID] = .failed(
                    message: "The download failed: \(error.localizedDescription)")
                // UAT-03: measure the kept partial for the row.
                refresh()
            }
        }
    }

    // MARK: - Folders

    nonisolated static func directory(for info: MLXModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.directoryName,
                                               isDirectory: true)
    }

    nonisolated static func stagingDirectory(for info: MLXModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.directoryName + ".partial",
                                               isDirectory: true)
    }

    nonisolated private static func sizeOfDirectory(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            total += Int64((try? fileURL.resourceValues(
                forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    nonisolated private static func sizeOfFile(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Download failures, in plain English.
    private enum StoreFailure: Error {
        case notFound
        case unreachable

        var message: String {
            switch self {
            case .notFound:
                return "Couldn't find that model on Hugging Face. "
                    + "It may have been renamed or removed."
            case .unreachable:
                return "Couldn't reach Hugging Face. Check your "
                    + "internet connection and try again."
            }
        }
    }
}
