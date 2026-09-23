import Foundation

enum CallTTSClient {
    static func endpoint(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw CallWelcomeError.invalidConfiguration
        }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (path.isEmpty ? "" : "/" + path) + "/v1/audio/speech"
        guard let url = parts.url else { throw CallWelcomeError.invalidConfiguration }
        return url
    }

    static func request(configuration: CallWelcomeConfiguration) throws -> URLRequest {
        try configuration.validate()
        var request = URLRequest(url: try endpoint(configuration.baseURL), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": configuration.text, "voice": configuration.voice,
            "speed": configuration.speed, "response_format": "wav", "stream": false
        ])
        request.setValue(String(request.httpBody!.count), forHTTPHeaderField: "Content-Length")
        return request
    }

    static func synthesize(configuration: CallWelcomeConfiguration) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 330
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await synthesize(configuration: configuration, session: session)
    }

    static func synthesize(configuration: CallWelcomeConfiguration, session: URLSession) async throws -> Data {
        let request = try request(configuration: configuration)
        let file: URL
        let response: URLResponse
        do { (file, response) = try await session.download(for: request, delegate: NoRedirect()) }
        catch {
            try Task.checkCancellation()
            throw CallWelcomeError.network((error as NSError).code)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CallWelcomeError.invalidAudio }
        guard response.statusCode == 200 else { throw CallWelcomeError.http(response.statusCode) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 44, size <= 32 * 1024 * 1024 else { throw CallWelcomeError.invalidAudio }
        return try CallWelcomeAudio.decode(wav: Data(contentsOf: file))
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
