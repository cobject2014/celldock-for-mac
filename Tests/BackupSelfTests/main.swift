import Foundation
import CellDockBackupCore

struct TestFailure: Error { let message: String }
func expect(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(message: message) }
}
func expectThrows(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TestFailure(message: "Expected rejection")
}

for path in ["../calls.json", "/calls.json", "Recordings/../calls.json", "Recordings//a", "Recordings/", "calls.json/child", "other.json", "Recordings/a\\b", "Recordings/a\u{0}"] {
    try expectThrows { try BackupPolicy.validateRelativePath(path) }
}
try BackupPolicy.validateRelativePath("Recordings/通话.m4a")
let entry = BackupFileEntry(path: "calls.json", size: 2, sha256: String(repeating: "a", count: 64))
func manifest(_ files: [BackupFileEntry], version: Int = 1) -> BackupManifest {
    BackupManifest(formatVersion: version, appVersion: "test", createdAt: Date(timeIntervalSince1970: 0), files: files,
                   messageCount: 0, callCount: 0, recordingCount: 0)
}
try BackupPolicy.validateManifest(manifest([entry]))
try expectThrows { try BackupPolicy.validateManifest(manifest([entry, entry])) }
try expectThrows { try BackupPolicy.validateManifest(manifest([entry], version: 2)) }
try expectThrows { try BackupPolicy.validateManifest(manifest([BackupFileEntry(path: "calls.json", size: UInt64.max, sha256: entry.sha256)])) }
try expectThrows { try BackupPolicy.validateManifest(manifest([BackupFileEntry(path: "calls.json", size: 0, sha256: "bad")])) }
print("Backup policy tests passed")
