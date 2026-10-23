import Foundation
import Observation
import Security

/// API keys, one per service, in the login keychain: never in defaults or on
/// disk, and never shown again once saved, only whether one is.
///
/// Read once at launch: if macOS asks to allow keychain access (after an
/// ad-hoc rebuild, say), that belongs at launch rather than mid-dictation.
@MainActor
@Observable
final class APIKeyStore {
    private(set) var saved: Set<AIService> = []
    @ObservationIgnored private var keys: [AIService: String] = [:]

    func load() {
        keys = [:]
        for service in AIService.allCases {
            if let key = Keychain.read(service: service.keychainService), !key.isEmpty {
                keys[service] = key
            }
        }
        saved = Set(keys.keys)
    }

    func key(for service: AIService) -> String? { keys[service] }

    func has(_ service: AIService) -> Bool { saved.contains(service) }

    func save(_ raw: String, for service: AIService) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.write(key, service: service.keychainService)
        keys[service] = key
        saved.insert(service)
    }

    func remove(_ service: AIService) {
        Keychain.delete(service: service.keychainService)
        keys[service] = nil
        saved.remove(service)
    }
}

private enum Keychain {
    private static let account = "api-key"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(service: String) -> String? {
        var lookup = query(service)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String) {
        delete(service: service)
        var item = query(service)
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Yap: could not save the \(service) key to the keychain (\(status))")
        }
    }

    static func delete(service: String) {
        SecItemDelete(query(service) as CFDictionary)
    }
}
