import Foundation

/// What actually happened on one assistant turn, recorded on the
/// message itself (see `Message.telemetry`): which backend produced
/// the reply, how long generation took, roughly how many tokens the
/// reply is, and what it cost. Local backends are always free.
/// Phase 8: a cloud reply carries the REAL cost its provider
/// reported (OpenRouter sends it in the usage report); when a paid
/// route reports no cost, `costKnown` is false and the pill says
/// "cost unknown" — a made-up $0.00 for a paid reply would be a lie.
struct MessageTelemetry: Equatable, Sendable {
    /// Pill label, e.g. "Apple On-Device" or "Local MLX · Gemma 4 12B"
    /// (see `TelemetryFormat.label`).
    let backendLabel: String
    /// Wall-clock seconds the reply took to generate.
    let seconds: Double
    /// Estimated tokens in the reply text (the usual ~4 characters per
    /// token estimate — a planning aid, not the model's real count).
    let estimatedTokens: Int
    /// What the turn cost, in US dollars. Always 0 for local backends
    /// and for Private Cloud Compute (Apple includes it).
    var costUSD: Double = 0
    /// False only when a paid route (OpenRouter) didn't report a
    /// cost for this reply. Everything else — local, PCC, and
    /// OpenRouter replies WITH a usage report — knows its cost.
    var costKnown: Bool = true
}

/// Formatting for the telemetry pill under each assistant message —
/// pure, so the exact wording is unit-tested.
enum TelemetryFormat {

    /// The pill's backend label for a resolved (concrete) selection:
    /// MLX models say both that they're local MLX and which one they
    /// are; servers go by their configured name; cloud backends say
    /// "Cloud" out loud — a reply that left the Mac is never dressed
    /// up as a local one.
    static func label(for selection: ModelSelection,
                      displayName: String) -> String {
        switch selection {
        case .onDevice:
            return "Apple On-Device"
        case .mlx:
            return "Local MLX · \(displayName)"
        case .endpoint:
            return displayName
        case .privateCloudCompute:
            return "Cloud · Apple Private Cloud"
        case .openRouter:
            return "Cloud · OpenRouter · \(displayName)"
        case .auto:
            // Auto is always resolved to a concrete backend before a
            // message is sent; reaching here would be a bug, so fall
            // back to whatever name the resolver produced.
            return displayName
        }
    }

    /// "1.2s" under a minute; "1m 5s" above it.
    static func durationText(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", max(0, seconds))
        }
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(total % 60)s"
    }

    /// The cost, honestly: "$0.00" when free, two decimals for
    /// ordinary amounts — and four decimals for the fractions of a
    /// cent a single cloud reply usually costs, so a real charge
    /// never rounds down to a fake-looking "$0.00".
    static func costText(_ costUSD: Double) -> String {
        if costUSD > 0, costUSD < 0.01 {
            return String(format: "$%.4f", costUSD)
        }
        return String(format: "$%.2f", max(0, costUSD))
    }

    /// The pill's cost segment: the real number when the provider
    /// reported one, "cost unknown" when a paid route didn't.
    static func costSegment(for telemetry: MessageTelemetry) -> String {
        telemetry.costKnown ? costText(telemetry.costUSD) : "cost unknown"
    }

    /// The whole pill, e.g. "Apple On-Device · 1.2s · ≈96 tokens · $0.00"
    /// or "Cloud · OpenRouter · Claude Opus 5.5 · 4.1s · ≈512 tokens · $0.0214".
    static func line(for telemetry: MessageTelemetry) -> String {
        var parts = [telemetry.backendLabel,
                     durationText(telemetry.seconds)]
        if telemetry.estimatedTokens > 0 {
            parts.append("≈\(telemetry.estimatedTokens) tokens")
        }
        parts.append(costSegment(for: telemetry))
        return parts.joined(separator: " · ")
    }
}
