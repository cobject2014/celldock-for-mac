import AVFoundation
import Foundation

enum CallWelcomeAudio {
    static func decode(wav: Data) throws -> Data {
        guard wav.count > 44, wav.count <= 32 * 1024 * 1024,
              wav.prefix(4) == Data("RIFF".utf8), wav[8..<12] == Data("WAVE".utf8) else {
            throw CallWelcomeError.invalidAudio
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CellDock-TTS-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try wav.write(to: url, options: [.atomic])
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.channelCount == 1, format.sampleRate == 24_000,
                  file.length > 0, file.length <= 24_000 * 300,
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096),
                  let converter = AVAudioConverter(from: format, to: target) else { throw CallWelcomeError.invalidAudio }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            var result = Data()
            var retainedInput: AVAudioPCMBuffer?
            while true {
                try Task.checkCancellation()
                var error: NSError?
                var readFailed = false
                let status = converter.convert(to: output, error: &error) { requested, state in
                    guard file.framePosition < file.length else { state.pointee = .endOfStream; return nil }
                    guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested) else {
                        readFailed = true; state.pointee = .endOfStream; return nil
                    }
                    do { try file.read(into: input, frameCount: requested) }
                    catch { readFailed = true; state.pointee = .endOfStream; return nil }
                    retainedInput = input
                    state.pointee = .haveData
                    return retainedInput
                }
                guard status != .error, error == nil, !readFailed else { throw CallWelcomeError.invalidAudio }
                if let samples = output.int16ChannelData?[0], output.frameLength > 0 {
                    result.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
                }
                guard result.count <= 8000 * 2 * 300 + 128 else { throw CallWelcomeError.invalidAudio }
                if status == .endOfStream { break }
                guard output.frameLength > 0 else { throw CallWelcomeError.invalidAudio }
            }
            guard !result.isEmpty else { throw CallWelcomeError.invalidAudio }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw CallWelcomeError.invalidAudio }
    }

    static func wav(pcm: Data, sampleRate: UInt32 = 8000) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
