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
/// Note: the MLX bridge loads models by repo id through its own
/// Hugging Face cache, so the first time a downloaded model is picked
/// it may still spend a little while loading — the copy kept here is
/// what the Models panel accounts for (sizes, delete) and the
/// guarantee that the model is on this Mac.
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
    /// Exact on-disk bytes per downloaded model.
    private(set) var diskSizes: [String: Int64] = [:]

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Audit B-41: the generation stamps behind `downloadTasks` —
    /// see `DownloadGenerationTracker`.
    private var downloadGenerations = DownloadGenerationTracker()

    /// The folder model files live under. Internal (not private) so
    /// tests and future phases can find it.
    static var modelsDirectory: URL {
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
    func refresh() {
        var newStates: [String: DownloadState] = [:]
        var newSizes: [String: Int64] = [:]
        for info in MLXCatalog.models {
            if downloadTasks[info.repoID] != nil { continue }
            let directory = Self.directory(for: info)
            if FileManager.default.fileExists(atPath: directory.path) {
                newStates[info.repoID] = .downloaded
                newSizes[info.repoID] = Self.sizeOfDirectory(directory)
            } else {
                newStates[info.repoID] = .notDownloaded
            }
        }
        // Preserve in-flight and failed states the scan can't know.
        for (repoID, state) in states {
            if case .downloading = state { newStates[repoID] = state }
            if case .failed = state, newStates[repoID] == .notDownloaded {
                newStates[repoID] = state
            }
        }
        states = newStates
        diskSizes = newSizes
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
        // The staging folder is cleaned up by the download task as it
        // unwinds; reset the visible state right away.
        states[info.repoID] = .notDownloaded
        try? FileManager.default.removeItem(at: Self.stagingDirectory(for: info))
    }

    func deleteModel(_ info: MLXModelInfo) {
        cancelDownload(info)
        try? FileManager.default.removeItem(at: Self.directory(for: info))
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
            let staging = Self.stagingDirectory(for: info)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            var received: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                guard isCurrent() else { return }
                guard let url = MLXDownloadPlanner.downloadURL(
                        repoID: repoID, path: file.path)
                else { throw StoreFailure.unreachable }
                let (tempURL, fileResponse) = try await URLSession.shared.download(from: url)
                if let http = fileResponse as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw StoreFailure.notFound
                }
                let destination = staging.appendingPathComponent(file.path)
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
            refresh()
        } catch is CancellationError {
            // Only the current generation cleans up: the staging
            // folder a stale attempt would delete may already be a
            // restarted download's (audit B-41).
            guard isCurrent() else { return }
            try? FileManager.default.removeItem(at: Self.stagingDirectory(for: info))
            if states[repoID] != .notDownloaded {
                states[repoID] = .notDownloaded
            }
        } catch let failure as StoreFailure {
            guard isCurrent() else { return }
            try? FileManager.default.removeItem(at: Self.stagingDirectory(for: info))
            // If the task entry is already gone, the user cancelled and
            // set the state themselves — don't overwrite it with a
            // failure that was really just the cancellation landing.
            if downloadTasks[repoID] != nil {
                states[repoID] = .failed(message: failure.message)
            }
        } catch {
            guard isCurrent() else { return }
            try? FileManager.default.removeItem(at: Self.stagingDirectory(for: info))
            if downloadTasks[repoID] != nil {
                states[repoID] = .failed(
                    message: "The download failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Folders

    static func directory(for info: MLXModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.directoryName,
                                               isDirectory: true)
    }

    static func stagingDirectory(for info: MLXModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.directoryName + ".partial",
                                               isDirectory: true)
    }

    private static func sizeOfDirectory(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            total += Int64((try? fileURL.resourceValues(
                forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func sizeOfFile(_ url: URL) -> Int64 {
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
