// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Whether a delete confirmation must say that the deletion also reaches the
/// user's other synced devices: this Mac is paired and the object has a sync
/// identity. A Space or Profile without one stays local, so the sentence would
/// be wrong for it.
@MainActor
enum SyncedDeletionNotice {
    static func appliesToSpace(_ spaceId: String) -> Bool {
        applies(isPaired: ProfilePairingGate.shared.isPaired,
                syncIdentity: PhiSpaceSyncState.shared.syncUuidLookup,
                localId: spaceId)
    }

    static func appliesToProfile(_ profileId: String) -> Bool {
        applies(isPaired: ProfilePairingGate.shared.isPaired,
                syncIdentity: PhiSpaceSyncState.shared.globalUuidLookup,
                localId: profileId)
    }

    /// `syncIdentity` maps a local id to its account uuid; nil means no sync
    /// engine has installed the lookup.
    static func applies(isPaired: Bool, syncIdentity: ((String) -> String?)?, localId: String) -> Bool {
        isPaired && syncIdentity?(localId) != nil
    }
}

/// The single delete-Space confirmation shared by Settings, the sidebar strip
/// and the app menu. Callers keep their own guards, the deletion and analytics.
@MainActor
enum SpaceDeletionConfirmation {
    /// Returns true when the user confirmed the deletion.
    static func run(space: Space) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("settings.spaces.deleteConfirmation.title", value: "Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = informativeText(
            pinnedTabScope: AccountController.shared.localDataAccount?.localStorage.pinnedTabScope(),
            showsSyncedDevicesNote: SyncedDeletionNotice.appliesToSpace(space.spaceId)
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.deleteConfirmation.deleteButton", value: "Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.deleteConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func informativeText(pinnedTabScope: PinnedTabScope?, showsSyncedDevicesNote: Bool) -> String {
        var text: String
        if pinnedTabScope == .space {
            text = NSLocalizedString("settings.spaces.deleteConfirmation.spaceScopedMessage", value: "Bookmarks and pinned tabs belonging to this Space will also be removed. This action cannot be undone.",
                comment: "Body of the delete-Space confirmation with Space-scoped pinned tabs"
            )
        } else {
            text = NSLocalizedString("settings.spaces.deleteConfirmation.message", value: "Bookmarks belonging to this Space will also be removed. This action cannot be undone.",
                comment: "Body of the delete-Space confirmation"
            )
        }
        if showsSyncedDevicesNote {
            text += "\n\n" + NSLocalizedString("settings.spaces.deleteConfirmation.syncedDevicesNote", value: "This Space will also be deleted from your other synced devices.",
                comment: "Delete-Space confirmation - Extra sentence shown when sync is on and the Space syncs to the user's other devices"
            )
        }
        return text
    }
}

/// The single delete-Profile flow shared by Settings and the app menu:
/// confirmation, the post-modal in-use re-check, the deletion and its failure alert.
@MainActor
enum ProfileDeletionFlow {
    static func confirmAndDelete(_ profile: PhiBrowserProfile) {
        guard profile.profileId != LocalStore.defaultProfileId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("settings.profiles.deleteConfirmation.title", value: "Delete profile \u{201C}%@\u{201D}?", comment: "Title of the delete-profile confirmation"),
            profile.displayName
        )
        // §9.4: deliberately fail-OPEN plus a warning rather than fail-closed.
        // `blocksProfileDeletion` answers false until the account's Spaces have
        // been drained once, and on a long-offline or long-ARK-locked Mac a
        // fail-closed prompt might never clear.
        //
        // Gated on account Space sync being live for this Mac as well, and not on
        // the drain flag alone: `hasDrainedFullReplay` is a per-process cache the
        // engine pushes back after every table write, so with no engine at all
        // (signed out, or the Spaces feature off) it stays false forever and the
        // warning would mention "the Spaces in your account" on a Mac that has
        // no account Spaces.
        let showsNotDrainedWarning = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && LoginController.shared.isLoggedin()
            && !PhiSpaceSyncState.shared.hasDrainedFullReplay
        alert.informativeText = informativeText(
            showsSyncedDevicesNote: SyncedDeletionNotice.appliesToProfile(profile.profileId),
            showsNotDrainedWarning: showsNotDrainedWarning
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.deleteConfirmation.deleteButton", value: "Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.deleteConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Re-check AFTER the modal: the delete control was validated before it
        // opened, and a Space can be bound to this profile while the
        // confirmation sits on screen (background work — the agent surface
        // included — keeps running under runModal). Nothing below this guard
        // re-checks: neither ProfileManager nor the Chromium bridge knows
        // about Space bindings.
        guard !SpaceManager.shared.isProfileInUse(profile.profileId) else {
            presentFailure(NSLocalizedString("settings.profiles.deleteFailure.inUseBySpace", value: "A Space is using this profile. Delete that Space or change its profile first.",
                comment: "Body of the profile-delete error when a Space became bound to the profile before the deletion ran"
            ))
            return
        }
        ProfileManager.shared.deleteProfile(profile.profileId) { success, error in
            if !success {
                presentFailure(error ?? NSLocalizedString("settings.profiles.deleteFailure.unknownError", value: "Unknown error", comment: "Fallback profile-delete error reason"))
            }
        }
    }

    static func informativeText(showsSyncedDevicesNote: Bool, showsNotDrainedWarning: Bool) -> String {
        var text = NSLocalizedString("settings.profiles.deleteConfirmation.browserDataAndChats", value: "Cookies, history, extensions, and other browser data in this profile will be permanently removed. Conversations will be kept in Phi Chat under Uncategorized. If AI is disabled or unavailable, conversations will be moved when AI is enabled and available again.",
            comment: "Profiles settings - Profile deletion confirmation distinguishing permanently removed browser data from retained conversations and explaining deferred organization while AI is unavailable"
        )
        if showsSyncedDevicesNote {
            text += "\n\n" + NSLocalizedString("settings.profiles.deleteConfirmation.syncedDevicesNote", value: "This profile will also be deleted from your other synced devices.",
                comment: "Delete-profile confirmation - Extra sentence shown when sync is on and the profile syncs to the user's other devices"
            )
        }
        if showsNotDrainedWarning {
            text += "\n\n" + NSLocalizedString(
                "This Mac hasn’t finished syncing the Spaces in your account yet. After you delete this profile, Spaces on your other devices that use it may not open.",
                comment: "Extra warning shown when the account's Spaces have not been synced yet"
            )
        }
        return text
    }

    /// Failure reason shown when the deletion cannot be recorded for sync, so
    /// the other devices would never learn about it. The deletion path reports
    /// it as the completion error string, which `presentFailure` displays.
    static var syncRecordFailedMessage: String {
        NSLocalizedString("profiles.delete.syncRecordFailed", value: "Could not save the sync deletion record. Please try again.",
            comment: "Delete-profile error - Reason shown when the profile could not be deleted because its deletion could not be saved for sync to the user's other devices"
        )
    }

    private static func presentFailure(_ reason: String) {
        let errAlert = NSAlert()
        errAlert.messageText = NSLocalizedString("settings.profiles.deleteFailure.title", value: "Couldn't delete profile", comment: "Title of the profile-delete error")
        errAlert.informativeText = reason
        errAlert.runModal()
    }
}
