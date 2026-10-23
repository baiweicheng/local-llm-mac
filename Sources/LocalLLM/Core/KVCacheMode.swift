import Foundation

/// How a downloaded MLX model stores its key-value (KV) cache — the
/// model's working memory of the conversation so far, kept so each new
/// word doesn't require re-reading everything before it.
///
/// The cache is big: at full precision (16-bit) it grows by a fixed
/// amount for every token in the conversation, and for a model like
/// Gemma 4 12B it runs to several GB at this app's context budget —
/// on an 18 GB Mac that's memory the weights and macOS also need.
/// Storing the cache at fewer bits shrinks it proportionally:
///
/// - **8-bit** (the default) halves it, at a quality cost too small to
///   measure in normal chat — the recommended balance.
/// - **4-bit** quarters it. Slightly more quality risk; useful if a
///   future, larger context budget needs the room.
/// - **Off** keeps the cache at full precision, exactly as the model
///   would run without this setting.
///
/// This applies to MLX models only. Apple's built-in model manages
/// its own cache inside the system (there is nothing to configure),
/// and a local server manages its own on the server side.
///
/// The mode is a pure value: the raw strings below are what
/// `AppSettings` persists in UserDefaults, `parameters` is the pure
/// mapping to concrete cache numbers, and the MLX library types those
/// numbers become live only in `MLXBackend.swift` — the one file that
/// imports MLX, as with everything else MLX-shaped in this app.
enum KVCacheMode: String, Equatable, Sendable, CaseIterable {
    case off
    case eightBit
    case fourBit

    /// The mode a fresh install runs with: 8-bit, per the plan above.
    static let defaultMode: KVCacheMode = .eightBit

    // MARK: - Storage codec

    /// Decodes a persisted value. A missing or unrecognized string —
    /// a fresh install, or a value written by some other version —
    /// decodes to the default rather than failing, so a chat can
    /// never be stranded by a setting it doesn't understand.
    init(storedValue: String?) {
        self = storedValue.flatMap(KVCacheMode.init(rawValue:))
            ?? Self.defaultMode
    }

    /// The string form `AppSettings` writes to UserDefaults.
    var storedValue: String { rawValue }

    // MARK: - Presentation

    /// Short label for the Settings picker.
    var label: String {
        switch self {
        case .off: return "Off"
        case .eightBit: return "8-bit"
        case .fourBit: return "4-bit"
        }
    }

    // MARK: - Mapping to cache parameters

    /// The concrete cache parameters this mode asks for, as pure
    /// numbers. `bits == nil` means "no quantization — full
    /// precision". The group size (values are quantized in blocks of
    /// 64, each block sharing one scale) and the compression start
    /// (quantize from the very first cached token) are the library's
    /// own standard values — they match mlx-swift-lm's built-in
    /// `.eightBit` / `.fourBit` presets exactly (checked against the
    /// pinned 3.32.3 sources), which is what `MLXBackend.swift`
    /// constructs from these numbers.
    var parameters: KVCacheParameters {
        switch self {
        case .off:
            return KVCacheParameters(bits: nil, groupSize: 64,
                                     compressionStart: 0)
        case .eightBit:
            return KVCacheParameters(bits: 8, groupSize: 64,
                                     compressionStart: 0)
        case .fourBit:
            return KVCacheParameters(bits: 4, groupSize: 64,
                                     compressionStart: 0)
        }
    }

    // MARK: - Session reuse

    /// Whether a live session created under `sessionMode` may be
    /// reused for a send whose current setting is `currentMode`.
    ///
    /// The KV cache layout is fixed when an MLX session is created —
    /// the library itself refuses to change it mid-session — so a
    /// mode change must retire MLX sessions; the engine then rebuilds
    /// and re-seeds them from the stored conversation, exactly as it
    /// does for a model-picker switch, and nothing is lost. Sessions
    /// on any other backend don't have a cache this setting can
    /// touch, so for them the mode is irrelevant and never blocks
    /// reuse.
    static func sessionReusable(sessionMode: KVCacheMode,
                                currentMode: KVCacheMode,
                                selectionIsMLX: Bool) -> Bool {
        !selectionIsMLX || sessionMode == currentMode
    }
}

/// The pure-numbers form of a `KVCacheMode`: how many bits each cached
/// value is stored at (nil = full precision), the quantization group
/// size, and the token position compression starts from. Kept free of
/// MLX types so the mapping is unit-testable anywhere; `MLXBackend`
/// translates it into the library's `GenerateParameters`.
struct KVCacheParameters: Equatable, Sendable {
    let bits: Int?
    let groupSize: Int
    let compressionStart: Int
}
