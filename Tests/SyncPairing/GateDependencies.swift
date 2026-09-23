import Foundation
@MainActor final class SyncKeyController {
    enum MappingsOutcome: String { case held, cleared, measured }
    static let mappingsOutcomeKey = "outcome"
    var needsPairing = true
    var needsPairingActionable = true
    var isRetired = false
}
@MainActor final class AccountController {
    static let shared = AccountController()
    var account: Account?
    struct Account { let userDefaults = Defaults() }
    final class Defaults {
        func bool(forKey: String) -> Bool { false }
        func set(_ value: Bool, forKey: String) {}
    }
}
func AppLogWarn(_ message: String) {}
extension Notification.Name {
    static let phiProfileMappingsDidResolve = Notification.Name("mappings")
    static let phiProfileAutoCreateDidRun = Notification.Name("autocreate")
}
@MainActor final class RecordingHost: ProfilePairingModalHost {
    var presents = 0
    var dismisses = 0
    func present(controller: SyncKeyController?) { presents += 1 }
    func dismiss() { dismisses += 1 }
}
