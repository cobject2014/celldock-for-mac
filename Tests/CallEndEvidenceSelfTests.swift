import Foundation

@main
struct CallEndEvidenceSelfTests {
    static func main() throws {
        let events = CallATParser.parseEvents(inLine: "NO CARRIER")
        guard case let .ended(reason, evidence) = events.first else { fatalError("Missing terminal event") }
        precondition(reason.rawValue == "unknown", "NO CARRIER does not prove the remote user hung up")
        precondition(evidence == .modemResult("NO CARRIER"))
        for (code, expected) in [("BUSY", CallEndReason.busy), ("NO ANSWER", .noAnswer),
                                 ("NO DIALTONE", .noDialTone), ("NO DIAL TONE", .noDialTone)] {
            precondition(CallATParser.parseEvents(inLine: code.lowercased()) == [.ended(expected, evidence: .modemResult(code))])
        }
        var call = CallSnapshot(phase: .idle)
        call.recordEnd(.localHangup, evidence: CallEndEvidence(source: .localAction))
        call.recordEnd(.unknown, evidence: .modemResult("NO CARRIER"))
        call.recordEnd(.unknown, evidence: CallEndEvidence(source: .callListEmpty))
        precondition(call.lastEndReason == .localHangup && call.lastEndEvidence?.source == .localAction)
        call.clearEnd()
        call.recordEnd(.unknown, evidence: CallEndEvidence(source: .callListEmpty))
        call.recordEnd(.unknown, evidence: .modemResult("NO CARRIER"))
        call.recordEnd(.unknown, evidence: CallEndEvidence(source: .callListEmpty))
        precondition(call.lastEndEvidence?.code == "NO CARRIER")
        call.recordEnd(.noAnswer, evidence: .modemResult("NO ANSWER"))
        call.recordEnd(.unknown, evidence: .modemResult("NO CARRIER"))
        precondition(call.lastEndReason == .noAnswer && call.lastEndEvidence?.code == "NO ANSWER")
        call.clearEnd()
        precondition(call.lastEndReason == nil && call.lastEndEvidence == nil)

        let outcomes: [(CallEndReason, CallEndEvidence)] = [
            (.localHangup, CallEndEvidence(source: .localAction)),
            (.unknown, CallEndEvidence(source: .callListEmpty)),
            (.busy, .modemResult("BUSY")),
            (.failed, CallEndEvidence(source: .internalFailure)),
            (.deviceDisconnected, CallEndEvidence(source: .deviceDisconnected)),
            (.statusUnknown, CallEndEvidence(source: .localSessionReset))
        ]
        for (reason, evidence) in outcomes {
            let moduleID = CellularModuleID(rawValue: "test-module")
            var result = CallSnapshot(moduleID: moduleID, phase: .recovering,
                                      direction: .incoming, number: "test", audioActive: true,
                                      muted: true, startedAt: Date(), mediaCleanupPending: true,
                                      recoveryTimedOut: true)
            result.recordEnd(reason, evidence: evidence)
            result.resetForInitialization(phase: .unavailable, voiceOverUSBSupported: false,
                                          lastError: "busy", controlInterfaceBusy: true)
            precondition(result.lastEndReason == reason && result.lastEndEvidence == evidence)
            precondition(result.moduleID == moduleID && result.lastError == "busy" && result.controlInterfaceBusy)
            result.resetForInitialization(phase: .idle, voiceOverUSBSupported: true)
            precondition(result.canDial && !result.recoveryTimedOut && !result.mediaCleanupPending)
            precondition(result.number == nil && result.direction == nil && result.startedAt == nil && !result.audioActive && !result.muted)
            precondition(result.lastEndReason == reason && result.lastEndEvidence == evidence)
            result.clearEnd()
            result.resetForInitialization(phase: .idle, voiceOverUSBSupported: true)
            precondition(result.lastEndReason == nil && result.lastEndEvidence == nil)
        }
        // The fork's unconfirmed local reset is distinct from a confirmed call
        // end whose cause is unknown; generic indications must not erase it.
        call.recordEnd(.statusUnknown, evidence: CallEndEvidence(source: .localSessionReset))
        call.recordEnd(.unknown, evidence: .modemResult("NO CARRIER"))
        precondition(call.lastEndReason == .statusUnknown)
        let legacy = try JSONDecoder().decode(CallEndReason.self, from: Data("\"remoteHangup\"".utf8))
        let localReset = try JSONDecoder().decode(CallEndReason.self, from: Data("\"statusUnknown\"".utf8))
        precondition(legacy == .remoteHangup && localReset == .statusUnknown)
        print("Call end evidence tests passed")
    }
}
