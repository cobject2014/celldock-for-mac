import Foundation

enum TestFailure: Error { case failed(String) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

// A documented 24 kHz PCM16 mono response, with a 1 kHz signal.
func fixtureWAV() -> Data {
    var pcm = Data()
    for frame in 0..<24_000 {
        var sample = Int16(sin(Double(frame) * 2 * .pi / 24) * 12_000).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    return CallWelcomeAudio.wav(pcm: pcm, sampleRate: 24_000)
}

@main struct CallWelcomeSelfTests {
    @MainActor static func main() async {
        do {
            var config = CallWelcomeConfiguration()
            config.enabled = true
            config.text = "您好，请在提示后留言。"
            config.apiKey = "tts-test-key"
            let request = try CallTTSClient.request(configuration: config)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try expect(request.url?.absoluteString == "http://DELLXPS.local:9101/v1/audio/speech", "wrong TTS endpoint")
            try expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "X-API-Key") == "tts-test-key", "missing TTS authentication")
            try expect(body["input"] as? String == config.text && body["response_format"] as? String == "wav", "wrong TTS synthesis request")
            try expect(body["stream"] as? Bool == false, "cached synthesis unexpectedly streams")
            try expect(!String(decoding: request.httpBody!, as: UTF8.self).contains("tts-test-key"), "key leaked into payload")
            for invalid in ["", " \n", String(repeating: "字", count: 5001)] {
                var changed = config; changed.text = invalid
                do { _ = try CallTTSClient.request(configuration: changed); throw TestFailure.failed("invalid welcome text accepted") }
                catch CallWelcomeError.invalidConfiguration { }
            }
            var changed = config; changed.baseURL = "http://user:password@example.test?key=secret"
            do { _ = try CallTTSClient.request(configuration: changed); throw TestFailure.failed("credential URL accepted") }
            catch CallWelcomeError.invalidConfiguration { }
            let pcm = try CallWelcomeAudio.decode(wav: fixtureWAV())
            try expect(abs(pcm.count - 16_000) <= 16, "24 kHz to 8 kHz conversion changed duration: \(pcm.count) bytes")
            try expect(pcm.contains(where: { $0 != 0 }), "converted welcome is silent")
            do { _ = try CallWelcomeAudio.decode(wav: Data("bad WAV".utf8)); throw TestFailure.failed("invalid audio accepted") }
            catch CallWelcomeError.invalidAudio { }

            // Pacing must not send the whole greeting at once or drop frames on backpressure.
            var playback = CallWelcomePlayback()
            playback.start(pcm)
            let first = playback.peek(maximumFrames: 160, now: 10)
            try expect(first == pcm.prefix(320), "greeting prefix truncated")
            playback.consume(frames: 80)
            try expect(playback.peek(maximumFrames: 160, now: 10) == pcm.subdata(in: 160..<320), "partial USB acceptance dropped audio")
            playback.consume(frames: 80)
            try expect(playback.peek(maximumFrames: 160, now: 10).isEmpty, "greeting sent faster than real time")
            var delivered = first
            for tick in 1...60 {
                let chunk = playback.peek(maximumFrames: 160, now: 10 + Double(tick) * 0.0201)
                delivered.append(chunk)
                playback.consume(frames: chunk.count / 2)
            }
            try expect(delivered == pcm && !playback.isPlaying, "greeting lost, duplicated, or reordered samples")
            playback.start(pcm); playback.cancel()
            try expect(playback.peek(maximumFrames: 800, now: 20).isEmpty, "hangup left greeting queued")

            var trigger = CallWelcomeTrigger()
            trigger.arm(pcm: pcm, automatic: true)
            try expect(trigger.take(hasCall: true, active: false, audioReady: true) == nil, "greeting played before answer")
            try expect(trigger.take(hasCall: true, active: true, audioReady: false) == nil, "greeting played before media ready")
            try expect(trigger.take(hasCall: true, active: true, audioReady: true) == pcm, "active automatic answer did not play")
            try expect(trigger.take(hasCall: true, active: true, audioReady: true) == nil, "repeated snapshot replayed greeting")
            trigger.arm(pcm: pcm, automatic: false)
            try expect(trigger.take(hasCall: true, active: true, audioReady: true) == nil, "manual answer played greeting")
            trigger.arm(pcm: pcm, automatic: true)
            _ = trigger.take(hasCall: false, active: false, audioReady: false)
            try expect(trigger.take(hasCall: true, active: true, audioReady: true) == nil, "ended call leaked greeting to next call")

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CellDock-Welcome-Test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            var syntheses = 0
            let store = CallWelcomeStore(directory: root, synthesize: { value in
                try expect(value.text == config.text, "wrong text used in synthesis")
                syntheses += 1
                return pcm
            })
            try await store.save(config)
            try expect(store.audioForCall == pcm, "saved greeting not available for calls")
            let reload = CallWelcomeStore(directory: root)
            try expect(reload.audioForCall == pcm, "cache did not survive relaunch")
            try reload.setEnabled(false)
            try expect(reload.audioForCall == nil, "disabled greeting still plays")
            try reload.setEnabled(true)
            try expect(reload.audioForCall == pcm, "reenabling lost cached greeting")
            try await store.save(config)
            try expect(syntheses == 1, "unchanged config unnecessarily called TTS")
            let failing = CallWelcomeStore(directory: root, synthesize: { _ in throw CallWelcomeError.http(503) })
            changed = config; changed.text = "新的欢迎语"
            do { try await failing.save(changed); throw TestFailure.failed("TTS failure reported success") }
            catch CallWelcomeError.http(503) { }
            try expect(failing.configuration.text == config.text && failing.audioForCall == pcm, "failed synthesis replaced working greeting")
            let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("welcome.json").path)[.posixPermissions] as? NSNumber
            try expect(permissions?.intValue == 0o600, "credential file is not private")

            let cancelledStore = CallWelcomeStore(directory: root, synthesize: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return pcm
            })
            let cancelSave = Task { try await cancelledStore.save(changed) }
            await Task.yield()
            cancelSave.cancel()
            do { try await cancelSave.value; throw TestFailure.failed("cancelled generation saved new text") }
            catch is CancellationError { }
            try expect(!cancelledStore.isGenerating && cancelledStore.configuration.text == config.text,
                       "cancelled generation changed saved settings or left controls disabled")
            try expect(CallWelcomeStore(directory: root).audioForCall == pcm, "cancelled generation corrupted persistent audio")

