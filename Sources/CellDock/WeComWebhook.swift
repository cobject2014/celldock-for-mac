import Foundation

struct WeComForwardingConfiguration: Equatable {
    var webhookURL: String = ""
    var isConfigured: Bool { (try? WeComWebhook.endpoint(webhookURL)) != nil }
}

enum WeComWebhook {
    enum Failure: LocalizedError {
        case invalidURL, invalidResponse, textTooLong
        case rejected(Int), httpStatus(Int), network(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return L10n.tr("请填写完整的企业微信群机器人 HTTPS Webhook 地址（包含 key）。")
            case .invalidResponse: return L10n.tr("企业微信返回了无效响应，无法确认发送成功。")
            case .textTooLong: return L10n.tr("转发文本超过企业微信的 2048 字节限制，未发送；完整短信仍保存在本机。")
            case let .rejected(code): return L10n.tr("企业微信拒绝发送（错误码 %d），请检查机器人地址或发送频率。", code)
            case let .httpStatus(code): return L10n.tr("服务端返回异常状态码 %d", code)
            case let .network(code): return L10n.tr("企业微信连接失败（错误码 %d）。", code)
            }
        }
    }

    static func endpoint(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "qyapi.weixin.qq.com",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path == "/cgi-bin/webhook/send",
              let items = parts.queryItems, items.count == 1,
              items[0].name == "key",
              let key = items[0].value, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = parts.url else { throw Failure.invalidURL }
        return url
    }

    static func request(webhookURL: String, text: String) throws -> URLRequest {
        let url = try endpoint(webhookURL)
        guard text.utf8.count <= 2048 else { throw Failure.textTooLong }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "msgtype": "text", "text": ["content": text]
        ])
        return request
    }

    static func validateResponse(data: Data, statusCode: Int) throws {
        guard (200 ..< 300).contains(statusCode) else { throw Failure.httpStatus(statusCode) }
        struct Response: Decodable { let errcode: Int }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Failure.invalidResponse
        }
        // HTTP 200 alone is not a successful WeCom delivery. Do not display
        // the raw response: remote error text can contain the secret URL.
        guard result.errcode == 0 else { throw Failure.rejected(result.errcode) }
    }

    static func send(webhookURL: String, text: String, session: URLSession) async throws {
        let request = try request(webhookURL: webhookURL, text: text)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirect())
        } catch {
            // URLError descriptions may contain the webhook key.
            throw Failure.network((error as NSError).code)
        }
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        try validateResponse(data: data, statusCode: response.statusCode)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
