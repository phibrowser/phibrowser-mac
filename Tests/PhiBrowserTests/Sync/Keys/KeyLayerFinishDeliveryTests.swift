import XCTest
@testable import Phi

/// Guards the run-loop modes `KeyLayerView` delivers its deferred `onFinish()` in.
///
/// Two opposite hazards meet on that one call:
///  * Delivering inside `.eventTracking` closes the hosting window out from under
///    an AppKit mouse-tracking loop (the T17 step 0 hang), so that mode must stay out.
///  * Delivering *only* in `.default` strands the window for the whole life of the
///    profile-pairing gate's `NSApp.runModal(for:)` session, which spins the run loop
///    in `.modalPanel` — and that session is routinely already up by the time `.done`
///    renders, because `resolveMappings()` posts `.phiProfileMappingsDidResolve`
///    before `phase = .done` is assigned. So `.modalPanel` must stay in.
@MainActor
final class KeyLayerFinishDeliveryTests: XCTestCase {
    func testFinishIsDeliveredInModalPanelButNotEventTracking() {
        let modes = KeyLayerView.finishDeliveryModes
        XCTAssertTrue(modes.contains(.default), "`onFinish()` must still arrive on a normal run-loop pass")
        XCTAssertTrue(modes.contains(.modalPanel),
                      "`onFinish()` must arrive during the pairing gate's modal session, "
                      + "or the key-layer window stays on screen until pairing ends")
        XCTAssertFalse(modes.contains(.eventTracking),
                       "`onFinish()` must never run inside an AppKit mouse-tracking loop")
        XCTAssertFalse(modes.contains(.common),
                       "`.common` would pull `.eventTracking` back in")
    }

    /// The property that actually matters, exercised against Foundation rather than
    /// asserted about: a block posted in these modes is delivered by a run loop
    /// spinning the way `NSApp.runModal(for:)` spins it.
    func testBlockPostedInFinishModesRunsWhileRunLoopIsInModalPanel() {
        var ran = false
        RunLoop.main.perform(inModes: KeyLayerView.finishDeliveryModes) { ran = true }

        // `.eventTracking` is not one of the modes, so nothing is delivered there.
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        XCTAssertFalse(ran, "the block must not be delivered while the run loop tracks mouse events")

        // A modal session spins in `.modalPanel`; the block has to land there.
        let deadline = Date().addingTimeInterval(2)
        while !ran, Date() < deadline {
            RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(ran, "the block must be delivered while a modal session owns the run loop")
    }
}
