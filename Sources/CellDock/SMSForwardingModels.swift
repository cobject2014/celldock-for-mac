import Foundation

enum SMSForwardChannel: String, CaseIterable, Codable, Identifiable {
    case bark
    case feishu
    case dingtalk
    case wecom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bark: return L10n.tr("Bark")
        case .feishu: return L10n.tr("飞书")
        case .dingtalk: return L10n.tr("钉钉")
        case .wecom: return L10n.tr("企业微信（Webhook）")
        }
    }

    var detail: String {
        switch self {
        case .bark: return L10n.tr("推送到 Bark App（iOS）")
        case .feishu: return L10n.tr("发送到飞书自定义机器人群")
        case .dingtalk: return L10n.tr("发送到钉钉自定义机器人群")
        case .wecom: return L10n.tr("填写完整 Webhook 地址，转发到企业微信群机器人")
        }
    }
}

/// Only the non-secret parts of SMS-forwarding configuration. The actual
/// endpoint/secret values live in the Keychain via
/// `SMSForwardingCredentialStore`, mirroring `SOCKSProxyStore`'s split
/// between `UserDefaults` (shape) and Keychain (credentials).
struct SMSForwardingSettings: Codable, Equatable {
    var enabledChannels: Set<SMSForwardChannel>

    static let empty = SMSForwardingSettings(enabledChannels: [])
}

enum SMSForwardResult: Equatable {
    case success(Date)
    case failure(String, Date)

    var date: Date {
        switch self {
        case let .success(date): return date
        case let .failure(_, date): return date
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var errorMessage: String? {
        if case let .failure(message, _) = self { return message }
        return nil
    }
}

enum SMSForwardingError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case httpStatus(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return L10n.tr("尚未填写该渠道的配置")
        case .invalidURL:
            return L10n.tr("配置里的地址无效")
        case let .httpStatus(code):
            return L10n.tr("服务端返回异常状态码 %d", code)
        case let .transport(message):
            return message
        }
    }
}
