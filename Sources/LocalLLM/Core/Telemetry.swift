import Foundation

/// What actually happened on one assistant turn, recorded on the
/// message itself (see `Message.telemetry`): which backend produced
/// the reply, how long generation took, roughly how many tokens the
/// reply is, and what it cost. Local backends are always free, so the
/// cost is $0.00 in every phase so far; the field exists so the cloud
/// tier (Phase 8) has somewhere honest to put a real number.
struct MessageTelemetry: Equatable, Sendable {
    /// Pill label, e.g. "Apple On-Device" or "Local MLX · Llama 3.1 8B"
    /// (see `TelemetryFormat.label`).
    let backendLabel: String
    /// Wall-clock seconds the reply took to generate.
    let seconds: Double
    /// Estimated tokens in the reply text (the usual ~4 characters per
    /// token estimate — a planning aid, not the model's real count).
    let estimatedTokens: Int
    /// What the turn cost, in US dollars. Always 0 for local backends.
    var costUSD: Double = 0
}

/// Formatting for the telemetry pill under each assistant message —
/// pure, so the exact wording is unit-tested.
enum TelemetryFormat {

    /// The pill's backend label for a resolved (concrete) selection:
    /// MLX models say both that they're local MLX and which one they
    /// are; servers go by their configured name.
    static func label(for selection: ModelSelection,
                      displayName: String) -> String {
        switch selection {
        case .onDevice:
            return "Apple On-Device"
        case .mlx:
            return "Local MLX · \(displayName)"
        case .endpoint:
            return displayName
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

    /// "$0.00" — two decimals, always.
    static func costText(_ costUSD: Double) -> String {
        String(format: "$%.2f", costUSD)
    }

    /// The whole pill, e.g. "Apple On-Device · 1.2s · ≈96 tokens · $0.00".
    static func line(for telemetry: MessageTelemetry) -> String {
        var parts = [telemetry.backendLabel,
                     durationText(telemetry.seconds)]
        if telemetry.estimatedTokens > 0 {
            parts.append("≈\(telemetry.estimatedTokens) tokens")
        }
        parts.append(costText(telemetry.costUSD))
        return parts.joined(separator: " · ")
    }
}
