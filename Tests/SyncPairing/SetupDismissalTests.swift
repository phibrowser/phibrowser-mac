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
        print("PASS setup dismissal: refresh after defer, unchanged enrollment, duplicate and retired sessions")
    }
}
