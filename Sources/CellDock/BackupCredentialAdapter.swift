import Foundation
import Security
import CellDockBackupCore

/// Only the exact CellDock credential accounts named by the snapshot are accessed.
struct BackupCredentialAdapter: BackupCredentialAccess {
    private func query(_ namespace: String, _ account: String) throws -> [String: Any] {
        try BackupPreferences.validateCredential(BackupCredential(namespace: namespace, account: account, value: nil))
        let services = ["sms": "app.celldock.mac.sms-forwarding", "socks": "app.celldock.mac.socks-proxy", "vowifi": "app.celldock.mac.vowifi-upstream"]
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: services[namespace]!, kSecAttrAccount as String: account]
    }
    func read(namespace: String, account: String) throws -> Data? {
        var query = try query(namespace, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BackupError.invalid("credential access denied") }
        return data
    }
    func write(_ value: Data?, namespace: String, account: String) throws {
        let query = try query(namespace, account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BackupError.invalid("credential delete failed") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: value]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var added = query.merging(attributes) { _, new in new }
            added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BackupError.invalid("credential write failed") }
    }
}

struct BackupSettingsAdapter: BackupSettingsAccess {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func read() throws -> Data {
        var values: [String: Any] = [:]
        for key in BackupPreferences.keys { values[key] = defaults.object(forKey: key) }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }
    func replace(with encodedSettings: Data) throws {
        let values = try BackupPreferences.decode(encodedSettings)
        for key in BackupPreferences.keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        guard defaults.synchronize() else { throw BackupError.invalid("preferences save failed") }
    }
}
