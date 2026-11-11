import BorisCore
import Foundation
import IOKit.pwr_mgt

/// What holds the Mac awake, so that the rule can be checked without touching the real power settings.
@MainActor
protocol SleepBlocker {
    /// Nil when the system refused.
    func hold(reason: String) -> UInt32?
    func release(_ id: UInt32)
}

/// Prevents only sleep from being idle. Closing the lid still sleeps the Mac.
struct SystemSleepBlocker: SleepBlocker {
    func hold(reason: String) -> UInt32? {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
        return result == kIOReturnSuccess ? assertion : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

/// Keeps the Mac from sleeping on idle while Claude is working, and only then.
@MainActor
final class PowerGuard {
    private let blocker: any SleepBlocker
    private var held: UInt32?
    /// A refusal is tried again at every update, which comes with every scan, and the log says it once.
    private var refusalNoted = false

    var isHolding: Bool { held != nil }

    init(blocker: any SleepBlocker = SystemSleepBlocker()) {
        self.blocker = blocker
    }

    /// A refusal is tried again with the next update.
    func update(shouldHold: Bool) {
        if shouldHold, held == nil {
            held = blocker.hold(reason: "Boris: Claude is working")
            if held != nil {
                AppLog.note(.keepAwakeOn)
                refusalNoted = false
            } else if !refusalNoted {
                AppLog.note(.keepAwakeFailed)
                refusalNoted = true
            }
        } else if !shouldHold {
            refusalNoted = false
            guard let id = held else { return }
            blocker.release(id)
            held = nil
            AppLog.note(.keepAwakeOff)
        }
    }
}
