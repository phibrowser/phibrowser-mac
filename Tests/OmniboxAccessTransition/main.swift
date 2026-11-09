import Foundation

final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(memoryOnly: Bool) { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@main
enum OmniboxAccessTransitionTests {
    @MainActor
    static func main() async {
        let center = NotificationCenter()
        let state = ApplicationState(defaults: MemoryDefaults(memoryOnly: true),
                                     notificationCenter: center, supportsAuthentication: true)
        var transitions: [String] = []
        let before = center.addObserver(forName: .omniboxAuthorityWillChange, object: nil, queue: nil) { _ in
            precondition(Thread.isMainThread)
            precondition(state.isOmniboxAuthorityTransitioning)
            // Taking these locks in an observer must not deadlock.
            _ = state.browserAccessState
            _ = state.canUseBrowser
            transitions.append("will")
        }
        let after = center.addObserver(forName: .omniboxAuthorityDidChange, object: nil, queue: nil) { _ in
            precondition(Thread.isMainThread)
            precondition(!state.isOmniboxAuthorityTransitioning)
            transitions.append("did")
        }
        state.enterGuestMode()
        precondition(transitions == ["will", "did"])
        state.enterGuestMode()
        precondition(transitions.count == 2, "Unchanged access must not revoke")
        precondition(state.beginGuestAccountPromotion())
        precondition(transitions.count == 4)
        precondition(state.beginGuestAccountPromotion())
        precondition(transitions.count == 4)
        state.cancelGuestAccountPromotion()
        precondition(transitions.count == 6)
        precondition(state.beginGuestMigrationRecovery(notifyBrowserAccessChange: false))
        precondition(transitions.count == 8, "Safety notification is independent of ordinary UI notification")
        state.endGuestMigrationRecovery()
        precondition(transitions.count == 10)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                state.markSignedIn()
                continuation.resume()
            }
        }
        precondition(state.browserAccessState == .signedIn)
        precondition(transitions.count == 12)
        center.removeObserver(before)
        center.removeObserver(after)
        print("OmniboxAccessTransition: actual access transactions and notification ordering passed")
    }
}
