import Foundation

/// Owned by the modem queue. Receipts are valid only for the current connection.
/// One verified slot per tick bounds interference with calls and incoming URCs.
final class SMSArchiveCleanup {
    enum Inspection { case exact, gone, unknown }

    private(set) var generation = UUID()
    private var pending: [ModemPDUReference: Date] = [:]

    func reset() {
        generation = UUID()
        pending.removeAll()
    }

    func enqueue(_ references: [ModemPDUReference], generation: UUID) {
        guard generation == self.generation else { return }
        for reference in references where pending.count < 1024 {
            guard reference.index >= 0,
                  ["ME", "SM", "MT"].contains(reference.storage),
                  !reference.rawPDU.isEmpty else { continue }
            // Repeated CMGL results must not reset a failed attempt's backoff.
            if pending[reference] == nil { pending[reference] = .distantPast }
        }
    }

    func processOne(
        now: Date = Date(),
        inspect: (ModemPDUReference) -> Inspection,
        delete: (ModemPDUReference) -> Void
    ) {
        let ready = pending.filter { $0.value <= now }.map(\.key)
        guard let target = SMSDeletionPlanner.orderedTargets(from: ready).first else { return }
        let session = generation
        // A lost CMGD response is not permission to blindly retry. Always CMGR
        // again, with a cooldown even if the next poll reports the same entry.
        pending[target] = now.addingTimeInterval(30)
        let state = inspect(target)
        guard session == generation else { return }
        switch state {
        case .gone: pending.removeValue(forKey: target)
        case .unknown: break
        case .exact: delete(target)
        }
    }
}
