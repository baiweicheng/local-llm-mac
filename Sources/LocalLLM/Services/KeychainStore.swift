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
    func saveKey(_ key: String)
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

    func saveKey(_ key: String) {
        // Replace any existing item: delete-then-add is the simple,
        // reliable update path for a single small secret.
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] =
            Data(key.utf8)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
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

    func saveKey(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        self.key = key
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
    /// removal, so the field can be cleared honestly).
    func setKey(_ rawKey: String) {
        let trimmed = rawKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.deleteKey()
        } else {
            store.saveKey(trimmed)
        }
        hasKey = store.readKey() != nil
    }

    func removeKey() {
        store.deleteKey()
        hasKey = false
    }
}
