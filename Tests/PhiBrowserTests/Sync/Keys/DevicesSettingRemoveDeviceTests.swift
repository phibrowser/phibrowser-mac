import XCTest
@testable import Phi

/// Task 18: the Settings → Devices runtime entry point for "remove this device
/// from sync".
///
/// The state machine is exercised without a `SyncKeyController`: that type is a
/// concrete `@MainActor final class` with no protocol, so it cannot be faked,
/// and `SelfRevokeTests` (which builds a real one out of `FakeAPI` and friends)
/// already covers the teardown itself. What is new here is only the pane's
/// state machine, so the model takes the removal as an injectable closure —
/// production hands it `syncKeyController.removeThisDeviceFromSync()` on the
/// coordinator-owned shared instance, the only one carrying `retirePhiSync` /
/// `deviceKeyRotator` / `engineDefaults` / `spaceStateStore`.
@MainActor
final class DevicesSettingRemoveDeviceTests: XCTestCase {

    /// Reference box so an escaping removal closure can count its own calls.
    private final class Counter { var calls = 0 }

    /// Holds a removal suspended in flight, so a second click can be attempted
    /// while the first one has not returned yet.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if opened { c.resume() } else { continuation = c }
            }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Spins the main actor until the model reaches `state`, so a second click
    /// can land while the first removal is genuinely suspended.
    private func spin(_ model: DevicesRemoveDeviceModel,
                      until state: DevicesRemoveDeviceModel.State) async {
        var spins = 0
        while model.state != state && spins < 200 {
            await Task.yield()
            spins += 1
        }
    }

    /// The button is the exact complement of the pane's "Set up sync on this
    /// device" arm: `DevicesSettingViewModel.unlockState == .unlocked`.
    func testRemoveButtonOnlyWhenJoinedAndUnlocked() {
        let model = DevicesRemoveDeviceModel(remove: {})
        XCTAssertFalse(model.isVisible(unlockState: .loading))
        XCTAssertFalse(model.isVisible(unlockState: .needsJoin))
        XCTAssertFalse(model.isVisible(unlockState: .notSignedIn))
        XCTAssertFalse(model.isVisible(unlockState: .failed("boom")))
        XCTAssertTrue(model.isVisible(unlockState: .unlocked))
    }

    func testRemoveSucceedsAndReturnsPaneToNotJoined() async {
        let removals = Counter()
        let reloads = Counter()
        let model = DevicesRemoveDeviceModel(remove: { removals.calls += 1 },
                                             onRemoved: { reloads.calls += 1 })
        await model.requestRemoval(confirm: { true })

        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(removals.calls, 1)
        XCTAssertEqual(reloads.calls, 1,
                       "the pane must re-run loadAll() so unlockState re-derives to .needsJoin")
        XCTAssertFalse(model.isVisible(unlockState: .unlocked),
                       "the button goes away the moment the removal lands, not only after the reload")
        XCTAssertFalse(model.canRequestRemoval)
        XCTAssertNil(model.note)
    }

    func testLastDeviceDisablesButtonWithNote() async {
        let removals = Counter()
        let model = DevicesRemoveDeviceModel(remove: {
            removals.calls += 1
            throw KeyAPIError.lastActiveDevice
        })
        await model.requestRemoval(confirm: { true })

        XCTAssertEqual(model.state, .lastDevice)
        XCTAssertEqual(removals.calls, 1)
        XCTAssertFalse(model.canRequestRemoval, "greyed in place: nothing here adds a second device")
        XCTAssertEqual(model.note, SelfRevokeStrings.lastDeviceNote)

        await model.requestRemoval(confirm: { XCTFail("a blocked button must not re-ask"); return true })
        XCTAssertEqual(removals.calls, 1)
    }

    func testSecondClickWhileRemovingIsIgnored() async {
        let removals = Counter()
        let gate = Gate()
        let model = DevicesRemoveDeviceModel(remove: {
            removals.calls += 1
            await gate.wait()
        })

        Task { await model.requestRemoval(confirm: { true }) }
        await spin(model, until: .removing)
        XCTAssertEqual(model.state, .removing)

        await model.requestRemoval(confirm: { XCTFail("a removal is already in flight"); return true })
        XCTAssertEqual(removals.calls, 1)
        XCTAssertEqual(model.state, .removing)

        gate.open()
        await spin(model, until: .done)
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(removals.calls, 1)
    }

    func testOtherFailureKeepsButtonEnabled() async {
        let removals = Counter()
        let model = DevicesRemoveDeviceModel(remove: {
            removals.calls += 1
            throw KeyAPIError.http(503, "{\"envelope\":\"secret-body\"}")
        })
        await model.requestRemoval(confirm: { true })

        guard case .failed(let message) = model.state else {
            return XCTFail("expected .failed, got \(model.state)")
        }
        XCTAssertEqual(message, "KeyAPIError.http(503)")
        XCTAssertFalse(message.contains("secret-body"), "R12: metadata only, never the response body")
        XCTAssertEqual(model.note, message)
        XCTAssertTrue(model.canRequestRemoval, "a transient failure is retried, not blocked")
        XCTAssertTrue(model.isVisible(unlockState: .unlocked))

        await model.requestRemoval(confirm: { true })
        XCTAssertEqual(removals.calls, 2)
    }

    /// The production closure throws when the coordinator-owned controller has
    /// gone (a sign-out in another window between the button rendering and the
    /// click). A teardown that never reached the server must not read as one
    /// that did: the model lands in `.failed`, not `.done`.
    func testMissingSharedControllerFailsInsteadOfReportingSuccess() async {
        let reloads = Counter()
        let model = DevicesRemoveDeviceModel(remove: {
            throw DevicesRemoveDeviceError.syncControllerUnavailable
        }, onRemoved: { reloads.calls += 1 })
        await model.requestRemoval(confirm: { true })

        guard case .failed(let message) = model.state else {
            return XCTFail("expected .failed, got \(model.state)")
        }
        XCTAssertEqual(message, SelfRevokeStrings.removalUnavailable)
        XCTAssertEqual(reloads.calls, 0, "nothing was revoked, so the pane must not run its success reload")
        XCTAssertTrue(model.canRequestRemoval, "the button stays live so the user can retry")
        XCTAssertTrue(model.isVisible(unlockState: .unlocked))
        XCTAssertTrue(model.noteIsError)
    }

    /// The note under the button carries two different kinds of string; only the
    /// failure one is an error, and only that one is coloured like the pane's
    /// other errors.
    func testNoteIsErrorOnlyForTransientFailures() async {
        let blocked = DevicesRemoveDeviceModel(remove: { throw KeyAPIError.lastActiveDevice })
        await blocked.requestRemoval(confirm: { true })
        XCTAssertEqual(blocked.state, .lastDevice)
        XCTAssertFalse(blocked.noteIsError, "the last-device note is informational, not an error")

        let failed = DevicesRemoveDeviceModel(remove: { throw KeyAPIError.http(503, "body") })
        await failed.requestRemoval(confirm: { true })
        XCTAssertTrue(failed.noteIsError)

        let idle = DevicesRemoveDeviceModel(remove: {})
        XCTAssertNil(idle.note)
        XCTAssertFalse(idle.noteIsError, "no note, nothing to colour")
    }

    /// Cancelling the confirmation leaves the model exactly where it was and
    /// never reaches the server.
    func testCancellingTheConfirmationDoesNothing() async {
        let removals = Counter()
        let model = DevicesRemoveDeviceModel(remove: { removals.calls += 1 })
        await model.requestRemoval(confirm: { false })

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(removals.calls, 0)
        XCTAssertTrue(model.canRequestRemoval)
    }
}
