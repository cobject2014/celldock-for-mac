import Foundation
import Darwin

/// The caller must hold an exclusive maintenance barrier for the entire transaction.
public struct BackupRestoreTransaction {
    public enum Outcome: String { case unchanged, committed, rolledBack, acknowledged }
    public static func outcome(at journal: URL) throws -> Outcome? {
        let url = journal.appendingPathExtension("outcome")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let value = Outcome(rawValue: String(decoding: try BackupSnapshotBuilder.metadata(url), as: UTF8.self)) else {
            throw BackupError.invalid("invalid restore outcome")
        }
        return value
    }
    public static func acknowledge(at journal: URL) throws { try writeOutcome(.acknowledged, at: journal) }
    private static func writeOutcome(_ outcome: Outcome, at journal: URL) throws {
        let url = journal.appendingPathExtension("outcome")
        try Data(outcome.rawValue.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw BackupError.invalid("outcome sync failed") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BackupError.invalid("outcome sync failed") }
    }
    private struct Journal: Codable {
        var phase: String
        let rollback: String
        let paths: [String]
        let accounts: [BackupCredential]
    }
    let root: URL
    let journal: URL
    let settings: BackupSettingsAccess
    let credentials: BackupCredentialAccess
    public init(root: URL, journal: URL, settings: BackupSettingsAccess, credentials: BackupCredentialAccess) {
        self.root = root; self.journal = journal; self.settings = settings; self.credentials = credentials
    }
    public static func hasPendingRecovery(at journal: URL) -> Bool {
        FileManager.default.fileExists(atPath: journal.path)
    }
    public func apply(_ verified: BackupSnapshot, rollback: URL, password: String,
                      checkpoint: (String) throws -> Void = { _ in }) throws {
        guard !Self.hasPendingRecovery(at: journal) else { throw BackupError.busy }
        try Self.writeOutcome(.unchanged, at: journal)
        try BackupSnapshotBuilder.validate(verified)
        let incoming = try secrets(verified)
        let temporary = try BackupFiles.privateDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let before = try BackupSnapshotBuilder.capture(root: root, into: temporary.appendingPathComponent("before"),
            settings: settings, credentials: credentials, appVersion: "rollback", additionalAccounts: incoming.map { ($0.namespace, $0.account) })
        try BackupArchive.seal(before, to: rollback, password: password, progress: { _ in }, cancelled: { false })
        let checked = try BackupArchive.open(rollback, into: temporary.appendingPathComponent("verified"), password: password, progress: { _ in }, cancelled: { false })
        try BackupSnapshotBuilder.validate(checked, allowAdditionalCredentials: true)
        let paths = Set((before.manifest.files + verified.manifest.files).map(\.path)).filter { $0 != "preferences.plist" && $0 != "credentials.json" }.sorted()
        // A derived fallback must not resurrect messages from the pre-restore installation.
        var record = Journal(phase: "prepared", rollback: rollback.path, paths: paths,
            accounts: try secrets(before).map { BackupCredential(namespace: $0.namespace, account: $0.account, value: nil) })
        try save(record)
        do {
            try checkpoint("prepared")
            try install(verified, record: &record, checkpoint: checkpoint)
            record.phase = "committed"; try save(record); try checkpoint("committed")
            try Self.writeOutcome(.committed, at: journal)
            try FileManager.default.removeItem(at: journal)
            try syncDirectory(journal.deletingLastPathComponent())
        } catch {
            do { try recover(rollback: rollback, password: password) }
            catch { throw BackupError.invalid("recovery required; keep rollback archive") }
            throw error
        }
    }
    public func recover(rollback: URL, password: String) throws {
        guard Self.hasPendingRecovery(at: journal) else { return }
        var record = try JSONDecoder().decode(Journal.self, from: BackupSnapshotBuilder.metadata(journal))
        guard record.rollback == rollback.path else { throw BackupError.invalid("rollback mismatch") }
        for path in record.paths { try BackupPolicy.validateRelativePath(path) }
        for item in record.accounts {
            try BackupPreferences.validateCredential(item)
            guard item.value == nil else { throw BackupError.invalid("invalid journal") }
        }
        let temporary = try BackupFiles.privateDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let before = try BackupArchive.open(rollback, into: temporary.appendingPathComponent("before"), password: password, progress: { _ in }, cancelled: { false })
        try BackupSnapshotBuilder.validate(before, allowAdditionalCredentials: true)
        let archivedAccounts = Set(try secrets(before).map { $0.namespace + ":" + $0.account })
        guard Set(record.accounts.map { $0.namespace + ":" + $0.account }) == archivedAccounts,
              Set(before.manifest.files.map(\.path).filter { $0 != "preferences.plist" && $0 != "credentials.json" }).isSubset(of: Set(record.paths)) else { throw BackupError.invalid("invalid rollback inventory") }
        record.phase = "rollingBack"; try save(record)
        try install(before, record: &record, checkpoint: { _ in })
        try Self.writeOutcome(.rolledBack, at: journal)
        try FileManager.default.removeItem(at: journal)
        try syncDirectory(journal.deletingLastPathComponent())
    }
    private func secrets(_ snapshot: BackupSnapshot) throws -> [BackupCredential] {
        try JSONDecoder().decode([BackupCredential].self, from: BackupSnapshotBuilder.metadata(snapshot.root.appendingPathComponent("credentials.json")))
    }
    private func install(_ snapshot: BackupSnapshot, record: inout Journal, checkpoint: (String) throws -> Void) throws {
        record.phase = "filesApplying"; try save(record)
        let present = Set(snapshot.manifest.files.map(\.path))
        for path in record.paths {
            try BackupPolicy.validateRelativePath(path)
            guard path != "preferences.plist", path != "credentials.json" else { throw BackupError.invalid("invalid data path") }
            let destination = root.appendingPathComponent(path)
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackupError.invalid("linked destination") }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try BackupFiles.checkedFile(root: root, path: path) }
            if present.contains(path) {
                let original = try BackupFiles.checkedFile(root: snapshot.root, path: path)
                let staging = parent.appendingPathComponent(".restore-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: original, to: staging)
                let handle = try FileHandle(forWritingTo: staging); try handle.synchronize(); try handle.close()
                guard rename(staging.path, destination.path) == 0 else { throw BackupError.invalid("file replacement failed") }
            } else if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try syncDirectory(parent)
            try checkpoint("file:" + path)
        }
        record.phase = "settingsApplying"; try save(record)
        try settings.replace(with: BackupSnapshotBuilder.metadata(snapshot.root.appendingPathComponent("preferences.plist")))
        try checkpoint("settingsApplying")
        record.phase = "credentialsApplying"; try save(record)
        let incoming = try secrets(snapshot)
        for item in record.accounts {
            let value = incoming.first { $0.namespace == item.namespace && $0.account == item.account }?.value
            try credentials.write(value, namespace: item.namespace, account: item.account)
            try checkpoint("credential:" + item.namespace + ":" + item.account)
        }
        try checkpoint("credentialsApplying")
    }
    private func save(_ record: Journal) throws {
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let handle = try FileHandle(forWritingTo: journal); try handle.synchronize(); try handle.close()
        try syncDirectory(journal.deletingLastPathComponent())
    }
    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw BackupError.invalid("directory sync failed") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BackupError.invalid("directory sync failed") }
    }
}
