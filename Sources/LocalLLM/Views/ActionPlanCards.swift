import AppKit
import SwiftUI

/// Phase 6: the propose-then-confirm cards.
///
/// `PendingPlanCard` is the gate itself: it pins above the composer
/// while a conversation has file changes awaiting a decision, listing
/// every proposed change in plain English with a per-item remove
/// button, and Approve / Discard. Nothing in the app runs a file
/// change except through this card's Approve.
///
/// `ActionPlanCard` is the decided plan in the transcript: what ran,
/// what each item did (or why it failed), the artifact chips for
/// files it created, and — while the plan can still be reversed — an
/// Undo button.
struct PendingPlanCard: View {
    let actions: [PlannedAction]
    let busy: Bool
    let onRemove: (UUID) -> Void
    let onApprove: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .foregroundStyle(.orange)
                Text(actions.count == 1
                     ? "1 file change needs your OK"
                     : "\(actions.count) file changes need your OK")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
                Text("Nothing has changed yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(actions) { action in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ToolCatalog.descriptor(
                        named: action.kind.toolName)?.symbolName ?? "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(action.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        onRemove(action.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Take this one off the list")
                    .disabled(busy)
                }
            }
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    onDiscard()
                } label: {
                    Text("Discard")
                }
                .disabled(busy)
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    onApprove()
                } label: {
                    Text(actions.count == 1
                         ? "Approve 1 change"
                         : "Approve \(actions.count) changes")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One decided plan, in the transcript.
struct ActionPlanCard: View {
    let record: ActionPlanRecord
    let engine: ChatEngine
    /// Phase 7: the quick panel renders these cards WITHOUT the Undo
    /// button (the default keeps it) — reversing a file change is a
    /// main-window decision, exactly like approving one.
    var showsUndoButton: Bool = true
    @Environment(\.modelContext) private var modelContext

    private var busy: Bool {
        engine.planBusyIDs.contains(record.conversationID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: record.status == .discarded
                      ? "checklist.unchecked" : "checklist.checked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(headerText)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(record.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(record.items, id: \.action.id) { item in
                itemRow(item)
            }
            if showsUndoButton, record.status == .executed, !record.isUndone {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        engine.undoPlan(record: record, context: modelContext)
                    } label: {
                        Label("Undo these changes", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .disabled(!record.canUndo || busy)
                    .help(record.canUndo
                          ? "Reverse what can be reversed, newest change first"
                          : "Nothing in this list can be reversed anymore")
                }
            }
            if let undoneAt = record.undoneAt {
                Text("Undone at \(undoneAt.formatted(.dateTime.hour().minute())) — see each change above for how its undo went.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var headerText: String {
        let count = record.items.count
        if record.status == .discarded {
            return count == 1
                ? "File change discarded — nothing was changed"
                : "\(count) file changes discarded — nothing was changed"
        }
        let done = record.items.filter { $0.outcome == .done }.count
        if done == count {
            return count == 1 ? "File change done" : "\(count) file changes done"
        }
        return "\(done) of \(count) file changes done"
    }

    @ViewBuilder
    private func itemRow(_ item: ExecutedActionItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusSymbol(item))
                    .font(.caption)
                    .foregroundStyle(statusColor(item))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.action.summary)
                        .font(.caption)
                    Text(item.resultNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let undoNote = item.undoNote {
                        Text(undoNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let artifactPath = item.artifactPath {
                ArtifactChip(path: artifactPath, byteCount: item.artifactBytes)
                    .padding(.leading, 22)
            }
        }
    }

    private func statusSymbol(_ item: ExecutedActionItem) -> String {
        switch item.outcome {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .declined: return "minus.circle"
        }
    }

    private func statusColor(_ item: ExecutedActionItem) -> Color {
        switch item.outcome {
        case .done: return .green
        case .failed: return .orange
        case .declined: return .secondary
        }
    }
}

/// A file an executed plan created, as a draggable pill: name +
/// size, drag it into a browser upload, Finder, anywhere. If the
/// file has since been moved or deleted by something else, the chip
/// stays — greyed, honest — rather than vanishing from the record.
struct ArtifactChip: View {
    let path: String
    let byteCount: Int?

    private var fileURL: URL { URL(fileURLWithPath: path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    private var label: String {
        var text = fileURL.lastPathComponent
        if let byteCount {
            text += " · " + ByteCountFormatter.string(
                fromByteCount: Int64(byteCount), countStyle: .file)
        }
        if !exists { text += " · missing" }
        return text
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: exists ? "doc.fill" : "doc.badge.gearshape")
                .font(.caption2)
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(exists ? 0.15 : 0.05),
                    in: Capsule())
        .foregroundStyle(exists ? Color.primary : Color.secondary)
        .opacity(exists ? 1 : 0.6)
        .draggable(fileURL) {
            // The drag preview: the chip itself.
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.2), in: Capsule())
        }
        .help(exists
              ? "Drag this file into a browser upload, Finder, or another app"
              : "This file isn't where the change left it anymore")
    }
}
