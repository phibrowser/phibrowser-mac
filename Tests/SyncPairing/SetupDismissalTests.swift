import Foundation

@main
struct SetupDismissalTests {
    @MainActor static func main() throws {
        let gate = ProfilePairingGate()
        let host = RecordingHost()
        gate.modalHost = host
        let controller = SyncKeyController()
        try gate.configureEnrollment(deviceKeyID: "verified-device", recordData: nil,
                                     saveRecord: { _ in true })
        try gate.beginEnrollment()

        var dismissals = 0
        var enrollmentChanges = 0
        let dismissed = NotificationCenter.default.addObserver(
            forName: Notification.Name("phiSyncSetupDidDismiss"), object: nil, queue: nil
        ) { note in
            MainActor.assumeIsolated {
                guard note.object as? ProfilePairingGate === gate else { return }
                precondition(host.dismisses > 0, "Refresh must follow closing the setup host")
                dismissals += 1
            }
        }
        let changed = NotificationCenter.default.addObserver(
            forName: .phiSyncPairingStateDidChange, object: nil, queue: nil
        ) { note in
            MainActor.assumeIsolated {
                if note.object as? ProfilePairingGate === gate { enrollmentChanges += 1 }
            }
        }
        defer {
            NotificationCenter.default.removeObserver(dismissed)
            NotificationCenter.default.removeObserver(changed)
        }

        gate.requestPresentation(controller: controller)
        // Verification can register the device without completing Profile/Space pairing.
        // Closing then must tell the pane to reload that changed registration state.
        gate.finishLater()
        precondition(dismissals == 1, "Deferring setup must refresh the pane after device verification")
        precondition(!gate.isPaired && enrollmentChanges == 0,
                     "Dismissing setup must not claim enrollment changed or completed")
        gate.finishLater()
        precondition(dismissals == 1, "An already closed session must not refresh again")

        gate.requestPresentation(controller: controller)
        gate.stop() // Account retirement has its own account-change refresh.
        gate.finishLater()
        precondition(dismissals == 1, "A retired account's session must not send a late dismissal")

        let nextController = SyncKeyController()
        try gate.configureEnrollment(deviceKeyID: "next-account-device", recordData: nil,
                                     saveRecord: { _ in true })
        gate.requestPresentation(controller: nextController)
        gate.finishLater()
        precondition(dismissals == 2, "The next account's actual dismissal must remain observable")
        // A live controller announces `.cleared` whenever a background resolve finds this
        // device still unjoined; the join steps run inside this window, so it must stay up.
        gate.requestPresentation(controller: nextController)
        let dismissesBefore = host.dismisses
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false,
                                      outcome: .cleared, controllerRetired: false)
        precondition(host.dismisses == dismissesBefore, "A live controller's .cleared must not close setup mid-join")
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false,
                                      outcome: .cleared, controllerRetired: true)
        precondition(host.dismisses == dismissesBefore + 1, "A retired controller's .cleared must close setup")
        precondition(dismissals == 3, "Closing for a retired controller still refreshes the pane")
        // A previous account's unlock may fail after its controller has retired. Its
        // .cleared must not dismiss the next account's verification/recovery-code UI.
        gate.start(controller: nextController)
        gate.requestPresentation(controller: nextController)
        controller.isRetired = true
        let beforeStaleNotification = host.dismisses
        NotificationCenter.default.post(name: .phiProfileMappingsDidResolve, object: controller,
            userInfo: [SyncKeyController.mappingsOutcomeKey: "cleared"])
        precondition(host.dismisses == beforeStaleNotification,
                     "A retired previous controller must not close the current setup")
        nextController.isRetired = true
        NotificationCenter.default.post(name: .phiProfileMappingsDidResolve, object: nil,
            userInfo: [SyncKeyController.mappingsOutcomeKey: "cleared"])
        precondition(host.dismisses == beforeStaleNotification,
                     "An unattributed notification must not close the current setup")
        NotificationCenter.default.post(name: .phiProfileMappingsDidResolve, object: nextController,
            userInfo: [SyncKeyController.mappingsOutcomeKey: "cleared"])
        precondition(host.dismisses == beforeStaleNotification + 1,
                     "Retiring the current controller still closes its setup")
        gate.stop()
        print("PASS setup dismissal: live .cleared keeps setup, retired .cleared closes it")
        print("PASS setup dismissal: stale and unattributed notifications cannot close another session")
        print("PASS setup dismissal: refresh after defer, unchanged enrollment, duplicate and retired sessions")
    }
}
