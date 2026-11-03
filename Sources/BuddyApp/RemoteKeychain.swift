import Foundation
import Security
import BuddyCore

/// The SSH token as a generic password (service com.tiagosantos.buddy, account remote-token). Never in UserDefaults or logs.
enum RemoteKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: RemoteAuth.keychainService,
         kSecAttrAccount as String: RemoteAuth.keychainAccount]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let rc = SecItemCopyMatching(q as CFDictionary, &out)
        if rc != errSecSuccess && rc != errSecItemNotFound { log.error("Keychain read failed: \(rc)") }
        guard rc == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8), RemoteAuth.isValidToken(s) else { return nil }
        return s
    }

    /// Delete, then add: an update would keep the old item's access list (for example an app the user once allowed).
    /// The new item trusts only Buddy itself; any other app must ask the user.
    @discardableResult
    static func write(_ token: String) -> Bool {
        guard delete() else { return false }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = "Buddy SSH token"
        if let access = (Legacy() as LegacyAccess).onlyBuddy() { q[kSecAttrAccess as String] = access } else {
            log.error("Keychain access list failed; using the default (the creating app only)")
        }
        let rc = SecItemAdd(q as CFDictionary, nil)
        if rc != errSecSuccess { log.error("Keychain write failed: \(rc)") }
        return rc == errSecSuccess
    }

    /// True when the item is gone (or was never there).
    @discardableResult
    static func delete() -> Bool {
        let rc = SecItemDelete(query as CFDictionary)
        if rc != errSecSuccess && rc != errSecItemNotFound { log.error("Keychain delete failed: \(rc)") }
        return rc == errSecSuccess || rc == errSecItemNotFound
    }
}

/// The data protection keychain needs a keychain-access-groups entitlement, which ad-hoc and self-signed builds cannot
/// have (errSecMissingEntitlement). So the item lives in the login keychain, and only the deprecated SecAccess API sets
/// its access list. Calling it through a protocol keeps the deprecation warning out of the build.
private protocol LegacyAccess { func onlyBuddy() -> SecAccess? }

private struct Legacy: LegacyAccess {
    @available(macOS, deprecated: 10.10)
    func onlyBuddy() -> SecAccess? {
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess, let app else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Buddy SSH token" as CFString, [app] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
