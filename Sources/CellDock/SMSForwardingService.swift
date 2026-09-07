import Foundation

/// Forwards incoming SMS messages to third-party push/webhook channels
/// (Bark, Feishu, DingTalk and WeCom group bots). Reads its configuration
/// snapshot from `SMSForwardingStore` on the main actor, then performs the
/// actual network calls off the main actor.
final class SMSForwardingService {
    static let shared = SMSForwardingService()

    private let session: URLSession
    private let wecomSession = URLSession(configuration: .ephemeral)

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fire-and-forget entry point called for every newly-received SMS.
    @MainActor
    func forward(_ message: SMSMessage) {
        let store = SMSForwardingStore.shared
        let text = Self.formattedText(for: message)
        let channels = store.enabledChannels
        guard !channels.isEmpty else { return }

        let bark = store.bark
        let feishu = store.feishu
        let dingtalk = store.dingtalk
        let wecom = store.wecom

        for channel in channels {
            Task {
                let result = await self.send(
                    title: L10n.tr("[CellDock] 新短信"),
                    text: text,
                    channel: channel,
                    bark: bark,
                    feishu: feishu,
                    dingtalk: dingtalk,
                    wecom: wecom
                )
                let forwardResult: SMSForwardResult
                switch result {
                case .success:
                    forwardResult = .success(Date())
                case let .failure(error):
                    forwardResult = .failure(error.localizedDescription, Date())
                }
                await MainActor.run {
                    SMSForwardingStore.shared.recordResult(forwardResult, for: channel)
                }
            }
        }
    }

    /// Used by the settings UI's "发送测试" button.
    func sendTest(_ channel: SMSForwardChannel) async -> Result<Void, Error> {
        let (bark, feishu, dingtalk, wecom) = await MainActor.run {
            let store = SMSForwardingStore.shared
            return (store.bark, store.feishu, store.dingtalk, store.wecom)
        }
        return await send(
            title: L10n.tr("[CellDock] 测试推送"),
            text: L10n.tr("这是一条来自 CellDock 短信转发功能的测试消息。"),
            channel: channel,
            bark: bark,
            feishu: feishu,
            dingtalk: dingtalk,
            wecom: wecom
        )
    }

    static func formattedText(for message: SMSMessage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return L10n.tr(
            "来自：%@\n时间：%@\n内容：%@",
            message.sender,
            formatter.string(from: message.timestamp),
            message.body
        )
    }

    private func send(
        title: String,
        text: String,
        channel: SMSForwardChannel,
        bark: BarkForwardingConfiguration,
        feishu: FeishuForwardingConfiguration,
        dingtalk: DingTalkForwardingConfiguration,
        wecom: WeComForwardingConfiguration
    ) async -> Result<Void, Error> {
        do {
            switch channel {
            case .bark:
                try await sendBark(title: title, body: text, configuration: bark)
            case .feishu:
                try await sendFeishu(text: "\(title)\n\(text)", configuration: feishu)
            case .dingtalk:
                try await sendDingTalk(text: "\(title)\n\(text)", configuration: dingtalk)
            case .wecom:
                try await WeComWebhook.send(webhookURL: wecom.webhookURL,
                    text: "\(title)\n\(text)", session: wecomSession)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Bark

    /// Test exactly what is currently typed, without saving or enabling forwarding.
    func sendWeComTest(_ configuration: WeComForwardingConfiguration) async -> Result<Void, Error> {
        do {
            try await WeComWebhook.send(webhookURL: configuration.webhookURL,
                text: L10n.tr("[CellDock] 测试推送") + "\n" + L10n.tr("这是一条来自 CellDock 短信转发功能的测试消息。"),
                session: wecomSession)
            return .success(())
        } catch { return .failure(error) }
    }

    private func sendBark(
        title: String,
        body: String,
        configuration: BarkForwardingConfiguration
    ) async throws {
        guard configuration.isConfigured else { throw SMSForwardingError.missingConfiguration }
        let trimmed = configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: normalized) else { throw SMSForwardingError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "body": body,
        ])
        try await perform(request)
    }

    // MARK: - Feishu

    private func sendFeishu(
        text: String,
        configuration: FeishuForwardingConfiguration
    ) async throws {
        guard configuration.isConfigured else { throw SMSForwardingError.missingConfiguration }
        guard let url = URL(string: configuration.webhookURL) else {
            throw SMSForwardingError.invalidURL
        }

        var payload: [String: Any] = [
            "msg_type": "text",
            "content": ["text": text],
        ]
        let secret = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let timestamp = Int(Date().timeIntervalSince1970)
            payload["timestamp"] = String(timestamp)
            payload["sign"] = SMSForwardingSigning.feishuSign(
                secret: secret,
                timestampSeconds: timestamp
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await perform(request)
    }

    // MARK: - DingTalk

    private func sendDingTalk(
        text: String,
        configuration: DingTalkForwardingConfiguration
    ) async throws {
        guard configuration.isConfigured else { throw SMSForwardingError.missingConfiguration }

        // Built by hand rather than via URLComponents.queryItems: that API's
        // default percent-encoding leaves "+" untouched, and DingTalk's
        // base64 signature routinely contains it — a literal "+" a server
        // decodes as a space, silently breaking signature verification.
        var query = "access_token=\(SMSForwardingSigning.urlEncodedQueryValue(configuration.accessToken))"
        let secret = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let sign = SMSForwardingSigning.dingTalkSign(
                secret: secret,
                timestampMilliseconds: timestamp
            )
            query += "&timestamp=\(timestamp)"
            query += "&sign=\(SMSForwardingSigning.urlEncodedQueryValue(sign))"
        }
        guard let url = URL(string: "https://oapi.dingtalk.com/robot/send?\(query)") else {
            throw SMSForwardingError.invalidURL
        }

        let payload: [String: Any] = [
            "msgtype": "text",
            "text": ["content": text],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await perform(request)
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SMSForwardingError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SMSForwardingError.transport(L10n.tr("无效的服务端响应"))
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SMSForwardingError.transport(
                L10n.tr("HTTP %d：%@", httpResponse.statusCode, body)
            )
        }
    }
}
