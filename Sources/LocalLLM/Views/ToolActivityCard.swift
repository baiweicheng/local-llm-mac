import SwiftUI

/// Phase 5: one tool execution, rendered in the transcript.
///
/// Every lookup the model makes appears here — tool, what it asked,
/// and a one-line summary of what came back — inline with the
/// messages, in time order. The same `ToolActivityRecord` backs the
/// "Recent lookups" log in Settings; this card is just its chat face.
/// Deliberately quiet styling: it should read as a footnote to the
/// conversation, not compete with the replies.
struct ToolActivityCard: View {
    let record: ToolActivityRecord

    var body: some View {
        let descriptor = ToolCatalog.descriptor(named: record.toolName)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: descriptor?.symbolName ?? "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(descriptor?.displayName ?? record.toolName)
                        .font(.caption)
                        .fontWeight(.semibold)
                    if !record.querySummary.isEmpty {
                        Text(record.querySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(record.createdAt, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !record.resultSummary.isEmpty {
                    Text(record.resultSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
