import Foundation

@main
struct CallRecoverySelfTests {
    @MainActor static func main() {
        var recovery = CallRecoveryDeadline()
        precondition(!recovery.update(phase: .recovering, now: 100))
        for second in 101..<130 {
            precondition(!recovery.update(phase: .recovering, now: Double(second)))
        }
        precondition(recovery.update(phase: .recovering, now: 130), "Repeated failures must not extend recovery forever")
        precondition(recovery.update(phase: .recovering, now: 300))
        let unknown = CallSnapshot(phase: .recovering, recoveryTimedOut: true)
        precondition(unknown.hasCall && !unknown.canDial, "Timeout is not proof of hangup")
        precondition(!recovery.update(phase: .active, now: 301))
        precondition(!recovery.update(phase: .recovering, now: 400))
        precondition(!recovery.update(phase: .recovering, now: 429))
        precondition(recovery.update(phase: .recovering, now: 430))
        precondition(!recovery.update(phase: .unavailable, now: 431))
        precondition(!recovery.update(phase: .recovering, now: 500))
        precondition(recovery.update(phase: .recovering, now: 530))
        let now = Date()
        for answered in [false, true] {
            let unknownRecord = CallHistoryRecord(
                id: UUID(), direction: .incoming, number: "test", startedAt: now,
                connectedAt: answered ? now : nil, endedAt: now,
                endReason: .statusUnknown
            )
            precondition(!unknownRecord.isMissed, "Unknown state must not announce a missed call")
            precondition(!CallTonePolicy.wantsHangupTone(for: unknownRecord), "Unknown state must not announce a hangup")
        }
        print("Call recovery deadline tests passed")
    }
}
