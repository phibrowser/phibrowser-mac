import Foundation

/// Settings → Devices: the state machine behind the Removal row ("Remove this
/// Mac from sync" or, on the account's only active device, "Reset sync"), the
/// runtime counterpart of the pairing modal's exit.
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
        /// The server refused: this is the account's last active device. The
        /// removal button stays disabled; the account reset is offered instead.
        case lastDevice
        /// The account reset's second confirmation is up (same reason as
        /// `confirming`: the alert is app-modal).
        case confirmingReset
        case resetting
        /// The reset failed without a refusal (offline, 5xx, Keychain). Still the
        /// last device, so the reset stays on offer for a retry.
        case resetFailed(String)
        /// Transient failure (offline, 5xx, Keychain). Retrying is the fix, so
        /// this does NOT disable the button.
        case failed(String)
        case done
    }

    @Published private(set) var state: State = .idle

    /// All closures are `@MainActor`: the model is main-actor confined and the
    /// production bodies touch the pane's own view model and the coordinator.
    private let remove: @MainActor () async throws -> Void
    private let reset: @MainActor () async throws -> Void
    private let onRemoved: (@MainActor () async -> Void)?
    private let onRefused: (@MainActor () async -> Void)?

    /// - Parameters:
    ///   - remove: the teardown itself — production passes the shared
    ///     controller's `removeThisDeviceFromSync()`.
    ///   - reset: the account reset, offered when the pane's device list shows
    ///     this Mac as the only active device or after a `last_device` refusal —
    ///     production passes the same controller's
    ///     `resetSyncAndRemoveThisDevice()`.
    ///   - onRemoved: run once, after a successful removal or reset, so the pane
    ///     can re-derive its own `unlockState` (which lives on
    ///     `DevicesSettingViewModel` and only changes when `loadAll()` runs).
    ///   - onRefused: run once when the server refuses a reset (`not_last_device`
    ///     or `device_not_found`), so the pane re-reads its device list and the
    ///     row flips back to the removal; nothing was deleted, so polling goes on.
    init(remove: @escaping @MainActor () async throws -> Void,
         reset: @escaping @MainActor () async throws -> Void,
         onRemoved: (@MainActor () async -> Void)? = nil,
         onRefused: (@MainActor () async -> Void)? = nil) {
        self.remove = remove
        self.reset = reset
        self.onRemoved = onRemoved
        self.onRefused = onRefused
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
        case .confirming, .removing, .lastDevice, .confirmingReset, .resetting, .resetFailed, .done:
            return false
        }
    }

    /// Whether the account reset is on screen: only on the last device, and it
    /// stays while its confirmation is up or it is running.
    var showsResetOffer: Bool {
        switch state {
        case .lastDevice, .confirmingReset, .resetting, .resetFailed: return true
        case .idle, .confirming, .removing, .failed, .done: return false
        }
    }

    /// Whether the reset may be asked for. Besides the `last_device` states it
    /// is allowed from `.idle` and `.failed`: the pane offers the reset directly
    /// when its device list shows this Mac as the only active device, and the
    /// server re-checks at reset time (`not_last_device`).
    var canRequestReset: Bool {
        switch state {
        case .idle, .failed, .lastDevice, .resetFailed: return true
        case .confirming, .removing, .confirmingReset, .resetting, .done: return false
        }
    }

    var isRemoving: Bool { state == .removing || state == .resetting }

    /// The line shown under the button: the `last_device` explanation, or the
    /// metadata-only rendering of a transient failure (R12 — never a response
    /// body, never a full uuid).
    var note: String? {
        switch state {
        case .lastDevice, .confirmingReset, .resetting: return SelfRevokeStrings.lastDeviceNote
        case .failed(let message), .resetFailed(let message): return message
        default: return nil
        }
    }

    /// Whether `note` is an error the user must act on (`failed` — retry) rather
    /// than the standing `last_device` explanation. The pane colours the two
    /// differently: every other error on that pane is red, and the one the user
    /// has to notice must not be the exception.
    var noteIsError: Bool {
        switch state {
        case .failed, .resetFailed: return true
        default: return false
        }
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

    /// Confirmation, then the account reset. The server's refusals
    /// (`notLastDevice`: another device appeared; `deviceNotFound`: the account
    /// was re-enrolled without this Mac) deleted nothing, so the pane returns to
    /// an ordinary retryable state and `onRefused` reloads its device list.
    /// Other failures keep the offer for a retry.
    /// The UI copy is fixed; only metadata reaches the log (R12).
    func requestReset(confirm: @MainActor () -> Bool) async {
        guard canRequestReset else { return }
        let previous = state
        state = .confirmingReset
        guard confirm() else {
            state = previous
            return
        }
        state = .resetting
        AppLogInfo("[phi-sync] account reset requested")
        do {
            try await reset()
            state = .done
            await onRemoved?()
        } catch KeyAPIError.notLastDevice {
            AppLogInfo("[phi-sync] account reset refused: not the last device")
            state = .failed(SelfRevokeStrings.resetRefusedNotLastDevice)
            await onRefused?()
        } catch KeyAPIError.deviceNotFound {
            AppLogInfo("[phi-sync] account reset refused: device not found")
            state = .failed(SelfRevokeStrings.removalUnavailable)
            await onRefused?()
        } catch {
            AppLogWarn("[phi-sync] account reset failed (\(PhiSyncLog.describe(error)))")
            state = .resetFailed(SelfRevokeStrings.removalUnavailable)
        }
    }
}
