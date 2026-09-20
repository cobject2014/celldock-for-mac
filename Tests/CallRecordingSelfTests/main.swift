import AVFoundation
import Foundation

enum CallRecordingSelfTestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CallRecordingSelfTestFailure.failed(message) }
}

let namingDate = Date(timeIntervalSince1970: 1_712_926_896)
let namingTimeZone = TimeZone(secondsFromGMT: 0)!
try expect(
    CallRecordingStore.recordingFileName(
        localNumber: "+86 138 0013 8000",
        remoteNumber: "+10086",
        startedAt: namingDate,
        timeZone: namingTimeZone
    ) == "8613800138000_10086_2024-04-12-130136.m4a",
    "recording file name did not include the local number, remote number, and timestamp"
)
try expect(
    CallRecordingStore.recordingFileName(
        localNumber: nil,
        remoteNumber: "12/34",
        startedAt: namingDate,
        timeZone: namingTimeZone
    ) == "unknown-local-number_12-34_2024-04-12-130136.m4a",
    "recording file name fallback or sanitization was incorrect"
)

let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CellDock-recording-test-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

let outputURL = temporaryDirectory.appendingPathComponent("stereo.m4a")
// Playback must mix both directions without altering the archived stereo file.
let playbackSource = temporaryDirectory.appendingPathComponent("playback-source.caf")
let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2)!
do {
    var fileSettings = playbackFormat.settings
    fileSettings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: playbackSource, settings: fileSettings,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 4)!
    buffer.frameLength = 4
    let channels = buffer.floatChannelData!
    for (index, value) in [Float(0.8), 0, 0.8, -0.8].enumerated() { channels[0][index] = value }
    for (index, value) in [Float(0), 0.6, 0.8, -0.8].enumerated() { channels[1][index] = value }
    try file.write(from: buffer)
}
let originalBytes = try Data(contentsOf: playbackSource)
let mixedURL = temporaryDirectory.appendingPathComponent("playback-mixed.caf")
try CallRecordingPlaybackMix.write(source: playbackSource, destination: mixedURL)
let mixedFile = try AVAudioFile(forReading: mixedURL)
try expect(mixedFile.processingFormat.channelCount == 1, "playback must be centered mono")
let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixedFile.processingFormat, frameCapacity: 4)!
try mixedFile.read(into: mixedBuffer)
try expect(mixedBuffer.frameLength == 4, "playback mix changed duration")
for (index, expected) in [Float(0.4), 0.3, 0.8, -0.8].enumerated() {
    try expect(abs(mixedBuffer.floatChannelData![0][index] - expected) < 0.0001, "playback mix lost a direction or clipped")
}
let preservedBytes = try Data(contentsOf: playbackSource)
try expect(originalBytes == preservedBytes, "playback modified the original recording")
let monoCopyURL = temporaryDirectory.appendingPathComponent("mono-copy.caf")
try CallRecordingPlaybackMix.write(source: mixedURL, destination: monoCopyURL)
let monoCopy = try AVAudioFile(forReading: monoCopyURL)
let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoCopy.processingFormat, frameCapacity: 4)!
try monoCopy.read(into: monoBuffer)
try expect(abs(monoBuffer.floatChannelData![0][0] - 0.4) < 0.0001, "mono playback changed volume")
let automaticRecord = CallRecordingRecord(id: UUID(), callID: nil, number: "test", direction: .incoming,
    startedAt: Date(), endedAt: Date(), duration: 1, fileName: "test.m4a", isIncomplete: false,
    wasAutomaticallyAnswered: true)
let encodedAutomatic = try JSONEncoder().encode(automaticRecord)
let decodedAutomatic = try JSONDecoder().decode(CallRecordingRecord.self, from: encodedAutomatic)
try expect(decodedAutomatic.wasAutomaticallyAnswered == true, "automatic-answer marker was not persisted")
var legacyObject = try JSONSerialization.jsonObject(with: encodedAutomatic) as! [String: Any]
legacyObject.removeValue(forKey: "wasAutomaticallyAnswered")
let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
let legacyRecord = try JSONDecoder().decode(CallRecordingRecord.self, from: legacyData)
try expect(legacyRecord.wasAutomaticallyAnswered != true, "legacy recordings were mislabeled automatic")
let startedAt = Date()
let frameCount = 8_000
let localSamples = (0 ..< frameCount).map { frame -> Int16 in
    let value = sin(Double(frame) * 2 * .pi * 440 / 8_000)
    return Int16(value * 8_000)
}
let remoteSamples = (0 ..< frameCount).map { frame -> Int16 in
    let value = sin(Double(frame) * 2 * .pi * 660 / 8_000)
    return Int16(value * 6_000)
}
let localPCM = localSamples.withUnsafeBytes { Data($0) }
let remotePCM = remoteSamples.withUnsafeBytes { Data($0) }

try CallRecordingCapture.shared.start(
    id: UUID(),
    startedAt: startedAt,
    outputURL: outputURL
)
CallRecordingCapture.shared.appendUplink(localPCM, at: startedAt)
CallRecordingCapture.shared.appendDownlink(remotePCM, at: startedAt)

let semaphore = DispatchSemaphore(value: 0)
var finalResult: Result<CallRecordingCapture.FinalizedCapture, Error>?
CallRecordingCapture.shared.stop { result in
    finalResult = result
    semaphore.signal()
}
guard semaphore.wait(timeout: .now() + 10) == .success else {
    throw CallRecordingSelfTestFailure.failed("recording finalization timed out")
}
let finalized = try finalResult!.get()
try expect(FileManager.default.fileExists(atPath: finalized.outputURL.path), "M4A file was not created")
try expect(abs(finalized.duration - 1) < 0.05, "unexpected recording duration")
try expect(!finalized.isIncomplete, "complete PCM input was marked incomplete")

let audioFile = try AVAudioFile(forReading: finalized.outputURL)
try expect(audioFile.fileFormat.channelCount == 2, "recording was not stereo")
try expect(audioFile.length > 0, "recording contained no readable audio frames")

var waveformResult: Result<CallRecordingWaveformData, Error>?
CallRecordingWaveformLoader.shared.load(url: finalized.outputURL, sampleCount: 240) {
    waveformResult = $0
}
let waveformDeadline = Date().addingTimeInterval(10)
while waveformResult == nil, Date() < waveformDeadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
}
guard let waveformResult else {
    throw CallRecordingSelfTestFailure.failed("waveform extraction timed out")
}
let waveform = try waveformResult.get()
try expect(waveform.remote.count == 240, "remote waveform bin count was incorrect")
try expect(waveform.local.count == 240, "local waveform bin count was incorrect")
try expect(waveform.remote.contains(where: { $0 > 0 }), "remote waveform was empty")
try expect(waveform.local.contains(where: { $0 > 0 }), "local waveform was empty")

print("Call recording self-tests passed (stereo M4A finalization and dual-channel waveform).")
