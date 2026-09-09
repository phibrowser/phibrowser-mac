import AppKit

/// The single copy of the user-facing copy for "remove this device from sync",
/// plus the confirmation itself.
///
/// Two surfaces offer this action and both drive the very same
/// `SyncKeyController.removeThisDeviceFromSync()`: the blocking pairing modal
/// (`ProfilePairingGateView`, where it is the only exit other than finishing the
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
    static let confirmTitle = NSLocalizedString(
        "Remove this Mac from account sync?",
        comment: "Self-revoke confirmation - title")

    /// Names every piece of state the teardown drops, because "remove" is
    /// otherwise easy to read as "delete my data": the server revokes this
    /// device, the device key is rotated, and the cached account key, the
    /// profile mappings and the sync cursors are cleared — while every byte of
    /// local browsing data stays.
    static let confirmBody = NSLocalizedString(
        """
        This Mac leaves the account's sync. The server revokes this device, its device key is \
        rotated, and the cached account key, profile mappings and sync cursors are cleared.

        Browsing data on this Mac — Spaces, bookmarks, history and pinned tabs — is kept in full; \
        it simply stops syncing with your other devices. Joining again needs approval from another \
        device or your recovery code.
        """,
        comment: "Self-revoke confirmation - body")

    static let confirmAction = NSLocalizedString(
        "Remove This Device",
        comment: "Self-revoke confirmation - confirm")

    static let cancel = NSLocalizedString(
        "Cancel",
        comment: "Self-revoke confirmation - cancel")

    /// Shown in place under the (now disabled) button when the server answers
    /// 409 `last_device`. The parenthetical is not politeness: an account
    /// profile whose envelope will not open under this ARK is read-only and does
    /// not count towards the actionable pairing predicate, so "finish pairing"
    /// really is reachable in such an account.
    static let lastDeviceNote = NSLocalizedString(
        "This is the last device on the account, so it can’t be removed. Finish pairing on this "
            + "device (profiles that can’t be read don’t block it), or set up sync on another "
            + "device first, then try again.",
        comment: "Self-revoke - last active device")

    /// The shared second confirmation. `NSAlert` is the Preferences family's only
    /// confirmation idiom (`confirmationDialog` appears nowhere in this app), and
    /// the destructive button goes first so it is the one `.alertFirstButtonReturn`
    /// identifies — the same order the pairing gate has always used.
    @MainActor
    static func confirmRemoval() -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmTitle
        alert.informativeText = confirmBody
        alert.addButton(withTitle: confirmAction)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
