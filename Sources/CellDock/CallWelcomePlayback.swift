import Foundation

/// Owned by ModemService's serial queue. Consume only once after call AND media readiness.
struct CallWelcomeTrigger {
    private var pending: Data?

    mutating func arm(pcm: Data?, automatic: Bool) {
        pending = automatic ? pcm : nil
    }

    mutating func take(hasCall: Bool, active: Bool, audioReady: Bool) -> Data? {
        guard hasCall else { pending = nil; return nil }
        guard active, audioReady else { return nil }
        defer { pending = nil }
        return pending
    }
}

/// PCM16 mono at 8 kHz. The owner serializes access and commits only accepted frames.
/// Separate from the microphone's short rolling buffer so long greetings aren't trimmed.
struct CallWelcomePlayback {
    private var pcm = Data()
    private var position = 0
    private var startedAt: Double?
    var isPlaying: Bool { position < pcm.count }

    mutating func start(_ data: Data) {
        pcm = data; position = 0; startedAt = nil
    }

    mutating func cancel() {
        pcm = Data(); position = 0; startedAt = nil
    }

    mutating func peek(maximumFrames: Int, now: Double) -> Data {
        guard isPlaying, maximumFrames > 0 else { return Data() }
        if startedAt == nil { startedAt = now }
        let elapsed = max(0, min(600, now - startedAt!))
        let budget = Int(elapsed * 8000) + maximumFrames - position / 2
        let frames = max(0, min(maximumFrames, budget, (pcm.count - position) / 2))
        return pcm.subdata(in: position..<(position + frames * 2))
    }

    mutating func consume(frames: Int) {
        position += min(max(0, frames) * 2, pcm.count - position)
        if position == pcm.count { cancel() }
    }
}
