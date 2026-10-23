import Foundation

/// Phase 10: the pure value types behind the completed Settings —
/// the instructions library and (via `ModelSelection`'s existing
/// storage codec, reused as-is) the default model for new chats.
///
/// An instruction preset is a named set of system instructions the
/// user keeps in Settings and applies to a chat from that chat's
/// instructions editor. Applying copies the text into the chat —
/// the chat keeps its own copy, so editing or deleting a preset
/// later never rewrites a chat that's already using it.
struct InstructionPreset: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// JSON coding for the saved preset list, mirroring
/// `MCPServerConfigCodec`: tolerant of junk (a damaged save decodes
/// to an empty list rather than a crash).
enum InstructionPresetCodec {

    static func encode(_ presets: [InstructionPreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }

    static func decode(_ data: Data) -> [InstructionPreset] {
        (try? JSONDecoder().decode([InstructionPreset].self, from: data)) ?? []
    }
}

/// The rules for the library's names: what the Settings form and
/// the instructions editor both rely on, kept pure so they're
/// testable. Names are compared trimmed and case-insensitively (two
/// sets called "Brief" and "brief" would be indistinguishable in
/// the picker), and neither a name nor the instructions may be
/// blank — a preset that does nothing isn't a preset.
enum InstructionPresetRules {

    static func cleanedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanedText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a (name, text) pair may be saved: both non-blank,
    /// and no OTHER preset already carries the name. `excludingID`
    /// is the preset being edited (it may keep its own name).
    static func canSave(name: String, text: String,
                        existing: [InstructionPreset],
                        excludingID: UUID? = nil) -> Bool {
        let name = cleanedName(name)
        guard !name.isEmpty, !cleanedText(text).isEmpty else { return false }
        return !existing.contains { other in
            other.id != excludingID
                && cleanedName(other.name).lowercased() == name.lowercased()
        }
    }
}
