import BorisCore
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from sleeping on idle while a run is active. Closing the lid still sleeps it.
@MainActor
final class PowerGuard {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHolding = false

    func update(shouldHold: Bool) {
        if shouldHold, !isHolding {
            let reason = "Boris: a Claude Code workflow is running" as CFString
            isHolding = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
            AppLog.note(isHolding ? .keepAwakeOn : .keepAwakeFailed)
        } else if !shouldHold, isHolding {
            IOPMAssertionRelease(assertion)
            isHolding = false
            AppLog.note(.keepAwakeOff)
        }
    }
}
