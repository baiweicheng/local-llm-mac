import Foundation
import SwiftData

/// Phase 6: one decided approval list — what the model proposed,
/// what the user chose, and what actually happened, item by item.
///
/// Like the Phase 5 access log, this is deliberately a separate
/// model from `Message`, not a special message row: Phase 2's
/// compaction counts message prefixes and must never see these.
/// ChatView merges records into the transcript by `createdAt`, so a
/// decided plan appears as a card where the decision happened, with
/// its artifact chips and (while it can still be undone) its Undo
/// button. Pending, undecided plans are NOT persisted — they live in
/// the engine's memory and are re-proposed if the app relaunches,
/// never silently executed.
@Model
final class ActionPlanRecord {
    var id: UUID
    var conversationID: UUID
    /// When the user decided (approved or discarded).
    var createdAt: Date
    /// "executed" (approved and run — per-item outcomes say how each
    /// went) or "discarded" (never ran).
    var statusRaw: String
    /// The items, JSON-encoded `[ExecutedActionItem]`.
    var itemsData: Data?
    /// When the whole plan was undone, if it was.
    var undoneAt: Date?

    init(conversationID: UUID,
         status: Status,
         items: [ExecutedActionItem],
         createdAt: Date = Date()) {
        self.id = UUID()
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
        self.itemsData = ActionPlanCoding.encodeItems(items)
        self.undoneAt = nil
    }

    enum Status: String {
        case executed
        case discarded
    }

    var status: Status { Status(rawValue: statusRaw) ?? .executed }

    var items: [ExecutedActionItem] {
        get { ActionPlanCoding.decodeItems(itemsData) }
        set { itemsData = ActionPlanCoding.encodeItems(newValue) }
    }

    var isUndone: Bool { undoneAt != nil }

    /// Whether the Undo button should be offered: an executed plan,
    /// not yet undone, with at least one item undo can reverse.
    var canUndo: Bool {
        status == .executed && !isUndone
            && ActionUndo.hasUndoableSteps(for: items)
    }
}
