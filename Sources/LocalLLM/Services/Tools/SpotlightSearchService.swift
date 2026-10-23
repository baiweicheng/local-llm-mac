import Foundation

/// Phase 5: file search backed by NSMetadataQuery (the Spotlight
/// index). Chosen over the framework's built-in Spotlight tool because
/// it composes with the app-level tool layer — the same search is
/// offered to the MLX backend, is access-logged, is capped for the
/// context budget, and sits behind the user's own toggle.
///
/// NSMetadataQuery gathers on a run loop, so the runner starts it on
/// the main actor, waits for the finished-gathering notification, and
/// gives up after a few seconds with whatever has arrived rather than
/// hanging a chat.
enum SpotlightSearchService {

    static func search(phrase: String, limit: Int) async -> String {
        guard let format = SpotlightQueryBuilder.predicateFormat(forPhrase: phrase) else {
            return "That search didn't have any keywords to look for."
        }
        let hits = await QueryRunner().run(predicateFormat: format, limit: limit)
        return SpotlightQueryBuilder.formatResults(hits.items, totalCount: hits.total)
    }

    private struct Hits {
        let items: [(name: String, path: String, modified: Date?)]
        let total: Int
    }

    /// Runs one metadata query to completion. State is guarded by a
    /// lock (@unchecked Sendable, justified: every mutable access goes
    /// through it, and `finish` is idempotent — first caller wins,
    /// the continuation is resumed exactly once).
    private final class QueryRunner: NSObject, @unchecked Sendable {
        private let lock = NSLock()
        private var query: NSMetadataQuery?
        private var observer: NSObjectProtocol?
        private var continuation: CheckedContinuation<Hits, Never>?
        private var finished = false

        func run(predicateFormat: String, limit: Int) async -> Hits {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                Task { @MainActor in
                    self.begin(predicateFormat: predicateFormat, limit: limit)
                }
                // Safety net: never let a stuck query stall a chat.
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self.finish(limit: limit)
                }
            }
        }

        @MainActor
        private func begin(predicateFormat: String, limit: Int) {
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
            query.predicate = NSPredicate(format: predicateFormat)
            lock.lock()
            self.query = query
            lock.unlock()
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                self?.finish(limit: limit)
            }
            query.start()
        }

        private func finish(limit: Int) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            let query = self.query
            self.query = nil
            let observer = self.observer
            self.observer = nil
            lock.unlock()

            var items: [(name: String, path: String, modified: Date?)] = []
            var total = 0
            if let query {
                query.stop()
                total = query.resultCount
                for index in 0 ..< min(limit, total) {
                    guard let item = query.result(at: index) as? NSMetadataItem else { continue }
                    let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                        ?? item.value(forAttribute: NSMetadataItemFSNameKey) as? String
                        ?? "Untitled"
                    let path = item.value(forAttribute: NSMetadataItemPathKey) as? String ?? ""
                    let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
                    items.append((name: name, path: path, modified: modified))
                }
            }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            continuation.resume(returning: Hits(items: items, total: total))
        }
    }
}
