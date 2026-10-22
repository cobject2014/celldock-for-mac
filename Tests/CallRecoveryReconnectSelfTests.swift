import Foundation

// Run the production reconnect operation against local audio/USB boundaries.
// No real modem, user data, audio device, or hangup command is used.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Sources/CellDock/ModemService.swift"))
let start = source.range(of: "    func reconnectAfterCallRecoveryTimeout(")!.lowerBound
let end = source.range(of: "    func hangUp(", range: start..<source.endIndex)!.lowerBound
let operation = String(source[start..<end])
let identityStart = source.range(of: "    private func recordConnectedModemIdentity(")!.lowerBound
let identityEnd = source.range(of: "    @discardableResult\n    private func stopVoiceAudioAndWait", range: identityStart..<source.endIndex)!.lowerBound
let identityMethods = String(source[identityStart..<identityEnd]).replacingOccurrences(of: "private func", with: "func")
let fixture = """
import Foundation
enum ModemActionResult { case success(String? = nil), failure(String) }
enum L10n { static func tr(_ value: String) -> String { value } }
enum CallPhase { case active, recovering, unavailable }
enum CallEndReason { case statusUnknown }
struct CallSnapshot {
    var phase: CallPhase = .recovering
    var recoveryTimedOut = true
}
struct ModemSnapshot { enum State { case disconnected }; var state: State }
final class SerialQueue { func async(_ work: () -> Void) { work() } }
final class Audio {
    var hasUnresolvedUACCleanup = false
    var enabled = true
    func setMediaEnabled(_ enabled: Bool) { self.enabled = enabled }
}
var closedHandles: [Int] = []
var discoveredRegistryID: UInt64 = 100
var discoveredLocationID: UInt32 = 42
func celldock_modem_close(_ handle: Int) { closedHandles.append(handle) }
func celldock_modem_registry_id(_ handle: Int) -> UInt64 { discoveredRegistryID }
func celldock_modem_location_id(_ handle: Int) -> UInt32 { discoveredLocationID }
final class Service {
    let queue = SerialQueue()
    var callSnapshot = CallSnapshot()
    var callActionInFlight = false
    var euiccOperationInFlight = false
    var modem: Int? = 1
    var modemLocationID: UInt32 = 42
    var modemRegistryID: UInt64 = 100
    var modemGeneration: UInt64 = 7
    var reconnectLocationID: UInt32?
    var snapshot = ModemSnapshot(state: .disconnected)
    let voiceAudio = Audio()
    var audioStopped = true
    var operations: [String] = []
    func cancelQDCInitializationRetry() { operations.append("cancelInit") }
    func cancelPendingQDCMediaSession() { operations.append("cancelMedia") }
    func invalidateCallAction() { operations.append("invalidate") }
    func stopVoiceAudioAndWait() -> Bool { operations.append("stopAudio"); return audioStopped }
    func resetSMSConnectionState() { operations.append("resetSMS") }
    func resetCallConnectionState(disconnected: Bool, endReason: CallEndReason) {
        precondition(!disconnected && endReason == .statusUnknown)
        operations.append("resetLocal")
        callSnapshot.phase = .unavailable
    }
    func publishSnapshot(_ snapshot: ModemSnapshot) { operations.append("publish") }
    func tick() {
        precondition(modemRegistryID == 0 && modemGeneration == 8, "Old USB ownership must be invalidated")
        precondition(reconnectLocationID == 42, "Reconnection must remain pinned to the original port")
        precondition(!voiceAudio.enabled && callSnapshot.phase == .unavailable)
        operations.append("detect")
    }
\(operation)
\(identityMethods)
}
let identity = Service()
precondition(identity.connectedModemMatchesExpectedIdentity())
discoveredRegistryID = 101
precondition(!identity.connectedModemMatchesExpectedIdentity(), "USB re-enumeration must not silently inherit an old call")
discoveredRegistryID = 100
discoveredLocationID = 43
precondition(!identity.connectedModemMatchesExpectedIdentity(), "Another port must not receive old call operations")
discoveredRegistryID = 101
discoveredLocationID = 42
identity.modemRegistryID = 0
precondition(identity.recordConnectedModemIdentity())
precondition(identity.connectedModemMatchesExpectedIdentity(), "Explicit fresh discovery must adopt the new USB instance")
let service = Service()
service.reconnectAfterCallRecoveryTimeout { _ in }
precondition(service.operations == ["cancelInit", "cancelMedia", "invalidate", "stopAudio", "resetSMS", "resetLocal", "publish", "detect"])
precondition(closedHandles == [1])
for scenario in 0..<6 {
    closedHandles = []
    let rejected = Service()
    switch scenario {
    case 0: rejected.callSnapshot.phase = .active
    case 1: rejected.callSnapshot.recoveryTimedOut = false
    case 2: rejected.callActionInFlight = true
    case 3: rejected.euiccOperationInFlight = true
    case 4: rejected.modemLocationID = 0
    default: rejected.modem = nil
    }
    rejected.reconnectAfterCallRecoveryTimeout { _ in }
    precondition(rejected.operations.isEmpty && closedHandles.isEmpty, "Unsafe reconnect must have no side effects")
}
for unresolved in [false, true] {
    closedHandles = []
    let blocked = Service()
    blocked.audioStopped = unresolved
    blocked.voiceAudio.hasUnresolvedUACCleanup = unresolved
    blocked.reconnectAfterCallRecoveryTimeout { _ in }
    precondition(!blocked.operations.contains("resetLocal") && !blocked.operations.contains("detect"))
    precondition(closedHandles.isEmpty && blocked.modemRegistryID == 100)
}
print("Call recovery reconnect safety tests passed")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("celldock-reconnect-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let test = directory.appendingPathComponent("main.swift")
try fixture.write(to: test, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", test.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
