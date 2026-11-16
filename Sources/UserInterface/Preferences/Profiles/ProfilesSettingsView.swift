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
/// for each profile's Space count and the delete guard. Renaming happens in the
/// row itself (`InlineRenameField`): the pencil, a double-click, or Enter on the
/// selected row starts it.
struct ProfilesSettingsView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    @State private var selectedProfileId: String?
    /// The profile whose name is being edited in place, and the field's text.
    @State private var renamingProfileId: String?
    @State private var renameDraft = ""
    @FocusState private var isListFocused: Bool

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

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(profileManager.profiles) { profile in
                            profileListRow(profile)
                                .id(profile.profileId)
                        }
                    }
                    .padding(6)
                }
                // Finder-style list keys: Enter renames the selected profile,
                // the arrows move the selection. The rename field consumes
                // these itself while it is editing.
                .focusable()
                .focusEffectDisabled()
                .focused($isListFocused)
                .onKeyPress(.return) {
                    guard renamingProfileId == nil, let profile = selectedProfile else { return .ignored }
                    beginRename(profile)
                    return .handled
                }
                .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
                .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
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

    @ViewBuilder
    private func profileListRow(_ profile: PhiBrowserProfile) -> some View {
        if renamingProfileId == profile.profileId {
            profileRenameRow(profile)
        } else {
            profileDisplayRow(profile)
        }
    }

    private func profileDisplayRow(_ profile: PhiBrowserProfile) -> some View {
        let isSelected = profile.profileId == selectedProfileId
        return Button {
            select(profile.profileId)
        } label: {
            HStack(spacing: 6) {
                Text(profile.displayName)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .lineLimit(1)
                profileRowTrailing(profile)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Simultaneous, so the single click still selects at once with no
        // double-click delay.
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(profile) })
    }

    private func profileRenameRow(_ profile: PhiBrowserProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                InlineRenameField(
                    initialText: profile.displayName,
                    onTextChange: { renameDraft = $0 },
                    onSubmit: { commitRename(profile, text: $0) },
                    onCancel: { endRename(profile.profileId) }
                )
                .frame(maxWidth: .infinity)
                profileRowTrailing(profile)
            }
            if let error = renameError(for: profile) {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func profileRowTrailing(_ profile: PhiBrowserProfile) -> some View {
        let count = spaceManager.spaces.filter { $0.profileId == profile.profileId }.count
        if profile.profileId == LocalStore.defaultProfileId {
            SettingsDefaultBadge()
        }
        Spacer(minLength: 4)
        Text(count == 0
             ? NSLocalizedString("settings.profiles.unusedStatus", value: "Not used", comment: "Profiles settings - tag for a profile with no Spaces")
             : Self.spaceCountLabel(count))
            .font(.system(size: 11))
            .themedForeground(.textSecondary)
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
        // Local references AND account references: once Spaces sync, a Profile
        // referenced only by a Space that lives on another Mac would look
        // deletable (§9.4).
        guard !spaceManager.isProfileInUse(profile.profileId) else { return false }
        return !PhiSpaceSyncState.shared.blocksProfileDeletion(localProfileId: profile.profileId)
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
        // Selecting another row cancels an edit in progress.
        if renamingProfileId != profileId { renamingProfileId = nil }
        selectedProfileId = profileId
        isListFocused = true
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard renamingProfileId == nil else { return .ignored }
        let ids = profileManager.profiles.map(\.profileId)
        guard !ids.isEmpty else { return .ignored }
        let current = selectedProfileId.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = min(max(current + offset, 0), ids.count - 1)
        select(ids[next])
        proxy.scrollTo(ids[next])
        return .handled
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
        beginRename(profile)
    }

    private func newProfile() {
        guard let name = ProfileNameFieldValidator.presentCreate() else { return }
        profileManager.createProfile(displayName: name) { newId in
            if let newId { select(newId) }
        }
    }

    // MARK: - Rename in place

    private func beginRename(_ profile: PhiBrowserProfile) {
        // Pull the latest profile list before the duplicate check reads it (see
        // `ProfileNameFieldValidator.presentCreate`); refresh() is sync.
        profileManager.refresh()
        selectedProfileId = profile.profileId
        renameDraft = profile.displayName
        renamingProfileId = profile.profileId
    }

    /// Ends the edit of `profileId` only: a field torn down because another
    /// row started editing must not end that row's edit.
    private func endRename(_ profileId: String) {
        guard renamingProfileId == profileId else { return }
        renamingProfileId = nil
        isListFocused = true
    }

    /// The inline red message under the field: only a duplicate shows one. An
    /// empty name shows nothing, it just can't be saved.
    private func renameError(for profile: PhiBrowserProfile) -> String? {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              profileManager.displayNameExists(trimmed, excluding: profile.profileId) else { return nil }
        return ProfileNameFieldValidator.duplicateNameMessage
    }

    /// Enter in the field. Returns false, keeping the field open, while the
    /// name is empty or a duplicate; `ProfileManager` re-checks uniqueness.
    private func commitRename(_ profile: PhiBrowserProfile, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !profileManager.displayNameExists(trimmed, excluding: profile.profileId) else { return false }
        endRename(profile.profileId)
        guard trimmed != profile.displayName else { return true }
        profileManager.renameProfile(profile.profileId, to: trimmed) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("settings.profiles.renameFailure.title", value: "Couldn't rename profile", comment: "Title of the profile-rename error")
                errAlert.informativeText = error ?? NSLocalizedString("settings.profiles.renameFailure.unknownError", value: "Unknown error", comment: "Fallback profile-rename error reason")
                errAlert.runModal()
            }
        }
        return true
    }

    private func deleteProfile(_ profile: PhiBrowserProfile) {
        ProfileDeletionFlow.confirmAndDelete(profile)
    }
}

