import Foundation
import CoreFoundation

public protocol BackupCredentialAccess {
    func read(namespace: String, account: String) throws -> Data?
    func write(_ value: Data?, namespace: String, account: String) throws
}
public protocol BackupSettingsAccess {
    func read() throws -> Data
    func replace(with encodedSettings: Data) throws
}

public enum BackupPreferences {
    public static let boolKeys: Set<String> = ["AutomaticallyAnswerCalls.v1", "AutomaticallyRecordCalls.v1", "AutoDeleteReadVerificationMessages.v1", "HideMenuBarIconWhenDisconnected.v1", "ShowsMenuBarNetworkSpeed.v1", "PresentationPrivacyProtectionEnabled.v1"]
    public static let stringKeys: Set<String> = Set(["CellDockAppearanceMode.v1", "CellDock.AppLanguage.v1", "PresentationPrivacyAliasSalt.v1", "NetworkToolsSelectedTab.v1", "CellDockUpdateChannel"])
        .union(["message", "incomingCall"].flatMap { kind in ["customFile", "displayName", "bundledSound"].map { "CellDock.AlertSound.\(kind).\($0).v1" } })
    public static let dataKeys: Set<String> = ["SMSForwardingSettings.v1", "SOCKSProxyConfigurations.v1", "VoWiFiUpstreamProxies.v1", "VoWiFiUpstreamRoutes.v1"]
    public static let keys = boolKeys.union(stringKeys).union(dataKeys).union(["AutomaticAnswerDelay.v1", "CommunicationSidebarWidth.v1"])
    public static let smsAccounts = ["bark.serverURL", "feishu.webhookURL", "feishu.secret", "dingtalk.accessToken", "dingtalk.secret", "wecom.webhookURL"]
    public static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= BackupPolicy.maxManifest,
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(values.keys).isSubset(of: keys) else { throw BackupError.invalid("unknown preferences") }
        for (key, value) in values {
            if boolKeys.contains(key) { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw BackupError.invalid("invalid switch") } }
            if stringKeys.contains(key) { guard let string = value as? String, string.utf8.count <= 4096 else { throw BackupError.invalid("invalid preference") } }
            if dataKeys.contains(key) {
                guard let encoded = value as? Data, encoded.count <= BackupPolicy.maxManifest else { throw BackupError.invalid("invalid configuration") }
                _ = try JSONSerialization.jsonObject(with: encoded)
            }
            if key == "AutomaticAnswerDelay.v1" { guard let n = value as? Int, (1...60).contains(n) else { throw BackupError.invalid("invalid delay") } }
            if key == "CommunicationSidebarWidth.v1" { guard let n = value as? Double, n.isFinite, (100...2000).contains(n) else { throw BackupError.invalid("invalid width") } }
            if key.contains(".customFile.") {
                guard let name = value as? String, !name.contains("/"), name != ".", name != ".." else { throw BackupError.invalid("invalid sound path") }
                try BackupPolicy.validateRelativePath("Sounds/" + name)
            }
        }
        return values
    }
    public static func accounts(_ values: [String: Any]) throws -> [(String, String)] {
        var result = smsAccounts.map { ("sms", $0) }
        for (namespace, key) in [("socks", "SOCKSProxyConfigurations.v1"), ("vowifi", "VoWiFiUpstreamProxies.v1")] {
            guard let data = values[key] as? Data else { continue }
            guard let configs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BackupError.invalid("invalid proxy configuration") }
            var seen = Set<UUID>()
            for config in configs {
                guard let raw = config["id"] as? String, let id = UUID(uuidString: raw), seen.insert(id).inserted else { throw BackupError.invalid("invalid proxy ID") }
                result.append((namespace, id.uuidString))
            }
        }
        return result
    }
    public static func validateCredential(_ item: BackupCredential) throws {
        guard (item.namespace == "sms" && smsAccounts.contains(item.account)) ||
                (["socks", "vowifi"].contains(item.namespace) && UUID(uuidString: item.account) != nil),
              (item.value?.count ?? 0) <= 65_536 else { throw BackupError.invalid("invalid credential") }
    }
}

