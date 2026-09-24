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
final class MemorySettings: BackupSettingsAccess {
    var data: Data
    init(_ values: [String: Any] = [:]) throws { data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) }
    func read() throws -> Data { data }
    func replace(with encodedSettings: Data) throws { data = encodedSettings }
}
final class MemoryCredentials: BackupCredentialAccess {
    var values: [String: Data] = [:]
    var deny = false
    func read(namespace: String, account: String) throws -> Data? {
        if deny { throw CocoaError(.fileReadNoPermission) }
        return values[namespace + ":" + account]
    }
    func write(_ value: Data?, namespace: String, account: String) throws { values[namespace + ":" + account] = value }
}
let settings = try MemorySettings(["AutomaticallyAnswerCalls.v1": true, "AutomaticAnswerDelay.v1": 3])
let credentials = MemoryCredentials()
credentials.values["sms:wecom.webhookURL"] = Data("test-secret".utf8)
let captured = try BackupSnapshotBuilder.capture(root: source, into: testRoot.appendingPathComponent("snapshot"),
    settings: settings, credentials: credentials, appVersion: "test")
try BackupSnapshotBuilder.validate(captured)
try expect(captured.manifest.callCount == 1, "call count mismatch")
let capturedSecrets = try JSONDecoder().decode([BackupCredential].self, from: Data(contentsOf: captured.root.appendingPathComponent("credentials.json")))
try expect(capturedSecrets.first(where: { $0.account == "wecom.webhookURL" })?.value == Data("test-secret".utf8), "credential missing")
credentials.deny = true
try expectThrows { _ = try BackupSnapshotBuilder.capture(root: source, into: testRoot.appendingPathComponent("denied"), settings: settings, credentials: credentials, appVersion: "test") }
credentials.deny = false
let forbidden = try MemorySettings(["CellDock.modemNetworkServiceRecord": "source-machine"])
try expectThrows { _ = try BackupPreferences.decode(forbidden.read()) }
print("Snapshot and credential tests passed")
let portableSource = testRoot.appendingPathComponent("portable-source")
try FileManager.default.createDirectory(at: portableSource.appendingPathComponent("Sounds"), withIntermediateDirectories: true)
try Data("tone".utf8).write(to: portableSource.appendingPathComponent("Sounds/custom.aiff"))
let portableMessages = Data("[{\"id\":\"sms-1\",\"isRead\":true,\"body\":\"中文\"}]".utf8)
try portableMessages.write(to: portableSource.appendingPathComponent("messages.json"))
let deletedIDs = Data("{\"deleted-1\":\"2026-09-24T00:00:00Z\"}".utf8)
try deletedIDs.write(to: portableSource.appendingPathComponent("deleted-message-ids.json"))
let portableSettings = try MemorySettings(["CellDock.AlertSound.message.customFile.v1": "custom.aiff"])
credentials.values["sms:feishu.secret"] = Data()
let portable = try BackupSnapshotBuilder.capture(root: portableSource, into: testRoot.appendingPathComponent("portable"), settings: portableSettings, credentials: credentials, appVersion: "test")
try expect(try Data(contentsOf: portable.root.appendingPathComponent("messages.json")) == portableMessages, "message state changed")
try expect(try Data(contentsOf: portable.root.appendingPathComponent("deleted-message-ids.json")) == deletedIDs, "tombstones changed")
try expect(portable.manifest.files.contains { $0.path == "Sounds/custom.aiff" }, "sound omitted")
let portableSecrets = try JSONDecoder().decode([BackupCredential].self, from: Data(contentsOf: portable.root.appendingPathComponent("credentials.json")))
try expect(portableSecrets.first { $0.account == "feishu.secret" }?.value == Data(), "empty secret conflated with absence")
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
