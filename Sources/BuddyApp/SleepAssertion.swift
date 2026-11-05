import IOKit.pwr_mgt

/// One power assertion that stops idle system sleep while a session works.
@MainActor
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    func set(_ hold: Bool) {
        guard hold != held else { return }
        if hold {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Buddy: a Claude Code session is working" as CFString, &id)
            guard r == kIOReturnSuccess else { log.error("Sleep assertion not created: \(r, privacy: .public)"); return }
        } else if IOPMAssertionRelease(id) != kIOReturnSuccess {
            log.error("Sleep assertion not released")
        }
        held = hold
    }
}