public enum BackupSnapshotBuilder {
    public static let dataFiles = ["messages.json", "messages.backup.json", "calls.json", "recordings.json", "deleted-message-ids.json"]
    public static func capture(root: URL, into staging: URL, settings: BackupSettingsAccess,
                               credentials: BackupCredentialAccess, appVersion: String,
                               additionalAccounts: [(String, String)] = []) throws -> BackupSnapshot {
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw BackupError.invalid("snapshot exists") }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: staging) } }
        let preferences = try settings.read()
        let values = try BackupPreferences.decode(preferences)
        var secrets: [BackupCredential] = []
        var seenAccounts = Set<String>()
        for (namespace, account) in try BackupPreferences.accounts(values) + additionalAccounts where seenAccounts.insert(namespace + ":" + account).inserted {
            secrets.append(BackupCredential(namespace: namespace, account: account, value: try credentials.read(namespace: namespace, account: account)))
        }
        try preferences.write(to: staging.appendingPathComponent("preferences.plist"))
        try JSONEncoder().encode(secrets).write(to: staging.appendingPathComponent("credentials.json"))
        var paths = ["preferences.plist", "credentials.json"]
        for path in dataFiles where FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let url = try BackupFiles.checkedFile(root: root, path: path)
            let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            try FileManager.default.copyItem(at: url, to: staging.appendingPathComponent(path)); paths.append(path)
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw BackupError.busy }
        }
        for folder in ["Recordings", "Sounds"] {
            let directory = root.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackupError.invalid("linked directory") }
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = folder + "/" + url.lastPathComponent
                let checked = try BackupFiles.checkedFile(root: root, path: path)
                try FileManager.default.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: checked, to: staging.appendingPathComponent(path)); paths.append(path)
            }
        }
        var entries: [BackupFileEntry] = []
        for path in paths.sorted() {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            entries.append(BackupFileEntry(path: path, size: UInt64(size), sha256: try BackupFiles.hash(url)))
        }
        let snapshot = BackupSnapshot(root: staging, manifest: BackupManifest(appVersion: appVersion, files: entries,
            messageCount: try rows(staging, "messages.json").count, callCount: try rows(staging, "calls.json").count,
            recordingCount: try rows(staging, "recordings.json").count))
        try validate(snapshot, allowAdditionalCredentials: !additionalAccounts.isEmpty)
        success = true
        return snapshot
    }
    public static func rows(_ root: URL, _ path: String) throws -> [[String: Any]] {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: metadata(url)) as? [[String: Any]] else { throw BackupError.invalid("invalid records") }
        return rows
    }
    public static func metadata(_ url: URL) throws -> Data {
        guard try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw BackupError.invalid("metadata too large") }
        return try Data(contentsOf: url)
    }
    public static func validate(_ snapshot: BackupSnapshot, allowAdditionalCredentials: Bool = false) throws {
        try BackupPolicy.validateManifest(snapshot.manifest)
        let paths = Set(snapshot.manifest.files.map(\.path))
        guard paths.contains("preferences.plist"), paths.contains("credentials.json") else { throw BackupError.invalid("incomplete snapshot") }
        for entry in snapshot.manifest.files {
            let url = try BackupFiles.checkedFile(root: snapshot.root, path: entry.path)
            guard try UInt64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == entry.size,
                  try BackupFiles.hash(url) == entry.sha256 else { throw BackupError.invalid("snapshot changed") }
        }
        let values = try BackupPreferences.decode(Data(contentsOf: snapshot.root.appendingPathComponent("preferences.plist")))
        let expected = Set(try BackupPreferences.accounts(values).map { $0.0 + ":" + $0.1 })
        let credentials = try JSONDecoder().decode([BackupCredential].self, from: Data(contentsOf: snapshot.root.appendingPathComponent("credentials.json")))
        var seen = Set<String>()
        for item in credentials {
            try BackupPreferences.validateCredential(item)
            guard seen.insert(item.namespace + ":" + item.account).inserted else { throw BackupError.invalid("duplicate credential") }
        }
        guard allowAdditionalCredentials ? expected.isSubset(of: seen) : expected == seen else { throw BackupError.invalid("credential inventory mismatch") }
        let messages = try rows(snapshot.root, "messages.json"), calls = try rows(snapshot.root, "calls.json"), recordings = try rows(snapshot.root, "recordings.json")
        guard messages.count == snapshot.manifest.messageCount, calls.count == snapshot.manifest.callCount,
              recordings.count == snapshot.manifest.recordingCount else { throw BackupError.invalid("record count mismatch") }
        for record in recordings {
            guard let name = record["fileName"] as? String, paths.contains("Recordings/" + name) else { throw BackupError.invalid("missing recording") }
        }
        for (key, value) in values where key.contains(".customFile.") {
            guard let name = value as? String, paths.contains("Sounds/" + name) else { throw BackupError.invalid("missing custom sound") }
        }
    }
}
