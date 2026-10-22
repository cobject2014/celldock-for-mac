import AppKit
import Foundation

@main
struct AppTerminationSelfTests {
    @MainActor
    static func main() async throws {
        try testSecondaryServiceEntryPointsAreGated()
        await testCleanupFailureAndRetry()
        await testDeferredShutdownCancellation()
        await testInFlightShutdownCancellation(clean: true)
        await testInFlightShutdownCancellation(clean: false)
        print("App termination tests passed (failure/retry, deferred recording, clean/failed in-flight shutdown)")
    }

    // AppState cannot be instantiated without live device services here. Verify
    // the gate at both shared entry points, not just the inventory callback.
    static func testSecondaryServiceEntryPointsAreGated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/CellDock/AppState.swift"), encoding: .utf8)
        for signature in [
            "private func reconcileSecondaryModemServices() {",
            "private func installSecondaryModemService(for device: DiscoveredModemDevice) {"
        ] {
            expect(source.contains(signature + "\n        guard !AppTerminationCoordinator.shared.isTerminationPending else { return }"),
                   "Late snapshots must not create or remove secondary services during quit: \(signature)")
        }
    }

    @MainActor
    static func testCleanupFailureAndRetry() async {
        let coordinator = AppTerminationCoordinator(timeout: 0.02)
        expect(coordinator.beginTermination { _ in
            fatalError("No cleanup should need an asynchronous reply")
        } == .terminateNow, "No cleanup should quit immediately")
        var cleanups = 0
        var cancellations = 0
        var confirmations = 0
        var replies: [Bool] = []
        var completeShutdown: ((Bool) -> Void)?
        coordinator.cleanup = { attempt, complete in
            expect(attempt.beginShutdown(), "Fresh teardown must start")
            cleanups += 1
            completeShutdown = complete
        }
        coordinator.onTerminationCancelled = { cancellations += 1 }
        coordinator.onTerminationConfirmed = { confirmations += 1 }
        let failed = await withCheckedContinuation { reply in
            expect(coordinator.beginTermination { result in
                replies.append(result)
                reply.resume(returning: result)
            } == .terminateLater, "Cleanup must defer quitting")
            expect(coordinator.beginTermination { _ in fatalError("Duplicate reply") } == .terminateLater,
                   "Overlapping quit must share the pending cleanup")
            expect(cleanups == 1, "Overlapping quit started another teardown")
            completeShutdown?(false)
            completeShutdown?(true)
        }
        expect(!failed && cancellations == 1 && confirmations == 0 && replies == [false],
               "Cleanup failure must cancel and restore exactly once")
        let succeeded = await withCheckedContinuation { reply in
            _ = coordinator.beginTermination { result in
                replies.append(result)
                reply.resume(returning: result)
            }
            completeShutdown?(true)
            completeShutdown?(false)
        }
        // Let both attempts' scheduled timeouts fire: neither may undo success.
        try? await Task.sleep(nanoseconds: 60_000_000)
        expect(succeeded && cleanups == 2 && cancellations == 1 && confirmations == 1 &&
               replies == [false, true] && !coordinator.isTerminationPending,
               "Stale completion or timeout altered a successful retry")
    }

    @MainActor
    static func testDeferredShutdownCancellation() async {
        let coordinator = AppTerminationCoordinator(timeout: 0.02)
        var deferredShutdown: (() -> Void)?
        var completeShutdown: ((Bool) -> Void)?
        var attempt: AppTerminationAttempt?
        var shutdowns = 0
        var restores = 0
        var confirmations = 0
        coordinator.cleanup = { current, complete in
            attempt = current
            completeShutdown = complete
            // Recording finalization is external; execute its callback explicitly.
            deferredShutdown = {
                guard current.beginShutdown() else { return }
                shutdowns += 1
                complete(true)
            }
        }
        coordinator.onTerminationCancelled = { restores += 1 }
        coordinator.onTerminationConfirmed = { confirmations += 1 }
        let shouldQuit = await withCheckedContinuation { reply in
            _ = coordinator.beginTermination { reply.resume(returning: $0) }
        }
        expect(!shouldQuit && attempt?.isCancelled == true && !coordinator.isTerminationPending && restores == 1,
               "Timeout before teardown must cancel its attempt and allow new calls")
        let abandonedShutdown = deferredShutdown
        let abandonedCompletion = completeShutdown
        abandonedShutdown?()
        abandonedCompletion?(true)
        abandonedCompletion?(false)
        await drainMainQueue()
        expect(shutdowns == 0 && restores == 1 && confirmations == 0,
               "Late recording callback performed teardown after cancellation")

        let nextQuit = await withCheckedContinuation { reply in
            _ = coordinator.beginTermination { reply.resume(returning: $0) }
            abandonedShutdown?()
            abandonedCompletion?(false)
            deferredShutdown?()
            deferredShutdown?()
        }
        expect(nextQuit && shutdowns == 1 && restores == 1 && confirmations == 1,
               "Abandoned callback affected a newer attempt, or teardown ran twice")
    }

    @MainActor
    static func testInFlightShutdownCancellation(clean: Bool) async {
        let coordinator = AppTerminationCoordinator(timeout: 0.02)
        var completeShutdown: ((Bool) -> Void)?
        var currentAttempt: AppTerminationAttempt?
        var replies: [Bool] = []
        var restores = 0
        var confirmations = 0
        var restored: CheckedContinuation<Void, Never>?
        coordinator.cleanup = { attempt, complete in
            expect(attempt.beginShutdown(), "Fresh teardown must start")
            expect(!attempt.beginShutdown(), "Duplicate teardown must be refused")
            currentAttempt = attempt
            completeShutdown = complete
        }
        coordinator.onTerminationCancelled = {
            restores += 1
            restored?.resume()
            restored = nil
        }
        coordinator.onTerminationConfirmed = { confirmations += 1 }
        let shouldQuit = await withCheckedContinuation { reply in
            _ = coordinator.beginTermination { result in
                replies.append(result)
                reply.resume(returning: result)
            }
        }
        expect(!shouldQuit && currentAttempt?.isCancelled == true && coordinator.isTerminationPending,
               "Timeout must cancel quitting but retain the in-flight teardown gate")
        expect(restores == 0 && confirmations == 0, "Services restarted before shutdown completed")
        expect(coordinator.beginTermination { _ in fatalError("Duplicate reply") } == .terminateCancel,
               "A second quit must be refused until in-flight shutdown finishes")
        await withCheckedContinuation { reply in
            restored = reply
            completeShutdown?(clean)
        }
        expect(!coordinator.isTerminationPending && restores == 1 && confirmations == 0 && replies == [false],
               "Finished teardown must restore once without confirming a cancelled quit")
        completeShutdown?(true)
        completeShutdown?(false)
        await drainMainQueue()
        expect(restores == 1 && confirmations == 0 && replies == [false],
               "Duplicate teardown completion repeated restoration or quit reply")
    }

    @MainActor
    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }
}
