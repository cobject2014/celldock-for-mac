import AVFoundation
import Foundation

enum TestFailure: Error { case failed(String) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

func recording(automatic: Bool = true) -> CallRecordingRecord {
    CallRecordingRecord(id: UUID(), callID: UUID(), number: "10086", direction: .incoming,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_061), duration: 61,
        fileName: "test.m4a", isIncomplete: false, wasAutomaticallyAnswered: automatic)
}

actor Delivery {
    var transcriptions = 0
    var messages: [String] = []
    var shouldFail = true
    func transcribe() -> String { transcriptions += 1; return String(repeating: "这是转录文本。", count: 400) }
    func send(_ text: String) throws {
        if messages.count == 1 && shouldFail { shouldFail = false; throw URLError(.timedOut) }
        messages.append(text)
    }
}

final class ASRFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var replies: [(Int, String)] = []
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> (Int, String) in
            Self.requests += 1
            return Self.replies.isEmpty ? (500, "unexpected request") : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CallTranscriptionSelfTests {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestFailure.failed("background processing did not finish")
    }

    @MainActor static func main() async {
        do {
            var config = CallTranscriptionConfiguration()
            try expect(!config.includes(recording()), "disabled feature queued a recording")
            config.enabled = true
            config.apiKey = "asr-test-secret"
            config.webhookURL = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wecom-test-secret"
            try expect(config.includes(recording()), "automatic answer was excluded")
            try expect(!config.includes(recording(automatic: false)), "manual recording leaked into automatic-only scope")
            config.scope = .allRecordings
            try expect(config.includes(recording(automatic: false)), "all-recordings scope excluded manual recording")

            let request = try CallASRClient.request(audio: Data([0, 1, 2, 255]), configuration: config, boundary: "fixture-boundary")
            try expect(request.url?.absoluteString == "http://DELLXPS.local:9100/v1/audio/transcriptions", "wrong ASR upload endpoint")
            try expect(request.httpMethod == "POST", "ASR request is not POST")
            try expect(request.value(forHTTPHeaderField: "X-API-Key") == "asr-test-secret", "missing ASR authentication")
            try expect(request.value(forHTTPHeaderField: "Content-Length") == String(request.httpBody!.count), "missing or wrong Content-Length")
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            try expect(body.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav"), "audio multipart field malformed")
            try expect(body.contains("qwen3-asr-0.6b") && body.contains("name=\"language\"\r\n\r\nauto"), "ASR model/language missing")
            try expect(!request.url!.absoluteString.contains(config.apiKey) && !body.contains(config.apiKey), "ASR key leaked outside headers")
            let text = try CallASRClient.decode(data: Data(#"{"text":"你好 Docker","model":"qwen3-asr-0.6b","audio_duration_s":1.2,"elapsed_s":0.3}"#.utf8), status: 200)
            try expect(text == "你好 Docker", "ASR response lost text")
            try expect(tryDecodeEmpty(), "silence response should be accepted")
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [ASRFixtureProtocol.self]
            let session = URLSession(configuration: sessionConfig)
            defer { session.invalidateAndCancel() }
            ASRFixtureProtocol.lock.withLock {
                ASRFixtureProtocol.replies = [(503, "busy"), (200, #"{"text":"恢复后的识别","model":"qwen3-asr-0.6b","audio_duration_s":1,"elapsed_s":0.2}"#)]
                ASRFixtureProtocol.requests = 0
            }
            let retried = try await CallASRClient.upload(request, session: session, pause: { _ in })
            try expect(retried == "恢复后的识别", "busy ASR request did not recover")
            try expect(ASRFixtureProtocol.lock.withLock { ASRFixtureProtocol.requests } == 2, "busy ASR retry count incorrect")
            ASRFixtureProtocol.lock.withLock {
                ASRFixtureProtocol.replies = [(401, "secret"), (200, #"{"text":"must not retry"}"#)]
                ASRFixtureProtocol.requests = 0
            }
            do {
                _ = try await CallASRClient.upload(request, session: session, pause: { _ in })
                throw TestFailure.failed("authentication failure was retried")
            } catch CallTranscriptionError.http(401) { }
            try expect(ASRFixtureProtocol.lock.withLock { ASRFixtureProtocol.requests } == 1, "authentication failure triggered retries")
            for (status, body) in [(503, "busy"), (401, "asr-test-secret"), (200, "{}"), (200, "not json")] {
                do {
                    _ = try CallASRClient.decode(data: Data(body.utf8), status: status)
                    throw TestFailure.failed("ASR error accepted as transcript")
                } catch let error as CallTranscriptionError {
                    try expect(!error.localizedDescription.contains("asr-test-secret"), "ASR error exposed secret")
                }
            }
            for address in ["file:///tmp/audio", "http://user:password@localhost", "https://example.com?key=secret", "http://"] {
                var invalid = config; invalid.baseURL = address
                do {
                    _ = try CallASRClient.endpoint(invalid.baseURL)
                    throw TestFailure.failed("invalid ASR address accepted")
                } catch is CallTranscriptionError { }
            }
            let transcript = String(repeating: "中文🙂e\u{301}，hello\n", count: 900)
            let chunks = CallTranscriptionText.messages(record: recording(), transcript: transcript)
            try expect(chunks.count > 1 && chunks.allSatisfy { $0.utf8.count <= 2048 }, "WeCom byte limit exceeded")
            let recovered = chunks.map { String($0.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)[1]) }.joined()
            try expect(recovered == transcript, "splitting lost, duplicated, or corrupted transcript text")

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CellDock-transcription-tests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("stereo.caf")
            try writeFixture(source)
            let original = try Data(contentsOf: source)
            let parts = try CallTranscriptionAudio.prepare(source: source, directory: root.appendingPathComponent("parts"), remoteOnly: true, maximumDuration: 0.05)
            try expect(parts.count == 2, "long recording was not split at duration limit")
            var totalFrames: Int64 = 0
            for part in parts {
                let file = try AVAudioFile(forReading: part)
                totalFrames += file.length
                try expect(file.processingFormat.channelCount == 1 && file.length <= 400, "ASR audio format or duration wrong")
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 400)!
                try file.read(into: buffer)
                try expect(abs(buffer.floatChannelData![0][0] - 0.5) < 0.01, "automatic-answer audio included local channel")
            }
            try expect(totalFrames == 800, "segmentation lost audio frames")
            let mixedParts = try CallTranscriptionAudio.prepare(source: source, directory: root.appendingPathComponent("mixed"), remoteOnly: false)
            let mixed = try AVAudioFile(forReading: mixedParts[0])
            let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixed.processingFormat, frameCapacity: 1)!
            try mixed.read(into: mixedBuffer, frameCount: 1)
            try expect(abs(mixedBuffer.floatChannelData![0][0] - 0.125) < 0.01, "normal recording lost a speaker during downmix")
            let after = try Data(contentsOf: source)
            try expect(after == original, "ASR preprocessing changed original recording")

            let delivery = Delivery()
            let jobsDir = root.appendingPathComponent("jobs")
            let store = CallTranscriptionStore(directory: jobsDir, recordingsDirectory: root,
                transcribe: { _, _, _ in await delivery.transcribe() },
                send: { _, text in try await delivery.send(text) }, pause: { _ in })
            var disabled = config; disabled.enabled = false
            try store.configure(disabled)
            store.enqueue(recording())
            try expect(store.jobs.isEmpty, "disabled store queued a job")
            try store.configure(config)
            let record = recording()
            store.enqueue(record)
            store.enqueue(record)
            try await waitUntil { store.jobs.first?.phase == .failed }
            try expect(store.jobs.count == 1 && store.jobs[0].sentMessageCount == 1, "duplicate enqueue or lost delivery checkpoint")
            let savedText = store.jobs[0].transcript
            try expect(savedText != nil, "transcript not saved before failed push")
            let initialCount = await delivery.transcriptions
            try expect(initialCount == 1, "duplicate enqueue transcribed twice")
            store.retry(record.id)
            try await waitUntil { store.jobs.first?.phase == .sent }
            let count = await delivery.transcriptions
            try expect(count == 1, "push retry retranscribed audio")
            let sent = await delivery.messages
            try expect(sent == CallTranscriptionText.messages(record: record, transcript: savedText!), "push retry duplicated or skipped messages")
            let restored = CallTranscriptionStore(directory: jobsDir, recordingsDirectory: root)
            try expect(restored.configuration.apiKey == config.apiKey && restored.configuration.webhookURL == config.webhookURL, "credentials were not restored from local configuration")
            try expect(restored.jobs.first?.phase == .sent && restored.jobs.first?.transcript == savedText, "transcript and status did not survive restart")
            let attrs = try FileManager.default.attributesOfItem(atPath: jobsDir.appendingPathComponent("settings.json").path)
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "local credentials file permissions too broad")

            let interruptedDirectory = root.appendingPathComponent("interrupted")
            let interrupted = CallTranscriptionStore(directory: interruptedDirectory, recordingsDirectory: root,
                transcribe: { _, _, _ in "保留转录结果" },
                send: { _, _ in throw TestFailure.failed("disabled task still sent text") },
                pause: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
            try interrupted.configure(config)
            let interruptedRecord = recording()
            interrupted.enqueue(interruptedRecord)
            try await waitUntil { interrupted.jobs.first?.phase == .sending }
            try interrupted.configure(disabled)
            try await waitUntil { interrupted.jobs.first?.phase == .queued }
            try expect(interrupted.jobs.first?.transcript == "保留转录结果", "disabling lost completed transcript")
            let resumed = CallTranscriptionStore(directory: interruptedDirectory, recordingsDirectory: root,
                transcribe: { _, _, _ in throw TestFailure.failed("restart repeated completed ASR") },
                send: { _, _ in }, pause: { _ in })
            try resumed.configure(config)
            try await waitUntil { resumed.jobs.first?.phase == .sent }
            resumed.remove(interruptedRecord.id)
            let removed = CallTranscriptionStore(directory: interruptedDirectory, recordingsDirectory: root)
            try expect(removed.jobs.isEmpty, "deleting recording left transcript or pending job")

            let corrected = CallTranscriptionStore(directory: root.appendingPathComponent("corrected"), recordingsDirectory: root,
                transcribe: { _, _, _ in "更正地址后发送" },
                send: { webhook, _ in
                    if !webhook.contains("corrected-key") { throw WeComWebhook.Failure.rejected(93000) }
                }, pause: { _ in })
            try corrected.configure(config)
            let correctedRecord = recording()
            corrected.enqueue(correctedRecord)
            try await waitUntil { corrected.jobs.first?.phase == .failed }
            var correctedConfig = config
            correctedConfig.webhookURL = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=corrected-key"
            try corrected.configure(correctedConfig)
            corrected.retry(correctedRecord.id)
            try await waitUntil { [.sent, .failed].contains(corrected.jobs.first?.phase) }
            try expect(corrected.jobs.first?.phase == .sent, "corrected webhook was ignored on retry")
            print("All CallTranscriptionSelfTests passed.")
        } catch {
            print("CallTranscriptionSelfTests FAILED: \(error)")
            exit(1)
        }
    }

    static func tryDecodeEmpty() -> Bool {
        (try? CallASRClient.decode(data: Data(#"{"text":""}"#.utf8), status: 200)) == ""
    }

    static func writeFixture(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        buffer.frameLength = 800
        for index in 0..<800 {
            buffer.floatChannelData![0][index] = 0.5
            buffer.floatChannelData![1][index] = -0.25
        }
        try file.write(from: buffer)
    }
}
