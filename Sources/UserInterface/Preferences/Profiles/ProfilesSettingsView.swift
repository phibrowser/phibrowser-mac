// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Settings pane content for managing Chromium profiles, laid out master-detail:
/// the profile list on the left (with a +/−/✎ toolbar) and the selected
/// profile's browser settings on the right (`ProfileDetailSettingsView`).
/// Profile lifecycle routes through `ProfileManager`; `SpaceManager` is observed
/// for each profile's Space count and the delete guard.
struct ProfilesSettingsView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    @State private var selectedProfileId: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            profileListPanel
                // Fixed, and narrower than the Spaces pane's 280 list: profile
                // rows carry less content, and the detail column needs the room.
                .frame(width: 240)
                .frame(maxHeight: .infinity)
            detailPanel
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 36)
        .onAppear {
            profileManager.refresh()
            if selectedProfileId == nil { selectInitialProfile() }
        }
        // Keep the selection valid as the profile list changes (create/delete).
        .onChange(of: profileManager.profiles.map(\.profileId)) { ids in
            if let sel = selectedProfileId, ids.contains(sel) { return }
            selectInitialProfile()
        }
    }

    // MARK: - Left: profile list

    private var profileListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("settings.profiles.listTitle", value: "Your Profiles", comment: "Profiles settings - list header"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            SettingsRowDivider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(profileManager.profiles) { profile in
                        profileListRow(profile)
                    }
                }
                .padding(6)
            }

            SettingsRowDivider()

            HStack(spacing: 0) {
                toolbarButton(systemName: "plus",
                              help: NSLocalizedString("settings.profiles.newButtonTooltip", value: "New profile", comment: "Profiles settings - new profile tooltip"),
                              action: newProfile)
                toolbarDivider
                toolbarButton(systemName: "minus",
                              help: NSLocalizedString("settings.profiles.deleteButtonTooltip", value: "Delete selected profile", comment: "Profiles settings - delete profile tooltip"),
                              disabled: !canDeleteSelected,
                              action: deleteSelected)
                toolbarDivider
                toolbarButton(systemName: "pencil",
                              help: NSLocalizedString("settings.profiles.renameButtonTooltip", value: "Rename selected profile", comment: "Profiles settings - rename profile tooltip"),
                              disabled: selectedProfile == nil,
                              action: renameSelected)
                Spacer()
            }
            .frame(height: 34)
        }
        .settingsCardChrome()
    }

    private func profileListRow(_ profile: PhiBrowserProfile) -> some View {
        let isSelected = profile.profileId == selectedProfileId
        let isDefault = profile.profileId == LocalStore.defaultProfileId
        let count = spaceManager.spaces.filter { $0.profileId == profile.profileId }.count
        return Button {
            select(profile.profileId)
        } label: {
            HStack(spacing: 6) {
                Text(profile.displayName)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .lineLimit(1)
                if isDefault {
                    SettingsDefaultBadge()
                }
                Spacer(minLength: 4)
                Text(count == 0
                     ? NSLocalizedString("settings.profiles.unusedStatus", value: "Not used", comment: "Profiles settings - tag for a profile with no Spaces")
                     : Self.spaceCountLabel(count))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolbarButton(systemName: String,
                               help: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.7))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(width: 1, height: 20)
    }

    // MARK: - Right: per-profile settings

    @ViewBuilder
    private var detailPanel: some View {
        if let profileId = selectedProfileId {
            ScrollView {
                ProfileDetailSettingsView(profileId: profileId)
            }
        } else {
            Text(NSLocalizedString("settings.profiles.details.emptyPlaceholder", value: "Select a profile to view its settings.",
                                   comment: "Profiles settings - empty detail placeholder"))
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Selection

    private var selectedProfile: PhiBrowserProfile? {
        guard let id = selectedProfileId else { return nil }
        return profileManager.profiles.first(where: { $0.profileId == id })
    }

    private var canDeleteSelected: Bool {
        guard let profile = selectedProfile,
              profile.profileId != LocalStore.defaultProfileId else { return false }
        // Store-read, not the `spaces` cache — see `isProfileInUse`.
        return !spaceManager.isProfileInUse(profile.profileId)
    }

    private func selectInitialProfile() {
        let preferred = profileManager.profiles.first(where: { $0.profileId == LocalStore.defaultProfileId })
            ?? profileManager.profiles.first
        if let profile = preferred {
            select(profile.profileId)
        } else {
            selectedProfileId = nil
        }
    }

    private func select(_ profileId: String) {
        selectedProfileId = profileId
    }

    // MARK: - Helpers

    static func spaceCountLabel(_ count: Int, bundle: Bundle = .main) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString(
                "settings.profiles.boundSpaceCount",
                bundle: bundle,
                value: "%d Spaces",
                comment: "Profiles settings - Number of Spaces bound to a profile; %d is the number of Spaces"
            ),
            count
        )
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        deleteProfile(profile)
    }

    private func renameSelected() {
        guard let profile = selectedProfile else { return }
        renameProfile(profile)
    }

    private func newProfile() {
        guard let name = ProfileNameFieldValidator.present(.create) else { return }
        profileManager.createProfile(displayName: name) { newId in
            if let newId { select(newId) }
        }
    }

    private func renameProfile(_ profile: PhiBrowserProfile) {
        guard let trimmed = ProfileNameFieldValidator.present(
            .rename(currentName: profile.displayName, profileId: profile.profileId)) else { return }
        guard trimmed != profile.displayName else { return }
        profileManager.renameProfile(profile.profileId, to: trimmed) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("settings.profiles.renameFailure.title", value: "Couldn't rename profile", comment: "Title of the profile-rename error")
                errAlert.informativeText = error ?? NSLocalizedString("settings.profiles.renameFailure.unknownError", value: "Unknown error", comment: "Fallback profile-rename error reason")
                errAlert.runModal()
            }
        }
    }

    private func deleteProfile(_ profile: PhiBrowserProfile) {
        guard profile.profileId != LocalStore.defaultProfileId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("settings.profiles.deleteConfirmation.title", value: "Delete profile \u{201C}%@\u{201D}?", comment: "Title of the delete-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = NSLocalizedString("settings.profiles.deleteConfirmation.message", value: "All cookies, history, extensions, and saved data on this profile will be permanently removed. This cannot be undone.",
            comment: "Body of the delete-profile confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.deleteConfirmation.deleteButton", value: "Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.deleteConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Re-check AFTER the modal: the delete button was validated before it
        // opened, and a Space can be bound to this profile while the
        // confirmation sits on screen (background work — the agent surface
        // included — keeps running under runModal). Nothing below this guard
        // re-checks: neither ProfileManager nor the Chromium bridge knows
        // about Space bindings.
        guard !spaceManager.isProfileInUse(profile.profileId) else {
            let errAlert = NSAlert()
            errAlert.messageText = NSLocalizedString("settings.profiles.deleteFailure.title", value: "Couldn't delete profile", comment: "Title of the profile-delete error")
            errAlert.informativeText = NSLocalizedString("settings.profiles.deleteFailure.inUseBySpace", value: "A Space is using this profile. Delete that Space or change its profile first.",
                comment: "Body of the profile-delete error when a Space became bound to the profile before the deletion ran"
            )
            errAlert.runModal()
            return
        }
        profileManager.deleteProfile(profile.profileId) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("settings.profiles.deleteFailure.title", value: "Couldn't delete profile", comment: "Title of the profile-delete error")
                errAlert.informativeText = error ?? NSLocalizedString("settings.profiles.deleteFailure.unknownError", value: "Unknown error", comment: "Fallback profile-delete error reason")
                errAlert.runModal()
            }
        }
    }
}

