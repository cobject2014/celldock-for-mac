import AppKit
import Foundation

@MainActor
final class AppTerminationAttempt {
    private(set) var isCancelled = false
    private(set) var shutdownStarted = false

    // Check immediately before teardown, including deferred recording callbacks.
    func beginShutdown() -> Bool {
        guard !isCancelled, !shutdownStarted else { return false }
        shutdownStarted = true
        return true
    }

    fileprivate func cancel() { isCancelled = true }
}

@MainActor
final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()

    var cleanup: ((AppTerminationAttempt, @escaping (Bool) -> Void) -> Void)?
    var onTerminationCancelled: (() -> Void)?
    var onTerminationConfirmed: (() -> Void)?
    private let timeout: TimeInterval
    private var activeAttempt: AppTerminationAttempt?

    var isTerminationPending: Bool { activeAttempt != nil }

    init(timeout: TimeInterval = 45) {
        self.timeout = timeout
    }

    func beginTermination(of application: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { application.reply(toApplicationShouldTerminate: $0) }
    }

    func beginTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        if let activeAttempt {
            return activeAttempt.isCancelled ? .terminateCancel : .terminateLater
        }
        guard let cleanup else { return .terminateNow }
        let attempt = AppTerminationAttempt()
        activeAttempt = attempt
        var replied = false
        let replyOnce: (Bool) -> Void = { shouldTerminate in
            guard !replied else { return }
            replied = true
            reply(shouldTerminate)
        }
        let finish: (Bool) -> Void = { clean in
            DispatchQueue.main.async {
                guard self.activeAttempt === attempt else { return }
                if !clean { attempt.cancel() }
                self.activeAttempt = nil
                if attempt.isCancelled {
                    // Every started teardown has completed. Queue device restarts
                    // before admitting more call actions, even after a timeout.
                    self.onTerminationCancelled?()
                    replyOnce(false)
                } else {
                    self.onTerminationConfirmed?()
                    replyOnce(true)
                }
            }
        }
        cleanup(attempt, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard self.activeAttempt === attempt, !replied else { return }
            attempt.cancel()
            if !attempt.shutdownStarted {
                self.activeAttempt = nil
                self.onTerminationCancelled?()
            }
            // Once teardown starts, retain the gate until finish acknowledges
            // quiescence. Cancelling the quit must not reopen call actions yet.
            replyOnce(false)
        }
        return .terminateLater
    }
}
