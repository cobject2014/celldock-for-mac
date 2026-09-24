import Foundation
import CellDockBackupCore

enum BackupSnapshotProvider {
    static func validate(_ snapshot: BackupSnapshot) throws {
        try BackupSnapshotBuilder.validate(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
            let url = snapshot.root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(type, from: Data(contentsOf: url))
        }
        let messages = try decode([SMSMessage].self, "messages.json") ?? []
        _ = try decode([SMSMessage].self, "messages.backup.json")
        let calls = try decode([CallHistoryRecord].self, "calls.json") ?? []
        let recordings = try decode([CallRecordingRecord].self, "recordings.json") ?? []
        _ = try decode([SMSMessage.ID: Date].self, "deleted-message-ids.json")
        // These stores use JSONEncoder's default date format rather than ISO-8601.
        decoder.dateDecodingStrategy = .deferredToDate
        _ = try decode(CallTranscriptionConfiguration.self, "CallTranscriptions/settings.json")
        _ = try decode([CallTranscriptionJob].self, "CallTranscriptions/transcriptions.json")
        struct WelcomeBackup: Decodable { let configuration: CallWelcomeConfiguration; let pcm: Data? }
        if let welcome = try decode(WelcomeBackup.self, "CallWelcome/welcome.json") {
            guard welcome.configuration.speed.isFinite, (0.5...2).contains(welcome.configuration.speed),
                  welcome.pcm.map({ $0.count % 2 == 0 && $0.count <= 8000 * 2 * 300 }) ?? true else { throw BackupError.invalid("invalid greeting audio") }
        }
        guard Set(messages.map(\.id)).count == messages.count,
              Set(calls.map(\.id)).count == calls.count,
              Set(recordings.map(\.id)).count == recordings.count else { throw BackupError.invalid("duplicate records") }
        // Recording deletion intentionally preserves history and its old recordingID.
        // Validate links that still resolve; missing audio for indexed recordings remains an error.
        let recordingsByID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        for call in calls {
            if let id = call.recordingID, let recording = recordingsByID[id],
               let linkedCall = recording.callID, linkedCall != call.id { throw BackupError.invalid("mismatched recording link") }
        }
        for recording in recordings {
            guard recording.duration.isFinite, recording.duration >= 0 else { throw BackupError.invalid("invalid recording duration") }
        }
        let values = try BackupPreferences.decode(Data(contentsOf: snapshot.root.appendingPathComponent("preferences.plist")))
        if let data = values["SMSForwardingSettings.v1"] as? Data { _ = try decoder.decode(SMSForwardingSettings.self, from: data) }
        if let data = values["SOCKSProxyConfigurations.v1"] as? Data { _ = try decoder.decode([SOCKSProxyConfiguration].self, from: data) }
        if let data = values["VoWiFiUpstreamProxies.v1"] as? Data { _ = try decoder.decode([VoWiFiUpstreamProxyConfiguration].self, from: data) }
        if let data = values["VoWiFiUpstreamRoutes.v1"] as? Data { _ = try decoder.decode([String: VoWiFiUpstreamRoute].self, from: data) }
    }
}