/// Live validator for a profile-name field inside an `NSAlert`. Owns the field
/// and a vertical accessory (field above, an inline red message below) and keeps
/// the alert's confirm button greyed out until the trimmed name is non-empty and
/// unique. Replaces the old dismiss-and-re-present-on-error loop: errors now
/// appear inline without the alert flickering. Shared by the create (Phi menu /
/// Profiles settings / create-Space) and rename prompts; pass `excludingProfileId`
/// when renaming so a profile's own name isn't treated as a clash. An empty field
/// just disables confirm — no red message until the user types a duplicate.
///
/// The caller must keep the instance alive for the modal's lifetime; a local
/// `let` across `runModal()` suffices (`NSTextField.delegate` is weak).
final class ProfileNameFieldValidator: NSObject, NSTextFieldDelegate {
    let field = NSTextField(frame: NSRect(x: 0, y: 20, width: 240, height: 24))
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
    private let errorLabel = NSTextField(labelWithString: "")
    private weak var confirmButton: NSButton?
    private let excludingProfileId: String?

    init(confirmButton: NSButton,
         excludingProfileId: String?,
         placeholder: String,
         initialValue: String = "") {
        self.confirmButton = confirmButton
        self.excludingProfileId = excludingProfileId
        super.init()
        field.placeholderString = placeholder
        field.stringValue = initialValue
        field.delegate = self
        field.autoresizingMask = [.width]
        errorLabel.frame = NSRect(x: 0, y: 0, width: 240, height: 16)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.autoresizingMask = [.width]
        accessory.addSubview(field)
        accessory.addSubview(errorLabel)
        revalidate()
    }

