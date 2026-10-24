import Foundation
import Security

/// Phase 8: where the OpenRouter API key lives — the macOS
/// Keychain, and ONLY there. Never UserDefaults, never a file,
/// never logged. The app ships with no key; the user pastes his own
/// into Settings whenever he likes (before or after any other setup),
/// and the cloud tier lights up the moment one is saved.
///
/// Storage sits behind this protocol for two reasons: tests must
/// never touch the real Keychain, and routing is only ever told
/// WHETHER a key exists — the key itself is read in exactly one
/// place, `BackendFactory`'s caller wiring in the app shell, and
/// handed straight to the OpenRouter backend.
protocol APIKeyStoring: Sendable {
    func readKey() -> String?
    /// Saves the key, reporting whether it actually landed — a
    /// failed Keychain write must never read as success (audit
    /// S-10: the old save discarded every status, so a failure
    /// silently lost the key the user had just pasted).
    @discardableResult
    func saveKey(_ key: String) -> Bool
    func deleteKey()
}

/// The real store: one generic-password item in the login Keychain.
struct KeychainAPIKeyStore: APIKeyStoring {

    private let service = "LocalLLM.openrouter"
    private let account = "api-key"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func readKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            // Not found (the normal no-key state), unreadable, or
            // denied — all read as "no key", and the UI says what
            // to do about it.
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    func saveKey(_ key: String) -> Bool {
        // Audit S-10: update in place, falling back to add — the
        // old delete-then-add could destroy a working key when the
        // add then failed, and its result was never looked at.
        // Accessibility is WhenUnlockedThisDeviceOnly: the key is
        // usable only while this Mac is unlocked, and it never
        // migrates to another device via a backup restore.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                         updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }
        var addAttributes = baseQuery
        for (name, value) in updateAttributes {
            addAttributes[name] = value
        }
        return SecItemAdd(addAttributes as CFDictionary, nil)
            == errSecSuccess
    }

    func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// A test double: the same contract, held in memory. Also the shape
/// of the user's intent — save, read back, remove.
final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    func readKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    @discardableResult
    func saveKey(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.key = key
        return true
    }

    func deleteKey() {
        lock.lock()
        defer { lock.unlock() }
        key = nil
    }
}

/// The app-facing key state: an observable "is a key saved?" plus
/// the save/remove actions Settings uses. The key value itself is
/// exposed only through `currentKey()`, for the factory wiring.
@MainActor
@Observable
final class OpenRouterKeyStore {

    private let store: any APIKeyStoring

    /// Whether a usable key is saved. Recomputed on every change
    /// made through this object; the app shell reads it for routing
    /// and the picker.
    private(set) var hasKey: Bool

    init(store: any APIKeyStoring = KeychainAPIKeyStore()) {
        self.store = store
        self.hasKey = store.readKey() != nil
    }

    /// The saved key, trimmed, or nil when none (or blank) is saved.
    func currentKey() -> String? {
        store.readKey()
    }

    /// Saves a pasted key (whitespace trimmed; an empty paste is a
    /// removal, so the field can be cleared honestly). Returns
    /// whether the save actually landed, so Settings can say so
    /// when the Keychain refuses (audit S-10).
    @discardableResult
    func setKey(_ rawKey: String) -> Bool {
        let trimmed = rawKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let saved: Bool
        if trimmed.isEmpty {
            store.deleteKey()
            saved = store.readKey() == nil
        } else {
            saved = store.saveKey(trimmed)
        }
        hasKey = store.readKey() != nil
        return saved
    }

    func removeKey() {
        store.deleteKey()
        hasKey = false
    }
}
