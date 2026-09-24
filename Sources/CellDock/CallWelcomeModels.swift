import Foundation

struct CallWelcomeConfiguration: Codable, Equatable {
    var enabled = false
    var baseURL = "http://DELLXPS.local:9101"
    var apiKey = ""
    var text = "您好，我现在不方便接听，请留言，我会尽快回复您。"
    var voice = "cosyvoice-official"
    var speed = 1.0

    func validate() throws {
        _ = try CallTTSClient.endpoint(baseURL)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 5000,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n"),
              !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              speed.isFinite, (0.5...2.0).contains(speed) else {
            throw CallWelcomeError.invalidConfiguration
        }
    }

    func hasSameSpeech(as other: Self) -> Bool {
        var lhs = self, rhs = other
        lhs.enabled = false; rhs.enabled = false
        return lhs == rhs
    }
}

enum CallWelcomeError: LocalizedError {
    case invalidConfiguration, invalidAudio, storage, notPrepared, busy
    case http(Int), network(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L10n.tr("请填写有效的 TTS 地址、API Key、音色和欢迎语（最多 5000 字），语速范围为 0.5–2.0。")
        case .invalidAudio: return L10n.tr("TTS 未返回有效语音，或语音超过 5 分钟。")
        case .storage: return L10n.tr("无法保存欢迎语，请检查本机存储空间和文件权限。")
        case .notPrepared: return L10n.tr("请先配置并生成欢迎语。")
        case .busy: return L10n.tr("正在生成欢迎语，请稍候。")
        case let .http(code): return L10n.tr("TTS 请求失败（HTTP %d）。", code)
        case let .network(code): return L10n.tr("TTS 连接失败（错误码 %d）。", code)
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? CallWelcomeError { return error.localizedDescription }
        return CallWelcomeError.network((error as NSError).code).localizedDescription
    }
}
