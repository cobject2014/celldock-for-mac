import Foundation
import Security

/// Keychain-backed storage for SMS-forwarding endpoint/secret values,
/// mirroring `SOCKSProxyCredentialStore`'s use of a fixed service name with
/// per-item accounts.
struct SMSForwardingCredentialStore {
    enum Field: String {
        case barkServerURL = "bark.serverURL"
        case feishuWebhookURL = "feishu.webhookURL"
        case feishuSecret = "feishu.secret"
        case dingtalkAccessToken = "dingtalk.accessToken"
        case dingtalkSecret = "dingtalk.secret"
        case wecomWebhookURL = "wecom.webhookURL"
    }

    private let service = "app.celldock.mac.sms-forwarding"

    func value(for field: Field) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw BoundSocketError.systemCall(operation: "Keychain read", code: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func setValue(_ value: String, for field: Field) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw BoundSocketError.systemCall(operation: "Keychain update", code: updated)
        }
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BoundSocketError.systemCall(operation: "Keychain add", code: status)
        }
    }

    func deleteValue(for field: Field) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field.rawValue,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BoundSocketError.systemCall(operation: "Keychain delete", code: status)
        }
    }
}
