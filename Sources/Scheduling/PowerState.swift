import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics
import Support

public enum PowerState {
    /// True when on AC power (a run is allowed).
    public static var isOnAC: Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }   // desktops report nothing
        if let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String? { return type == kIOPSACPowerValue }
        return true
    }

    /// Seconds since the last keyboard/mouse event.
    public static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }

    /// Holds off *idle* sleep while a run is active. Does not hold a closed lid (needs the helper).
    public final class Assertion: @unchecked Sendable {
        private var id: IOPMAssertionID = 0
        public init?(reason: String) {
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            if rc != kIOReturnSuccess { return nil }
        }
        deinit { IOPMAssertionRelease(id) }
    }
}
