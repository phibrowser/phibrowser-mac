import Foundation

/// Settings → Devices: the state machine behind "Remove this device from sync…",
/// the runtime counterpart of the pairing modal's exit of the same name.
///
/// It deliberately does NOT hold a `SyncKeyController`. The removal arrives as a
/// closure for two reasons: the controller is a concrete `@MainActor final class`
/// with no protocol (so a pane test could not fake it), and — more importantly —
/// the closure is the one place that names WHICH controller runs the teardown.
/// Only the coordinator-owned instance carries `retirePhiSync` /
/// `deviceKeyRotator` / `engineDefaults` / `spaceStateStore`; a controller built
/// from the pane's own signed-out `SyncKeyStack.make(accountId:)` fallback would
/// revoke the device server-side and then leave the engine running, the device
/// key unrotated and the cursors in place. `DevicesSettingHostingViewController`
/// binds the closure to `PhiChromiumCoordinator.shared.syncKeyControllerCreatingIfNeeded()`
/// and to nothing else.
/// Why a removal could not even be attempted.
///
/// `DevicesSettingHostingViewController` throws this when the coordinator-owned
/// `SyncKeyController` is gone at click time (a sign-out in another window
/// between the button rendering and the click). It has to be an error rather
/// than a quiet return: a closure that returns normally is the model's proof
/// that the device left the account, and reporting `.done` for a teardown that
/// never reached the server would hide the failure behind a success state.
enum DevicesRemoveDeviceError: Error {
    case syncControllerUnavailable
}

@MainActor
final class DevicesRemoveDeviceModel: ObservableObject {
    /// `confirming` is a real state rather than a transient: the confirmation is
    /// an app-modal `NSAlert`, so the button must already be inert when it opens
    /// or a second click can queue behind the modal.
    enum State: Equatable {
        case idle
        case confirming
        case removing
        /// The server refused: this is the account's last active device. Sticky —
        /// nothing the pane can do adds a second device.
        case lastDevice
        /// Transient failure (offline, 5xx, Keychain). Retrying is the fix, so
        /// this does NOT disable the button.
        case failed(String)
        case done
    }

    @Published private(set) var state: State = .idle

    /// Both closures are `@MainActor`: the model is main-actor confined and the
    /// production bodies touch the pane's own view model and the coordinator.
    private let remove: @MainActor () async throws -> Void
    private let onRemoved: (@MainActor () async -> Void)?

    /// - Parameters:
    ///   - remove: the teardown itself — production passes the shared
    ///     controller's `removeThisDeviceFromSync()`.
    ///   - onRemoved: run once, after a successful removal, so the pane can
    ///     re-derive its own `unlockState` (which lives on
    ///     `DevicesSettingViewModel` and only changes when `loadAll()` runs).
    init(remove: @escaping @MainActor () async throws -> Void,
         onRemoved: (@MainActor () async -> Void)? = nil) {
        self.remove = remove
        self.onRemoved = onRemoved
    }

    /// The button is the exact complement of the pane's "Set up sync on this
    /// device" arm: it appears only where that one does not, i.e. this device is
    /// joined and unlocked. `.done` hides it immediately rather than waiting for
    /// the pane's reload to drop `unlockState` to `.needsJoin`.
    func isVisible(unlockState: DevicesSettingViewModel.UnlockState) -> Bool {
        unlockState == .unlocked && state != .done
    }

    /// False while a removal is confirming or in flight (requirement: only one
    /// removal at a time), after a `last_device` refusal, and once done.
    var canRequestRemoval: Bool {
        switch state {
        case .idle, .failed: return true
        case .confirming, .removing, .lastDevice, .done: return false
        }
    }

    var isRemoving: Bool { state == .removing }

    /// The line shown under the button: the `last_device` explanation, or the
    /// metadata-only rendering of a transient failure (R12 — never a response
    /// body, never a full uuid).
    var note: String? {
        switch state {
        case .lastDevice: return SelfRevokeStrings.lastDeviceNote
        case .failed(let message): return message
        default: return nil
        }
    }

    /// Whether `note` is an error the user must act on (`failed` — retry) rather
    /// than the standing `last_device` explanation. The pane colours the two
    /// differently: every other error on that pane is red, and the one the user
    /// has to notice must not be the exception.
    var noteIsError: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Confirm, then run the teardown. `confirm` is injected so the pane can pass
    /// the shared app-modal `NSAlert` while tests pass a plain answer.
    func requestRemoval(confirm: @MainActor () -> Bool) async {
        guard canRequestRemoval else { return }
        state = .confirming
        guard confirm() else {
            state = .idle
            return
        }
        state = .removing
        AppLogInfo("[phi-sync] remove this device requested")
        do {
            try await remove()
            // The success line is `SyncKeyController.removeThisDeviceFromSync()`'s
            // own ("this device left the account's sync"); a second one here would
            // only double-count in the log.
            state = .done
            await onRemoved?()
        } catch KeyAPIError.lastActiveDevice {
            AppLogInfo("[phi-sync] remove this device refused: last active device")
            state = .lastDevice
        } catch DevicesRemoveDeviceError.syncControllerUnavailable {
            // Nothing was sent, so this is a plain retryable failure; the message
            // is a user-facing one because the error carries no server metadata
            // worth rendering.
            AppLogWarn("[phi-sync] remove this device failed: no shared sync key controller")
            state = .failed(SelfRevokeStrings.removalUnavailable)
        } catch {
            let described = PhiSyncLog.describe(error)
            AppLogWarn("[phi-sync] remove this device failed (\(described))")
            state = .failed(described)
        }
    }
}
