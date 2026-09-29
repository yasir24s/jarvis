import Foundation
import JarvisCore
import Security

/// Reads app secrets from the keychain (plan: M02-M04 §3.11). It lives in JarvisBrain because
/// JarvisCore never imports Security (D-13). It only reads: nothing here adds, updates or
/// deletes a keychain item. A value it returns is held in memory by the caller and never
/// logged, written to disk, put in argv or passed to a child environment.
public enum SecretStore {
    public static let service = "com.jarvis.assistant"

    /// The generic password stored for `service` and `account`, as UTF-8 text; nil when there
    /// is no such item or it cannot be read. Failures other than "not found" are logged with
    /// their OSStatus only.
    public static func read(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                JarvisLog.log("keychain read failed for account \(account): OSStatus \(status)", category: .security)
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
