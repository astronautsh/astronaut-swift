import Foundation
import Security

/// The key that owns this install's chat.
///
/// Chat threads used to be addressed by device id, which is not a secret:
/// it travels in every analytics event, is shown in the owner's dashboard, and
/// ends up in logs. Anyone who came by one could read the conversation and
/// write in it. So the thread is owned by 32 random bytes generated here; the
/// server stores only their SHA-256 and can no longer hand a conversation to
/// anyone who merely knows who the user is.
///
/// Kept in UserDefaults, beside the device id it belongs with. The Keychain
/// would protect it from an unencrypted local backup, but it also outlives the
/// app: a reinstall would come back holding a key to a conversation whose
/// device id had been thrown away, which is exactly the drift this pair is
/// meant not to have. Deleting the app forgets the conversation, which is the
/// answer most people would expect anyway.
enum SupportSecretStore {
    /// This app's key, generated and stored the first time it is asked for.
    static func secret(for trackingId: String) -> String? {
        let key = storageKey(trackingId)
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }

        guard let generated = generate() else { return nil }
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// Takes on a session key the server minted, for a conversation it
    /// started.
    ///
    /// Replaces whatever this install was holding: a device that has never
    /// written has a key owning no conversation, and keeping it would leave
    /// the message the owner sent unreadable. Arrives only in an APNs payload,
    /// so only this phone ever sees it.
    static func adopt(_ key: String, for trackingId: String) {
        UserDefaults.standard.set(key, forKey: storageKey(trackingId))
    }

    /// 32 bytes from the system CSPRNG, base64url so it survives a header.
    private static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }

        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func storageKey(_ trackingId: String) -> String {
        "astronaut_chat_key_\(trackingId)"
    }
}
