import Foundation

struct CallTranscriptionConfiguration: Codable, Equatable {
    enum Scope: String, Codable, CaseIterable {
        case automaticAnswers, allRecordings
    }
    var enabled = false
    var scope: Scope = .automaticAnswers
    var baseURL = "http://DELLXPS.local:9100"
    var apiKey = ""
    var language = "auto"
    var webhookURL = ""

    func includes(_ record: CallRecordingRecord) -> Bool {
        enabled && (scope == .allRecordings || record.wasAutomaticallyAnswered == true)
    }

    func validate() throws {
        _ = try CallASRClient.endpoint(baseURL)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n"),
              ["auto", "zh", "en"].contains(language) else {
            throw CallTranscriptionError.invalidConfiguration
        }
        _ = try WeComWebhook.endpoint(webhookURL)
    }
}

enum CallTranscriptionError: LocalizedError {
    case invalidConfiguration, invalidResponse, audioTooLarge, invalidAudio, storage
    case http(Int), network(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L10n.tr("请填写有效的 ASR 地址、API Key、识别语言和企业微信 Webhook。")
        case .invalidResponse: return L10n.tr("ASR 返回了无效的转录结果。")
        case .audioTooLarge: return L10n.tr("音频分段超过 ASR 的 25 MiB 限制。")
        case .invalidAudio: return L10n.tr("无法读取录音，或录音没有可用音频。")
        case .storage: return L10n.tr("无法保存转录配置或进度，请检查本机存储空间和文件权限。")
        case let .http(code): return L10n.tr("ASR 请求失败（HTTP %d）。", code)
        case let .network(code): return L10n.tr("转录或推送连接失败（错误码 %d）。", code)
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? CallTranscriptionError { return error.localizedDescription }
        if let error = error as? WeComWebhook.Failure { return error.localizedDescription }
        // Network errors can contain URLs/credentials. Never persist their raw descriptions.
        return CallTranscriptionError.network((error as NSError).code).localizedDescription
    }
}

struct CallTranscriptionJob: Codable, Identifiable {
    enum Phase: String, Codable {
        case queued, transcribing, sending, sent, failed
        var title: String {
            switch self {
            case .queued: return L10n.tr("等待转录或推送")
            case .transcribing: return L10n.tr("正在转录")
            case .sending: return L10n.tr("正在推送")
            case .sent: return L10n.tr("已推送到企业微信")
            case .failed: return L10n.tr("转录或推送失败")
            }
        }
    }
    var id: UUID { record.id }
    let record: CallRecordingRecord
    var phase: Phase = .queued
    var transcript: String?
    // Keep the exact message list across restarts/language changes for reliable resume.
    var messages: [String] = []
    var sentMessageCount = 0
    var deliveryWebhookURL: String?
    var error: String?
}

enum CallTranscriptionText {
    static func messages(record: CallRecordingRecord, transcript: String) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let heading = L10n.tr("通话录音转录") + "\n" + record.number + " · " +
            formatter.string(from: record.startedAt) + " · " +
            L10n.tr("%lld 秒", Int64(max(0, record.duration)))
        let content = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.tr("未识别到语音。") : transcript
        // Leave room for the header and sequence label; split Unicode scalars so even
        // a very large combining-character sequence cannot exceed WeCom's byte limit.
        let prefix = String(heading.unicodeScalars.prefix(160))
        let budget = 2048 - prefix.utf8.count - 64
        var pieces: [String] = []
        var piece = ""
        var bytes = 0
        for scalar in content.unicodeScalars {
            let value = String(scalar)
            if bytes + value.utf8.count > budget {
                pieces.append(piece); piece = ""; bytes = 0
            }
            piece += value
            bytes += value.utf8.count
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces.enumerated().map { index, body in
            "\(prefix) [\(index + 1)/\(pieces.count)]\n\n\(body)"
        }
    }
}
