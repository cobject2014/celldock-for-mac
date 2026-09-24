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
        let calls = try decode([CallHistoryRecord].self, "calls.json") ?? []
        let recordings = try decode([CallRecordingRecord].self, "recordings.json") ?? []
        _ = try decode([SMSMessage.ID: Date].self, "deleted-message-ids.json")
        guard Set(messages.map(\.id)).count == messages.count,
              Set(calls.map(\.id)).count == calls.count,
              Set(recordings.map(\.id)).count == recordings.count else { throw BackupError.invalid("duplicate records") }
        // A recording can survive deletion of its history entry, but a history link must resolve.
        let recordingIDs = Set(recordings.map(\.id))
        for call in calls {
            if let id = call.recordingID, !recordingIDs.contains(id) { throw BackupError.invalid("missing recording link") }
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
