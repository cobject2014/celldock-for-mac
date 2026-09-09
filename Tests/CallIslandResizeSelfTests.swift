import Foundation

// Execute the production resize method with a window boundary that deliberately
// reenters before committing its frame, as AppKit did in the crash report.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Sources/CellDock/IncomingCallWindowController.swift"))
let start = source.range(of: "    private func updatePanelSize(")!.lowerBound
let end = source.range(of: "    private func restoreOrPosition", range: start..<source.endIndex)!.lowerBound
var method = String(source[start..<end])
method = method.replacingOccurrences(of: "private func updatePanelSize(animated: Bool)", with: "func updatePanelSize()")
method = method.replacingOccurrences(of: "private func updatePanelSize()", with: "func updatePanelSize()")
let fixture = """
import AppKit
let animated = true
final class State { var call = Call() }
struct Call { var phase = 0 }
struct Presentation { var isExpanded = false }
enum CallIslandView {
    static func contentSize(for phase: Int, isExpanded: Bool) -> NSSize {
        NSSize(width: 300, height: 100)
    }
}
final class Panel {
    var frame = NSRect(x: 400, y: 400, width: 400, height: 200)
    var depth = 0
    var maximumDepth = 0
    var calls = 0
    var usedAnimation = false
    var reenter: (() -> Void)?
    func setFrame(_ target: NSRect, display: Bool, animate: Bool) {
        depth += 1
        maximumDepth = max(maximumDepth, depth)
        calls += 1
        usedAnimation = usedAnimation || animate
        if calls == 1 { reenter?() }
        frame = target
        depth -= 1
    }
}
final class Controller {
    var appState: State? = State()
    var panel: Panel? = Panel()
    var presentation = Presentation()
    var isAdjustingFrame = false
    func constrainedFrame(_ frame: NSRect) -> NSRect { frame }
\(method)
}
let controller = Controller()
let panel = controller.panel!
panel.reenter = { controller.updatePanelSize() }
controller.updatePanelSize()
guard panel.maximumDepth == 1 else {
    print("FAIL: window resize reentered (depth \\(panel.maximumDepth))")
    exit(1)
}
guard !panel.usedAnimation else {
    print("FAIL: synchronous AppKit resize animation may pump a nested run loop")
    exit(1)
}
guard panel.frame == NSRect(x: 500, y: 500, width: 300, height: 100),
      !controller.isAdjustingFrame else {
    print("FAIL: target frame or resize guard was not restored")
    exit(1)
}
controller.updatePanelSize()
guard panel.calls == 1 else { print("FAIL: unchanged size resized again"); exit(1) }
print("Call island resize regression tests passed")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("celldock-resize-\(UUID().uuidString)")
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