            guard let baseURL = ProcessInfo.processInfo.environment["WELCOME_TTS_TEST_URL"] else {
                throw TestFailure.failed("HTTP fixture missing")
            }
            var networkConfig = config; networkConfig.baseURL = baseURL
            let synthesized = try await CallTTSClient.synthesize(configuration: networkConfig)
            try expect(synthesized.count == 16_000, "HTTP WAV response did not produce one second of telephone audio")
            networkConfig.apiKey = "wrong-key"
            do { _ = try await CallTTSClient.synthesize(configuration: networkConfig); throw TestFailure.failed("TTS authentication failure accepted") }
            catch CallWelcomeError.http(401) { }
            networkConfig.apiKey = "tts-test-key"; networkConfig.text = "bad-audio"
            do { _ = try await CallTTSClient.synthesize(configuration: networkConfig); throw TestFailure.failed("TTS JSON error accepted as WAV") }
            catch CallWelcomeError.invalidAudio { }
            networkConfig.text = "redirect"
            do { _ = try await CallTTSClient.synthesize(configuration: networkConfig); throw TestFailure.failed("TTS redirect followed with credentials") }
            catch CallWelcomeError.http(302) { }
            networkConfig.text = "slow"
            let networkTask = Task { try await CallTTSClient.synthesize(configuration: networkConfig) }
            try await Task.sleep(nanoseconds: 50_000_000)
            networkTask.cancel()
            do { _ = try await networkTask.value; throw TestFailure.failed("cancelled TTS request succeeded") }
            catch is CancellationError { }
            try expect(!CallWelcomeError.message(for: URLError(.timedOut)).contains("http"), "raw network details leaked")
            print("Call welcome self-tests passed")
        } catch {
            fputs("Call welcome self-tests failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
