import Foundation

public enum BackupError: Error, LocalizedError {
    case invalid(String), cancelled, shortPassword, busy
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Backup validation failed: \(reason)"
        case .cancelled: return "Operation cancelled"
        case .shortPassword: return "Password must contain at least 12 characters"
        case .busy: return "CellDock must be idle before backup or restore"
        }
    }
}
public struct BackupFileEntry: Codable, Equatable {
    public let path: String
    public let size: UInt64
    public let sha256: String
    public init(path: String, size: UInt64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
}
public struct BackupCredential: Codable, Equatable {
    public let namespace: String
    public let account: String
    public let value: Data?
    public init(namespace: String, account: String, value: Data?) { self.namespace = namespace; self.account = account; self.value = value }
}
public struct BackupManifest: Codable {
    public let formatVersion: Int
    public let appVersion: String
    public let createdAt: Date
    public let files: [BackupFileEntry]
    public let messageCount: Int
    public let callCount: Int
    public let recordingCount: Int
    public init(formatVersion: Int = 1, appVersion: String, createdAt: Date = Date(), files: [BackupFileEntry], messageCount: Int = 0, callCount: Int = 0, recordingCount: Int = 0) {
        self.formatVersion = formatVersion; self.appVersion = appVersion; self.createdAt = createdAt; self.files = files
        self.messageCount = messageCount; self.callCount = callCount; self.recordingCount = recordingCount
    }
}
public struct BackupSnapshot {
    public let root: URL
    public let manifest: BackupManifest
    public init(root: URL, manifest: BackupManifest) { self.root = root; self.manifest = manifest }
}
