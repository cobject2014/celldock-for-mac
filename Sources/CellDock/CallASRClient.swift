import Foundation

enum CallASRClient {
    static func endpoint(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw CallTranscriptionError.invalidConfiguration
        }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (path.isEmpty ? "" : "/" + path) + "/v1/audio/transcriptions"
        guard let url = parts.url else { throw CallTranscriptionError.invalidConfiguration }
        return url
    }

    static func request(audio: Data, configuration: CallTranscriptionConfiguration,
                        boundary: String = UUID().uuidString) throws -> URLRequest {
        guard audio.count <= 25 * 1024 * 1024 else { throw CallTranscriptionError.audioTooLarge }
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.apiKey.contains("\r"), !configuration.apiKey.contains("\n"),
              ["auto", "zh", "en"].contains(configuration.language) else {
            throw CallTranscriptionError.invalidConfiguration
        }
        var body = Data()
        for (name, value) in [("model", "qwen3-asr-0.6b"), ("language", configuration.language), ("response_format", "json")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: try endpoint(configuration.baseURL), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        return request
    }

    static func decode(data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw CallTranscriptionError.http(status) }
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CallTranscriptionError.invalidResponse
        }
        return response.text
    }

    static func transcribe(fileURL: URL, remoteOnly: Bool, configuration: CallTranscriptionConfiguration) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CellDock-ASR-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let segments = try CallTranscriptionAudio.prepare(source: fileURL, directory: directory, remoteOnly: remoteOnly)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForResource = 660
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        var results: [String] = []
        for segment in segments {
            try Task.checkCancellation()
            let request = try request(audio: Data(contentsOf: segment), configuration: configuration)
            let text = try await upload(request, session: session)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { results.append(text) }
        }
        return results.joined(separator: "\n")
    }

    static func upload(_ request: URLRequest, session: URLSession,
                       pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> String {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: NoRedirect())
            } catch {
                try Task.checkCancellation()
                throw CallTranscriptionError.network((error as NSError).code)
            }
            guard let response = response as? HTTPURLResponse else { throw CallTranscriptionError.invalidResponse }
            if response.statusCode == 503, attempt < 3 {
                try await pause([2, 5, 10][attempt] * 1_000_000_000)
                continue
            }
            return try decode(data: data, status: response.statusCode)
        }
        throw CallTranscriptionError.http(503)
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
