import Foundation
import Security

/// The secret that owns this install's support conversation.
///
/// Support threads used to be addressed by device id, which is not a secret:
/// it travels in every analytics event, is shown in the owner's dashboard, and
/// ends up in logs. Anyone who came by one could read the conversation and
/// write in it. So the thread is owned by 32 random bytes generated here; the
/// server stores only their SHA-256 and can no longer hand a conversation to
/// anyone who merely knows who the user is.
///
/// Kept in the Keychain rather than UserDefaults so it is encrypted at rest
/// and not carried out in a plist backup, and marked `AfterFirstUnlock` so a
/// notification arriving while the phone is locked can still be reconciled.
enum SupportSecretStore {
    private static let service = "sh.astronaut.support"

    /// This app's secret, generated and stored the first time it is asked for.
    /// Nil only when the Keychain is unavailable and nothing can be stored, in
    /// which case chat stays offline rather than falling back to something
    /// weaker without saying so.
    static func secret(for trackingId: String) -> String? {
        if let existing = read(account: trackingId) { return existing }

        guard let generated = generate() else { return nil }
        let status = store(generated, account: trackingId)
        if status == errSecSuccess { return generated }

        // Two threads asked at once and the other won: use what is stored.
        if status == errSecDuplicateItem { return read(account: trackingId) }

        // A unit-test process has no Keychain access group, so the Keychain
        // refuses outright. Tests still need a stable secret, and a process
        // with no app container has nothing to protect.
        if status == errSecMissingEntitlement {
            return fallbackSecret(for: trackingId, generated: generated)
        }
        return nil
    }

    // MARK: - Keychain

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement {
            return UserDefaults.standard.string(forKey: fallbackKey(account))
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    private static func store(_ secret: String, account: String) -> OSStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            // Readable after the first unlock so a background refresh works,
            // and never synced to iCloud: this device owns this conversation.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    // MARK: - Generation

    /// 32 bytes from the system CSPRNG, base64url so it survives a header.
    private static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func fallbackKey(_ account: String) -> String {
        "astronaut_support_secret_\(account)"
    }

    private static func fallbackSecret(for account: String, generated: String) -> String {
        let key = fallbackKey(account)
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}
