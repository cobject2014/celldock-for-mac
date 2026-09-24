import Foundation
import CryptoKit
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

let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CellDock-backup-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: testRoot) }
let source = testRoot.appendingPathComponent("source")
try FileManager.default.createDirectory(at: source.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
let calls = Data("[{\"number\":\"测试😀\"}]".utf8)
let large = Data(repeating: 37, count: 2_100_123)
try calls.write(to: source.appendingPathComponent("calls.json"))
try large.write(to: source.appendingPathComponent("Recordings/test.m4a"))
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let fixture = BackupSnapshot(root: source, manifest: manifest([
    BackupFileEntry(path: "calls.json", size: UInt64(calls.count), sha256: digest(calls)),
    BackupFileEntry(path: "Recordings/test.m4a", size: UInt64(large.count), sha256: digest(large))
]))
let encrypted = testRoot.appendingPathComponent("test.celldockbackup")
try BackupArchive.seal(fixture, to: encrypted, password: "test-password-123", progress: { _ in }, cancelled: { false })
let restored = try BackupArchive.open(encrypted, into: testRoot.appendingPathComponent("restored"), password: "test-password-123", progress: { _ in }, cancelled: { false })
try expect(try Data(contentsOf: restored.root.appendingPathComponent("calls.json")) == calls, "calls changed")
try expect(try Data(contentsOf: restored.root.appendingPathComponent("Recordings/test.m4a")) == large, "multi-block audio changed")
let sealed = try Data(contentsOf: encrypted)
try expect(sealed.range(of: calls) == nil, "plaintext leaked")
try expectThrows { _ = try BackupArchive.open(encrypted, into: testRoot.appendingPathComponent("wrong"), password: "incorrect-password", progress: { _ in }, cancelled: { false }) }
for mutation in 0..<5 {
    var bad = sealed
    switch mutation {
    case 0: bad[bad.count / 2] ^= 1
    case 1: bad.removeLast()
    case 2: bad.append(0)
    case 3: bad[12] ^= 1
    default: bad = bad.prefix(40)
    }
    let badURL = testRoot.appendingPathComponent("bad-\(mutation)")
    try bad.write(to: badURL)
    let target = testRoot.appendingPathComponent("bad-open-\(mutation)")
    try expectThrows { _ = try BackupArchive.open(badURL, into: target, password: "test-password-123", progress: { _ in }, cancelled: { false }) }
    try expect(!FileManager.default.fileExists(atPath: target.path), "failed decrypt left plaintext")
}
let cancelledURL = testRoot.appendingPathComponent("cancelled")
try expectThrows { try BackupArchive.seal(fixture, to: cancelledURL, password: "test-password-123", progress: { _ in }, cancelled: { true }) }
try expect(!FileManager.default.fileExists(atPath: cancelledURL.path), "cancelled archive published")
try expectThrows { try BackupArchive.seal(fixture, to: encrypted, password: "test-password-123", progress: { _ in }, cancelled: { false }) }
try expect(try Data(contentsOf: encrypted) == sealed, "existing archive overwritten")
print("Backup archive tests passed")
// Authentication must also reject reordered/duplicated frames and a valid prefix without its end marker.
var frames: [Data] = []
var cursor = 36
while cursor < sealed.count {
    let length = sealed[(cursor + 5)..<(cursor + 9)].reduce(0) { ($0 << 8) | Int($1) }
    frames.append(sealed.subdata(in: cursor..<(cursor + 9 + length + 16)))
    cursor += 9 + length + 16
}
for index in 0..<3 {
    var altered = frames
    if index == 0 { altered.swapAt(1, 2) }
    if index == 1 { altered.insert(frames[1], at: 2) }
    if index == 2 { altered.removeLast() }
    let url = testRoot.appendingPathComponent("frames-\(index)")
    try (Data(sealed.prefix(36)) + altered.reduce(Data(), +)).write(to: url)
    try expectThrows { _ = try BackupArchive.open(url, into: testRoot.appendingPathComponent("frames-out-\(index)"), password: "test-password-123", progress: { _ in }, cancelled: { false }) }
}
let outside = testRoot.appendingPathComponent("outside")
try calls.write(to: outside)
try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Recordings/link.m4a"), withDestinationURL: outside)
let linked = BackupSnapshot(root: source, manifest: manifest([BackupFileEntry(path: "Recordings/link.m4a", size: UInt64(calls.count), sha256: digest(calls))]))
try expectThrows { try BackupArchive.seal(linked, to: testRoot.appendingPathComponent("linked"), password: "test-password-123", progress: { _ in }, cancelled: { false }) }