    /// The field's trimmed contents — what the caller should persist.
    var trimmedValue: String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which prompt to present — `create` for a brand-new profile, `rename` for
    /// an existing one (its own name is excluded from the duplicate check and
    /// pre-filled for editing).
    enum Mode {
        case create
        case rename(currentName: String, profileId: String)
    }

    /// Presents the shared create/rename name alert modally and returns the
    /// confirmed, trimmed name — or nil if the user cancelled. Centralizes the
    /// `NSAlert` + field wiring that every create entry point and rename would
    /// otherwise duplicate. The live validator greys out the confirm button on an
    /// empty/duplicate name; `ProfileManager` re-checks uniqueness at submit time.
    static func present(_ mode: Mode) -> String? {
        // Pull the latest profile list before the live validator reads it: the
        // singleton can still be empty if it was first touched before the
        // Chromium bridge came up, which would let an existing name pass the
        // inline check and then fail silently at submit time. refresh() is sync.
        ProfileManager.shared.refresh()
        let alert = NSAlert()
        let validator: ProfileNameFieldValidator
        switch mode {
        case .create:
            alert.messageText = NSLocalizedString("settings.profiles.createDialog.title", value: "New Profile", comment: "Title of the create-profile dialog")
            alert.informativeText = NSLocalizedString("settings.profiles.createDialog.message", value: "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
                comment: "Body of the create-profile dialog")
            alert.addButton(withTitle: NSLocalizedString("settings.profiles.createDialog.createButton", value: "Create", comment: "Create button"))
            alert.addButton(withTitle: NSLocalizedString("settings.profiles.createDialog.cancelButton", value: "Cancel", comment: "Cancel button"))
            validator = ProfileNameFieldValidator(
                confirmButton: alert.buttons[0],
                excludingProfileId: nil,
                placeholder: NSLocalizedString("settings.profiles.nameField.placeholder", value: "Profile name", comment: "Placeholder for the profile-name field"))
        case let .rename(currentName, profileId):
            alert.messageText = NSLocalizedString("settings.profiles.renameDialog.title", value: "Rename Profile", comment: "Title of the rename-profile dialog")
            alert.informativeText = NSLocalizedString("settings.profiles.renameDialog.message", value: "Enter a new name for this profile.", comment: "Body of the rename-profile dialog")
            alert.addButton(withTitle: NSLocalizedString("settings.profiles.renameDialog.renameButton", value: "Rename", comment: "Rename button"))
            alert.addButton(withTitle: NSLocalizedString("settings.profiles.renameDialog.cancelButton", value: "Cancel", comment: "Cancel button"))
            validator = ProfileNameFieldValidator(
                confirmButton: alert.buttons[0],
                excludingProfileId: profileId,
                placeholder: currentName,
                initialValue: currentName)
        }
        alert.accessoryView = validator.accessory
        DispatchQueue.main.async {
            validator.field.window?.makeFirstResponder(validator.field)
            if case .rename = mode { validator.field.selectText(nil) }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return validator.trimmedValue
    }

    /// Greys out the confirm button unless the name is non-empty and unique, and
    /// shows the inline red message only on a duplicate.
    private func revalidate() {
        let trimmed = trimmedValue
        if trimmed.isEmpty {
            errorLabel.stringValue = ""
            confirmButton?.isEnabled = false
        } else if ProfileManager.shared.displayNameExists(trimmed, excluding: excludingProfileId) {
            errorLabel.stringValue = NSLocalizedString("settings.profiles.nameField.duplicateError", value: "A profile with this name already exists.",
                comment: "Validation shown when a new or renamed profile name duplicates an existing profile")
            confirmButton?.isEnabled = false
        } else {
            errorLabel.stringValue = ""
            confirmButton?.isEnabled = true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        revalidate()
    }
}
