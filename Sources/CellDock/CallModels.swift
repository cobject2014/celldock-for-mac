import Foundation

struct CallRecoveryDeadline {
    private var startedAt: TimeInterval?

    // Use monotonic time. Repeated failure publications must not extend the deadline.
    mutating func update(phase: CallPhase, now: TimeInterval) -> Bool {
        guard phase == .recovering else {
            startedAt = nil
            return false
        }
        if startedAt == nil { startedAt = now }
        return now - startedAt! >= 30
    }
}

struct AutomaticAnswerGate {
    private var observedID: UUID?
    private var deadline: TimeInterval?
    private var suppressedID: UUID?

    mutating func suppress(callID: UUID?) {
        suppressedID = callID
        deadline = nil
    }

    mutating func shouldAnswer(callID: UUID?, eligible: Bool, now: TimeInterval, delay: Int) -> Bool {
        if observedID != callID {
            observedID = callID
            deadline = nil
        }
        guard let callID, eligible, suppressedID != callID else {
            deadline = nil
            return false
        }
        if deadline == nil { deadline = now + Double(max(1, min(60, delay))) }
        guard now >= deadline! else { return false }
        suppress(callID: callID)
        return true
    }
}

enum CallPhase: String, Equatable {
    case unavailable
    case idle
    case incoming
    case dialing
    case alerting
    case active
    case ending
    case recovering
    case error
}

enum CallDirection: String, Codable, Equatable {
    case outgoing
    case incoming
}

enum CallEndReason: String, Codable, Equatable {
    case localHangup
    // Legacy history remains decodable; generic release codes are not proof
    // that the remote person pressed Hang Up.
    case remoteHangup
    case unknown
    case busy
    case noAnswer
    case noDialTone
    case deviceDisconnected
    case statusUnknown
    case failed

    var localizedDescription: String {
        switch self {
        case .localHangup: return L10n.tr("通话已结束")
        case .remoteHangup: return L10n.tr("对方已挂断")
        case .unknown: return L10n.tr("通话已结束，原因未知")
        case .busy: return L10n.tr("对方忙线")
        case .noAnswer: return L10n.tr("无人接听")
        case .noDialTone: return L10n.tr("网络未提供拨号音")
        case .deviceDisconnected: return L10n.tr("模块已拔出，通话结束")
        case .statusUnknown: return L10n.tr("通话状态未知，本地会话已重置")
        case .failed: return L10n.tr("通话失败")
        }
    }
}

// Adapted from upstream PR #23, b321b7a / adb3619.
struct CallEndEvidence: Codable, Equatable {
    enum Source: String, Codable {
        case localAction
        case modemResultCode
        case callListEmpty
        case deviceDisconnected
        case internalFailure
        case localSessionReset
    }

    let source: Source
    var code: String? = nil

    static func modemResult(_ code: String) -> Self {
        Self(source: .modemResultCode, code: code)
    }
}

struct UACMediaSnapshot: Equatable {
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputTotalSamples: UInt64 = 0
    var inputSignalSamples: UInt64 = 0
    var inputPeakPCM16: UInt32 = 0
    var inputSignalThresholdPCM16: UInt32 = 0
}

struct CallSnapshot: Equatable {
    var moduleID: CellularModuleID?
    var phase: CallPhase = .unavailable
    var direction: CallDirection?
    var number: String?
    var voiceOverUSBSupported = false
    var audioActive = false
    var muted = false
    var startedAt: Date?
    var lastEndReason: CallEndReason?
    var lastEndEvidence: CallEndEvidence?
    var lastError: String?
    var controlInterfaceBusy = false
    var mediaCleanupPending = false
    var uacMedia: UACMediaSnapshot?
    var recoveryTimedOut = false

    var hasCall: Bool {
        switch phase {
        case .incoming, .dialing, .alerting, .active, .ending, .recovering:
            return true
        case .unavailable, .idle, .error:
            return false
        }
    }

    var canDial: Bool {
        phase == .idle && voiceOverUSBSupported && !mediaCleanupPending
    }

    var canSendDTMF: Bool {
        phase == .active
    }

    mutating func recordEnd(_ reason: CallEndReason, evidence: CallEndEvidence) {
        if lastEndEvidence?.source == .localAction, evidence.source != .localAction { return }
        if reason == .unknown {
            if let previous = lastEndReason, previous != .unknown, previous != .failed { return }
            if lastEndEvidence?.source == .modemResultCode, evidence.source == .callListEmpty { return }
        }
        lastEndReason = reason
        lastEndEvidence = evidence
    }

    mutating func resetForInitialization(
        phase: CallPhase,
        voiceOverUSBSupported: Bool,
        lastError: String? = nil,
        controlInterfaceBusy: Bool = false
    ) {
        self = Self(
            moduleID: moduleID,
            phase: phase,
            voiceOverUSBSupported: voiceOverUSBSupported,
            lastEndReason: lastEndReason,
            lastEndEvidence: lastEndEvidence,
            lastError: lastError,
            controlInterfaceBusy: controlInterfaceBusy
        )
    }

    mutating func clearEnd() {
        lastEndReason = nil
        lastEndEvidence = nil
    }
}

enum ModemCallStatus: Int, Equatable {
    case active = 0
    case held = 1
    case dialing = 2
    case alerting = 3
    case incoming = 4
    case waiting = 5
}

struct ModemCallInfo: Equatable {
    let index: Int
    let direction: CallDirection
    let status: ModemCallStatus
    let isVoice: Bool
    let isMultiparty: Bool
    let number: String?
}

enum ModemCallEvent: Equatable {
    case ring
    case callerID(String)
    case callInfo(ModemCallInfo)
    case connected
    case ended(CallEndReason, evidence: CallEndEvidence)
    case pcmFlowReady(Bool)
}
