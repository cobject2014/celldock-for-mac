import AVFoundation
import Foundation

enum CallTranscriptionAudio {
    // Produce bounded mono WAVs for the ASR's 600-second / 25-MiB upload limits.
    // The original stereo recording remains untouched.
    static func prepare(source: URL, directory: URL, remoteOnly: Bool,
                        maximumDuration: Double = 300) throws -> [URL] {
        try Task.checkCancellation()
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw CallTranscriptionError.invalidAudio }
        let rate = input.processingFormat.sampleRate
        guard input.length > 0, rate > 0, maximumDuration > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let target = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192) else {
            throw CallTranscriptionError.invalidAudio
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let framesPerSegment = max(1, min(Int64(min(300, maximumDuration) * rate), Int64(24 * 1024 * 1024 / 2)))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        var urls: [URL] = []
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("segment-\(urls.count).wav")
            let output = try AVAudioFile(forWriting: url, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            var remaining = min(framesPerSegment, input.length - input.framePosition)
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: sourceBuffer, frameCount: AVAudioFrameCount(min(8192, remaining)))
                guard sourceBuffer.frameLength > 0, let channels = sourceBuffer.floatChannelData,
                      let destination = target.floatChannelData else { throw CallTranscriptionError.invalidAudio }
                target.frameLength = sourceBuffer.frameLength
                let channelCount = Int(input.processingFormat.channelCount)
                for frame in 0..<Int(sourceBuffer.frameLength) {
                    if remoteOnly { destination[0][frame] = channels[0][frame] }
                    else {
                        var value: Float = 0
                        for channel in 0..<channelCount { value += channels[channel][frame] / Float(channelCount) }
                        destination[0][frame] = value
                    }
                }
                try output.write(from: target)
                remaining -= Int64(sourceBuffer.frameLength)
            }
            urls.append(url)
        }
        return urls
    }
}