/// Live validator for the new-profile name field inside an `NSAlert`. Owns the
/// field and a vertical accessory (field above, an inline red message below) and
/// keeps the alert's confirm button greyed out until the trimmed name is
/// non-empty and unique. Errors appear inline without the alert flickering.
/// Shared by every create entry point (Phi menu / Profiles settings /
/// create-Space); renaming happens in place in the Profiles settings list. An
/// empty field just disables confirm — no red message until the user types a
/// duplicate.
///
/// The caller must keep the instance alive for the modal's lifetime; a local
/// `let` across `runModal()` suffices (`NSTextField.delegate` is weak).
final class ProfileNameFieldValidator: NSObject, NSTextFieldDelegate {
    let field = NSTextField(frame: NSRect(x: 0, y: 20, width: 240, height: 24))
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
    private let errorLabel = NSTextField(labelWithString: "")
    private weak var confirmButton: NSButton?

    /// The inline message for a name another profile already uses — shown by
    /// this prompt and by the in-place rename in Profiles settings.
    static var duplicateNameMessage: String {
        NSLocalizedString("settings.profiles.nameField.duplicateError", value: "A profile with this name already exists.",
            comment: "Validation shown when a new or renamed profile name duplicates an existing profile")
    }

    init(confirmButton: NSButton, placeholder: String) {
        self.confirmButton = confirmButton
        super.init()
        field.placeholderString = placeholder
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

    /// Presents the new-profile name alert modally and returns the confirmed,
    /// trimmed name — or nil if the user cancelled. Centralizes the `NSAlert` +
    /// field wiring that every create entry point would otherwise duplicate. The
    /// live validator greys out the confirm button on an empty/duplicate name;
    /// `ProfileManager` re-checks uniqueness at submit time.
    static func presentCreate() -> String? {
        // Pull the latest profile list before the live validator reads it: the
        // singleton can still be empty if it was first touched before the
        // Chromium bridge came up, which would let an existing name pass the
        // inline check and then fail silently at submit time. refresh() is sync.
        ProfileManager.shared.refresh()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("settings.profiles.createDialog.title", value: "New Profile", comment: "Title of the create-profile dialog")
        alert.informativeText = NSLocalizedString("settings.profiles.createDialog.message", value: "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
            comment: "Body of the create-profile dialog")
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.createDialog.createButton", value: "Create", comment: "Create button"))
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.createDialog.cancelButton", value: "Cancel", comment: "Cancel button"))
        let validator = ProfileNameFieldValidator(
            confirmButton: alert.buttons[0],
            placeholder: NSLocalizedString("settings.profiles.nameField.placeholder", value: "Profile name", comment: "Placeholder for the profile-name field"))
        alert.accessoryView = validator.accessory
        DispatchQueue.main.async {
            validator.field.window?.makeFirstResponder(validator.field)
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
        } else if ProfileManager.shared.displayNameExists(trimmed, excluding: nil) {
            errorLabel.stringValue = Self.duplicateNameMessage
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
