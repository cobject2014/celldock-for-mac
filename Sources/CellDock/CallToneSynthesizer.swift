import Foundation

enum CallToneCadence {
    case outgoingRingback
    case hangup

    fileprivate var segments: [(duration: TimeInterval, audible: Bool)] {
        switch self {
        case .outgoingRingback:
            // Keep the familiar one-second 450 Hz pulse, but give the local
            // Mac playback a little more breathing room than the nominal
            // four-second PSTN pause. A 5.5-second onset-to-onset interval
            // avoids the first two pulses feeling rushed on desktop speakers.
            return [(1, true), (4.5, false)]
        case .hangup:
            // Two short 450 Hz busy-tone pulses make the end of an established
            // call audible without turning call failures into a long alarm.
            return [(0.35, true), (0.35, false), (0.35, true)]
        }
    }

    var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }
}

enum CallTonePolicy {
    static func wantsOutgoingRingback(for call: CallSnapshot) -> Bool {
        guard call.direction == .outgoing else { return false }
        return call.phase == .dialing || call.phase == .alerting
    }

    static func wantsHangupTone(for completedCall: CallHistoryRecord?) -> Bool {
        completedCall?.wasAnswered == true && completedCall?.endReason != .statusUnknown
    }
}

enum CallToneSynthesizer {
    static let sampleRate = 8_000
    private static let frequency = 450.0
    private static let amplitude = 0.16
    private static let fadeDuration = 0.005

    static func wavData(for cadence: CallToneCadence) -> Data {
        var samples: [Int16] = []
        samples.reserveCapacity(Int(cadence.duration * Double(sampleRate)))

        for segment in cadence.segments {
            let sampleCount = Int((segment.duration * Double(sampleRate)).rounded())
            guard segment.audible else {
                samples.append(contentsOf: repeatElement(0, count: sampleCount))
                continue
            }

            let fadeSamples = max(1, Int(fadeDuration * Double(sampleRate)))
            for index in 0 ..< sampleCount {
                let fadeIn = min(1, Double(index) / Double(fadeSamples))
                let fadeOut = min(1, Double(sampleCount - 1 - index) / Double(fadeSamples))
                let envelope = min(fadeIn, fadeOut)
                let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
                let value = sin(phase) * amplitude * envelope * Double(Int16.max)
                samples.append(Int16(value.rounded()))
            }
        }

        let pcmByteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + pcmByteCount)
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcmByteCount), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data) // Linear PCM
        append(UInt16(1), to: &data) // Mono
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * MemoryLayout<Int16>.size), to: &data)
        append(UInt16(MemoryLayout<Int16>.size), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(pcmByteCount), to: &data)
        for sample in samples {
            append(sample, to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
