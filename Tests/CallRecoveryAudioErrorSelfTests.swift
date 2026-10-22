import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Sources/CellDock/ModemService.swift"))
let start = source.range(of: "        voiceAudio.onError =")!.lowerBound
let end = source.range(of: "\n    }\n\n    func start()", range: start..<source.endIndex)!.lowerBound
// Normalize only the callback signature for the pre-fix red run; the production
// queue-hop handler body itself is executed unchanged.
let handler = String(source[start..<end]).replacingOccurrences(of: "[weak self] error in", with: "[weak self] error, session in")
let fixture = """
import Foundation
final class Queue {
    var pending: [() -> Void] = []
    func async(_ action: @escaping () -> Void) { pending.append(action) }
    func drain() { let work = pending; pending = []; work.forEach { $0() } }
}
final class Audio {
    var onError: ((String, UInt64) -> Void)?
    var generation: UInt64 = 1
    func isCurrentSession(_ session: UInt64) -> Bool { session == generation }
}
struct Snapshot { var hasCall = true; var audioActive = true; var lastError: String? }
enum Reason { case failed }
final class Service {
    let queue = Queue()
    let voiceAudio = Audio()
    var callSnapshot = Snapshot()
    var hangups = 0
    var publications = 0
    func publishCallSnapshot() { publications += 1 }
    func terminateAndConfirmCall(reason: Reason) -> Bool { hangups += 1; return true }
    init() {
\(handler)
    }
}
let service = Service()
service.voiceAudio.onError?("old session error", 1)
// Reconnect stops the old audio session before discovering an existing call.
service.voiceAudio.generation = 2
service.queue.drain()
precondition(service.hangups == 0 && service.publications == 0, "Stale audio error must not hang up or overwrite a rediscovered call")
precondition(service.callSnapshot.audioActive && service.callSnapshot.lastError == nil)
service.voiceAudio.onError?("current session error", 2)
service.queue.drain()
precondition(service.hangups == 1 && service.publications == 1, "Current audio failures must retain their normal handling")
print("Call recovery stale audio error tests passed")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("celldock-audio-error-\(UUID().uuidString)")
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
