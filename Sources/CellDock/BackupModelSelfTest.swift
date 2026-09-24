#if DEBUG
import Foundation
import AVFoundation
import Darwin
import CellDockBackupCore

/// Isolated business-model integration test. Runs before any live store is constructed.
enum BackupModelSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--backup-model-self-test") else { return }
        do { try run(); print("Backup business-model and stereo migration tests passed"); Darwin.exit(0) }
        catch { print("Backup model test failed: \(error)"); Darwin.exit(1) }
    }
    private final class Settings: BackupSettingsAccess {
        var data = try! PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        func read() throws -> Data { data }
        func replace(with data: Data) throws { self.data = data }
    }
    private final class Credentials: BackupCredentialAccess {
        var data: [String: Data] = [:]
        func read(namespace: String, account: String) throws -> Data? { data[namespace + account] }
        func write(_ value: Data?, namespace: String, account: String) throws { data[namespace + account] = value }
    }
    private static func run() throws {
        let temp = try BackupFiles.privateDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let messages = ["module-a", "module-b"].map { module in
            SMSMessage(id: module + "|test-sms", moduleID: CellularModuleID(rawValue: module), modemIndices: [1], sender: "10000", body: "中文测试😀", timestamp: date, rawPDUs: [], isRead: true, firstSeenAt: date)
        }
        let callID = UUID(), recordingID = UUID()
        let call = CallHistoryRecord(id: callID, direction: .incoming, number: "10000", moduleID: CellularModuleID(rawValue: "module-a"), startedAt: date, connectedAt: date, endedAt: date.addingTimeInterval(1), endReason: .remoteHangup, recordingID: recordingID, wasAutomaticallyAnswered: true)
        let record = CallRecordingRecord(id: recordingID, callID: callID, number: "10000", direction: .incoming, startedAt: date, endedAt: date.addingTimeInterval(1), duration: 1, fileName: "stereo.caf", isIncomplete: false, wasAutomaticallyAnswered: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(messages).write(to: source.appendingPathComponent("messages.json"))
        try encoder.encode([call]).write(to: source.appendingPathComponent("calls.json"))
        try encoder.encode([record]).write(to: source.appendingPathComponent("recordings.json"))
        try encoder.encode(["deleted": date]).write(to: source.appendingPathComponent("deleted-message-ids.json"))
        let audio = source.appendingPathComponent("Recordings/stereo.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
            buffer.frameLength = 8_000
            for frame in 0..<8_000 {
                buffer.floatChannelData![0][frame] = 0.25
                buffer.floatChannelData![1][frame] = -0.125
            }
            try file.write(from: buffer)
        }
        let fixture = try BackupSnapshotBuilder.capture(root: source, into: temp.appendingPathComponent("snapshot"), settings: Settings(), credentials: Credentials(), appVersion: "test")
        try BackupSnapshotProvider.validate(fixture)
        let archive = temp.appendingPathComponent("test.celldockbackup")
        try BackupArchive.seal(fixture, to: archive, password: "test-password-123", progress: { _ in }, cancelled: { false })
        let decoded = try BackupArchive.open(archive, into: temp.appendingPathComponent("decoded"), password: "test-password-123", progress: { _ in }, cancelled: { false })
        try BackupSnapshotProvider.validate(decoded)
        let target = temp.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try BackupRestoreTransaction(root: target, journal: temp.appendingPathComponent("journal"), settings: Settings(), credentials: Credentials())
            .apply(decoded, rollback: temp.appendingPathComponent("rollback"), password: "test-password-123")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard try decoder.decode([SMSMessage].self, from: Data(contentsOf: target.appendingPathComponent("messages.json"))) == messages,
              try decoder.decode([CallHistoryRecord].self, from: Data(contentsOf: target.appendingPathComponent("calls.json"))) == [call],
              try decoder.decode([CallRecordingRecord].self, from: Data(contentsOf: target.appendingPathComponent("recordings.json"))) == [record],
              try BackupFiles.hash(audio) == BackupFiles.hash(target.appendingPathComponent("Recordings/stereo.caf")),
              try AVAudioFile(forReading: target.appendingPathComponent("Recordings/stereo.caf")).processingFormat.channelCount == 2 else {
            throw BackupError.invalid("business data or stereo audio changed")
        }
        try encoder.encode([call, call]).write(to: source.appendingPathComponent("calls.json"))
        let duplicate = try BackupSnapshotBuilder.capture(root: source, into: temp.appendingPathComponent("duplicate"), settings: Settings(), credentials: Credentials(), appVersion: "test")
        do { try BackupSnapshotProvider.validate(duplicate) }
        catch { return }
        throw BackupError.invalid("duplicate history accepted")
    }
}
#endif
