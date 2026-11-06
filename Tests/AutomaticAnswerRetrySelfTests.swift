import Foundation

@main
struct AutomaticAnswerRetrySelfTests {
    static func main() {
        var gate = AutomaticAnswerGate()
        let id = UUID()
        precondition(!gate.shouldAnswer(callID: id, eligible: true, now: 0, delay: 3))
        for attempt in 1...3 {
            let time = Double(attempt * 3)
            precondition(gate.shouldAnswer(callID: id, eligible: true, now: time, delay: 3))
            precondition(!gate.shouldAnswer(callID: id, eligible: true, now: time + 0.1, delay: 3))
            gate.complete(callID: id, succeeded: false, now: time)
            precondition(!gate.shouldAnswer(callID: id, eligible: true, now: time + 2.9, delay: 3))
        }
        precondition(!gate.shouldAnswer(callID: id, eligible: true, now: 100, delay: 3))
        let next = UUID()
        precondition(!gate.shouldAnswer(callID: next, eligible: true, now: 101, delay: 3))
        gate.complete(callID: id, succeeded: false, now: 102)
        precondition(gate.shouldAnswer(callID: next, eligible: true, now: 104, delay: 3))
        gate.suppress(callID: next)
        gate.complete(callID: next, succeeded: false, now: 104)
        precondition(!gate.shouldAnswer(callID: next, eligible: true, now: 110, delay: 3))
        let success = UUID()
        _ = gate.shouldAnswer(callID: success, eligible: true, now: 120, delay: 3)
        precondition(gate.shouldAnswer(callID: success, eligible: true, now: 123, delay: 3))
        gate.complete(callID: success, succeeded: true, now: 123)
        precondition(!gate.shouldAnswer(callID: success, eligible: true, now: 150, delay: 3))
        let waiting = UUID()
        _ = gate.shouldAnswer(callID: waiting, eligible: true, now: 200, delay: 3)
        precondition(gate.shouldAnswer(callID: waiting, eligible: true, now: 203, delay: 3))
        gate.complete(callID: waiting, succeeded: false, now: 204)
        precondition(!gate.shouldAnswer(callID: waiting, eligible: false, now: 210, delay: 3), "Must not retry during cleanup or ambiguous call state")
        precondition(!gate.shouldAnswer(callID: waiting, eligible: true, now: 211, delay: 3))
        precondition(gate.shouldAnswer(callID: waiting, eligible: true, now: 214, delay: 3))
        gate.suppress(callID: waiting)
        precondition(!gate.complete(callID: waiting, succeeded: false, now: 215), "Late completion must not revive cancelled retry UI")
        print("Automatic answer retry tests passed")
    }
}
