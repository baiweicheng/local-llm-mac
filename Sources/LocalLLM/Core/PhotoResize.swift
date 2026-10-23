import Foundation

/// Phase 6: the photo-resize arithmetic — how a photo gets under a
/// pixel-width cap AND a JPEG byte ceiling.
///
/// Two knobs, in a fixed order (cheapest quality loss first):
///
///  1. **Size.** The photo is scaled so its width is at most the cap,
///     aspect ratio preserved, never enlarged. (The executor hands
///     ImageIO a maximum pixel size — the larger dimension — which
///     produces exactly these dimensions.)
///  2. **Quality.** The JPEG is encoded down a quality ladder; the
///     first rung whose bytes fit the ceiling wins.
///  3. **Size again.** If even the lowest quality is too big, the
///     dimensions shrink by a factor and the ladder runs again, a
///     few rounds at most.
///
/// The executor walks `attempts(...)` in order and stops at the
/// first encoding that fits; if none fits, it keeps the smallest
/// encoding it produced and says so honestly (the file is still
/// delivered — "smallest I could get" beats failing outright).
/// Everything here is pure numbers, so the walk itself is testable
/// without an image in sight.
enum PhotoResize {

    /// JPEG compression qualities, best first. The rungs are spaced
    /// so each step cuts the byte size meaningfully without turning
    /// the descent into a dozen encodes.
    static let qualityLadder: [Double] = [0.85, 0.72, 0.60, 0.48, 0.36, 0.25, 0.15]

    /// How much smaller each shrink round makes the photo.
    static let shrinkFactor: Double = 0.75

    /// Shrink rounds after the first full-size attempt (rounds are
    /// numbered from 0, so the walk covers rounds 0...3).
    static let maxShrinkRounds = 3

    /// One encoding attempt, in walk order.
    struct Attempt: Equatable, Sendable {
        /// The cap for the image's larger dimension, in pixels —
        /// what `kCGImageSourceThumbnailMaxPixelSize` takes.
        let maxPixelSize: Int
        let quality: Double
        /// 0 = at the width cap; higher rounds are progressively
        /// smaller versions of the same photo.
        let round: Int
    }

    /// The dimensions a photo ends up at under a width cap: aspect
    /// preserved, never enlarged. Degenerate inputs (a dimension of
    /// zero — the executor never produces them, it reads real pixel
    /// sizes first) fall back to the cap squared rather than dividing
    /// by zero.
    static func outputDimensions(sourceWidth: Int, sourceHeight: Int,
                                 maxWidth: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0, maxWidth > 0 else {
            return (max(1, maxWidth), max(1, maxWidth))
        }
        guard sourceWidth > maxWidth else { return (sourceWidth, sourceHeight) }
        let height = Double(sourceHeight) * Double(maxWidth) / Double(sourceWidth)
        return (maxWidth, max(1, Int(height.rounded())))
    }

    /// The full walk, in order: for each shrink round (the width cap
    /// scaled by `shrinkFactor` per round), every quality rung from
    /// best to lowest.
    static func attempts(sourceWidth: Int, sourceHeight: Int,
                         maxWidth: Int) -> [Attempt] {
        let base = outputDimensions(sourceWidth: sourceWidth,
                                    sourceHeight: sourceHeight,
                                    maxWidth: maxWidth)
        var result: [Attempt] = []
        for round in 0...maxShrinkRounds {
            let scale = pow(shrinkFactor, Double(round))
            let width = max(1, Int((Double(base.width) * scale).rounded()))
            let height = max(1, Int((Double(base.height) * scale).rounded()))
            let cap = max(width, height)
            for quality in qualityLadder {
                result.append(Attempt(maxPixelSize: cap,
                                      quality: quality, round: round))
            }
        }
        return result
    }

    /// The next rung down the ladder after `quality`, or nil when
    /// the ladder is exhausted. (For the executor's step-by-step
    /// narration; the walk itself uses `attempts`.)
    static func nextQuality(after quality: Double) -> Double? {
        guard let index = qualityLadder.firstIndex(where: { $0 < quality - 0.0001 })
        else { return nil }
        return qualityLadder[index]
    }
}
