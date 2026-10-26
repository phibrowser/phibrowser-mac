import AppKit

/// The single copy of the user-facing copy for "remove this device from sync",
/// plus the confirmation itself.
///
/// Two surfaces offer this action and both drive the very same
/// `SyncKeyController.removeThisDeviceFromSync()`: the blocking pairing modal
/// (`PairingWizardView`, where it is the only exit other than finishing the
/// pairing) and the runtime entry point in Settings → Devices
/// (`DevicesSettingView`). A second copy of the promise is how the two promises
/// drift apart — what the alert says about the browsing data staying put is a
/// commitment about the teardown order in `removeThisDeviceFromSync()`, not
/// decoration — so the strings live here and neither surface owns one.
///
/// The strings are English because the app's string catalog
/// (`Resources/Localizable.xcstrings`) declares `sourceLanguage = "en"` and the
/// Devices pane is authored in English throughout. That moves the gate's alert
/// from Chinese to English; the gate's remaining labels are untouched.
enum SelfRevokeStrings {
    static let confirmTitle = NSLocalizedString("sync.removal.confirmation.title",
        value: "Remove this Mac from account sync?",
        comment: "Remove this device from sync - confirmation dialog title")

    /// Names every piece of state the teardown drops, because "remove" is
    /// otherwise easy to read as "delete my data": the server revokes this
    /// device, the device key is rotated, and the cached account key, the
    /// profile mappings and the sync cursors are cleared — while every byte of
    /// local browsing data stays.
    static let confirmBody = NSLocalizedString(
        "sync.removal.explanation", value: "This Mac will stop syncing. Your local browsing data stays on this Mac. To join again, use approval from another device or your saved recovery code.",
        comment: "Consequences of removing this device from sync")

    static let confirmAction = NSLocalizedString("sync.removal.confirmation.confirm",
        value: "Remove This Device",
        comment: "Remove this device from sync - confirmation dialog button that removes the device")

    static let cancel = NSLocalizedString("sync.removal.confirmation.cancel",
        value: "Cancel",
        comment: "Remove this device from sync - confirmation dialog cancel button")

    /// Shown in place under the (now disabled) button when the server answers
    /// 409 `last_device`, next to the `resetOffer` action it introduces.
    static let lastDeviceNote = NSLocalizedString(
        "sync.removal.lastDeviceResetOffer", value: "This is the last device set up for sync. You can remove it and delete all sync data stored for this account, or set up sync on another device first.",
        comment: "Remove this device from sync - note shown when this is the account's last device, introducing the option to delete all sync data")

    /// The destructive action offered only after a `last_device` refusal. It runs
    /// `SyncKeyController.resetSyncAndRemoveThisDevice()` after `confirmReset()`.
    static let resetOffer = NSLocalizedString("sync.removal.resetOffer",
        value: "Remove this device and delete all sync data…",
        comment: "Remove this device from sync - button shown on the account's last device that removes it and deletes all of the account's sync data")

    static let resetConfirmTitle = NSLocalizedString("sync.removal.resetConfirmTitle",
        value: "Delete all sync data for this account?",
        comment: "Delete all sync data - confirmation dialog title, shown before the last device removes itself and deletes the account's sync data")

    /// Names the whole consequence, because the reset cannot be undone: every
    /// device leaves, the server's copy is deleted, local browsing data stays,
    /// and sync starts over from the first-device setup.
    static let resetConfirmBody = NSLocalizedString("sync.removal.resetConfirmBody",
        value: "Every device will be removed from sync, and all data stored on the sync server for this account will be deleted. Your local browsing data stays on this Mac. To use sync again, you’ll need to set it up from scratch.",
        comment: "Delete all sync data - confirmation dialog message explaining what deleting the account's sync data does")

    static let resetConfirmAction = NSLocalizedString("sync.removal.resetConfirmAction",
        value: "Delete All Sync Data",
        comment: "Delete all sync data - confirmation dialog button that removes this device and deletes the account's sync data")

    /// Shown when the server refused a reset with 409 `not_last_device`: the
    /// Devices pane offered "Reset sync" from a device list that showed this Mac
    /// alone, but another device joined before the request. Nothing was deleted.
    static let resetRefusedNotLastDevice = NSLocalizedString("sync.removal.resetRefusedNotLastDevice",
        value: "Another device has joined this account since, so nothing was deleted. You can remove this Mac from sync instead.",
        comment: "Reset sync - error shown when the server refused the reset because another device joined the account in the meantime")

    /// Shown in place of a removal that never reached the server: the shared
    /// `SyncKeyController` was gone by the time the button was clicked (a
    /// sign-out in another window, say). Retrying is the fix, so this reads as a
    /// transient failure rather than a refusal.
    static let removalUnavailable = NSLocalizedString("sync.removal.unavailable",
        value: "Sync isn’t available right now, so this device wasn’t removed. Check that you’re still signed in, then try again.",
        comment: "Remove this device from sync - error shown when sync is unavailable so the device was not removed")

    /// The shared second confirmation. `NSAlert` is the Preferences family's only
    /// confirmation idiom (`confirmationDialog` appears nowhere in this app), and
    /// the destructive button goes first so it is the one `.alertFirstButtonReturn`
    /// identifies — the same order the pairing gate has always used.
    ///
    /// `.warning` + `hasDestructiveAction` on that first button are what make the
    /// irreversibility visible rather than merely stated: the confirm button is
    /// drawn in the destructive tint, as the pane family's other teardown
    /// confirmations are (`SpacesSettingsView.deleteSpace` / `changeSpaceProfile`).
    @MainActor
    static func confirmRemoval() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmTitle
        alert.informativeText = confirmBody
        alert.addButton(withTitle: confirmAction)
        alert.addButton(withTitle: cancel)
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The account reset's second confirmation, in the same destructive style. Like
    /// `confirmRemoval()` it is a synchronous `NSAlert` that awaits nothing while up.
    @MainActor
    static func confirmReset() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = resetConfirmTitle
        alert.informativeText = resetConfirmBody
        alert.addButton(withTitle: resetConfirmAction)
        alert.addButton(withTitle: cancel)
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Copy shared by the Sync pane and setup's blocked preview.
enum SyncReconfigurationStrings {
    static let title = NSLocalizedString("sync.reconfigure.title", value: "Set up sync again", comment: "Action to explicitly reset local sync state and configure it again")
    static let explanation = NSLocalizedString("sync.reconfigure.explanation", value: "The account’s sync data has changed. Syncing Phi data is paused. Review your account and connection before setting up sync again.", comment: "Native sync paused after the server rejected its previous identity")
    static let confirmation = NSLocalizedString("sync.reconfigure.confirmation", value: "This will clear this Mac’s sync setup and matching information, then let you set up sync again. Your local browsing data and account’s synced data will be kept.", comment: "Confirmation before clearing only local sync metadata")
    static let failed = NSLocalizedString("sync.reconfigure.failed", value: "Couldn’t finish clearing this Mac’s sync setup. Sync remains paused. Try setting up sync again.", comment: "Local metadata cleanup failed and may be retried")
    static let returnToSettings = NSLocalizedString("sync.reconfigure.returnToSettings", value: "Sync needs to be set up again. Finish later, then choose Set up sync again in Settings → Sync. Your local browsing data is kept.", comment: "Pairing cannot continue until an explicit local sync reset is confirmed in settings")

    @MainActor static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = confirmation
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: SelfRevokeStrings.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
