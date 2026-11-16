// Display-sleep assertion adapted from VoiceInk; see NOTICE.md.
import Foundation
import IOKit.pwr_mgt
import os

@MainActor
protocol RecordingSleepPreventing {
    func start()
    func stop()
}

@MainActor
final class ScreenSleepPreventer: RecordingSleepPreventing {
    private let logger = Logger(subsystem: "xyz.karzaev.ummh", category: "power")
    private var assertionID: IOPMAssertionID = 0

    func start() {
        guard assertionID == 0 else { return }
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "ummh recording" as CFString, &assertionID)
        if status != kIOReturnSuccess {
            assertionID = 0
            logger.error("Could not prevent display sleep: \(status)")
        }
    }

    func stop() {
        guard assertionID != 0 else { return }
        let releasingID = assertionID
        assertionID = 0
        let status = IOPMAssertionRelease(releasingID)
        if status != kIOReturnSuccess { logger.error("Could not release display sleep assertion: \(status)") }
    }
}
