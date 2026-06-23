// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Rich "Create a Space" panel. Replaces the bare name-only NSAlert that used
/// to back both the File menu and the Spaces picker's "New Space" row. Lets the
/// user name the Space, bind it to a profile, and pick an accent swatch before
/// committing.
///
/// Self-contained: the only side effect is `manager.createSpace(...)` on
/// confirm. Presented in a chrome-light floating window via `present(...)`,
/// which both entry points call so the window setup lives in one place.
struct CreateSpacePanel: View {
    enum Style {
        /// Floating window — used in the horizontal (Comfortable) layout and
        /// whenever no usable sidebar is available.
        case window
        /// Fills the sidebar in vertical (Performance / Balanced) layouts.
        case sidebar
    }

    var style: Style = .window
    @ObservedObject var manager: SpaceManager
    @ObservedObject var profileManager: ProfileManager
    /// Profile the picker opens on — the active Space's profile when reached
    /// from the sidebar, or the menu's active-window profile.
    let initialProfileId: String?
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var selectedProfileId: String = ""
    @State private var selectedSwatch: Int = 0
    @FocusState private var nameFocused: Bool

    /// Accent presets, lifted straight from the Figma swatch row. The first is
    /// a neutral white; the rest are the design's pastel hues.
    static let swatches: [String] = [
        "#FFFFFF", "#8DDA86", "#73DAE0", "#66CCFF",
        "#8682F6", "#DA7BE7", "#F5867B", "#F5D67B",
    ]
    private static let ringColor = Color(hexString: "#3AA4D5")
    private static let accentColor = Color(hexString: "#3AA4D5")

    var body: some View {
        styledContent
            .onAppear {
                selectedProfileId = resolvedInitialProfileId
                DispatchQueue.main.async { nameFocused = true }
            }
    }

    @ViewBuilder
    private var styledContent: some View {
        switch style {
        case .window:
            formStack
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(width: 300)
        case .sidebar:
            // Transparent so the themed visual-effect backdrop installed by
            // `SidebarViewController.showCreateSpaceOverlay` shows through —
            // the form then sits on the active Space's overlay color and
            // opacity instead of an opaque card that ignores the Space theme.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                formStack.padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    private var formStack: some View {
        VStack(spacing: 28) {
            header
            form
            actions
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Create a Space",
                comment: "Title of the create-Space panel"))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
            Text(NSLocalizedString("Each space has its own independent bookmarks",
                comment: "Subtitle of the create-Space panel"))
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(spacing: 4) {
            nameField
            profileRow
            colorBlock
        }
    }

    private var nameField: some View {
        TextField(
            NSLocalizedString("Space name", comment: "Placeholder for the Space-name field"),
            text: $name
        )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($nameFocused)
            .onSubmit(create)
            .frame(height: 32)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileRow: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("Profile",
                comment: "Label for the profile picker in the create-Space panel"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 0)
            profilePill
        }
        .frame(height: 32)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profilePill: some View {
        Menu {
            ForEach(profileManager.profiles, id: \.profileId) { profile in
                Button(profile.displayName) { selectedProfileId = profile.profileId }
            }
            Divider()
            Button {
                promptCreateProfile()
            } label: {
                Label(NSLocalizedString("New Profile\u{2026}",
                    comment: "Profile picker item to create a new profile"),
                    systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedProfileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var colorBlock: some View {
        swatchRow
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var swatchRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.swatches.enumerated()), id: \.offset) { index, hex in
                swatch(index: index, hex: hex)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func swatch(index: Int, hex: String) -> some View {
        let isSelected = index == selectedSwatch
        return Circle()
            .fill(Color(hexString: hex))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Self.ringColor, lineWidth: 1.5).padding(-3)
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                selectedSwatch = index
            }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: create) {
                Text(NSLocalizedString("Create Space",
                    comment: "Confirm button in the create-Space panel"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Self.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Text(NSLocalizedString("Cancel", comment: "Cancel button"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Color math

    /// The Space's color is the selected accent swatch as shown — no shading.
    private func resolvedColorHex() -> String {
        Self.swatches[selectedSwatch]
    }

    // MARK: - Profiles

    private var resolvedInitialProfileId: String {
        if let id = initialProfileId,
           profileManager.profiles.contains(where: { $0.profileId == id }) {
            return id
        }
        return profileManager.profiles.first?.profileId ?? LocalStore.defaultProfileId
    }

    private var selectedProfileName: String {
        profileManager.profile(for: selectedProfileId)?.displayName ?? selectedProfileId
    }

    /// Prompts for a name and creates a new profile, selecting it for this
    /// Space once the bridge reports the new id. Mirrors the menu's
    /// `newProfile` flow so both entry points behave identically.
    private func promptCreateProfile() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("New Profile",
            comment: "Title of the create-profile dialog")
        alert.informativeText = NSLocalizedString(
            "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
            comment: "Body of the create-profile dialog")
        alert.addButton(withTitle: NSLocalizedString("Create", comment: "Create button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = NSLocalizedString("Profile name",
            comment: "Placeholder for the profile-name field")
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profileManager.createProfile(displayName: trimmed) { newId in
            if let newId { selectedProfileId = newId }
        }
    }

    // MARK: - Commit

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? String(format: NSLocalizedString("Space %d",
                comment: "Default name for a newly created Space"),
                manager.spaces.count + 1)
            : trimmed
        let profileId = selectedProfileId.isEmpty ? resolvedInitialProfileId : selectedProfileId
        let newSpaceId = manager.createSpace(
            name: finalName,
            colorHex: resolvedColorHex(),
            iconName: "rectangle.stack",
            profileId: profileId
        )
        onClose()
        // Bring the freshly created Space to the front of the active window.
        // `createSpace` only records it as the persisted default, so without
        // this the current window would stay on the Space we created from — in
        // both the sidebar (vertical) and floating-panel (horizontal) flows.
        // Runs after `onClose` so the overlay / panel is torn down first and the
        // switch animation plays over the revealed sidebar rather than under it.
        if let newSpaceId {
            manager.activateInFocusedWindow(spaceId: newSpaceId)
        }
    }
}

// MARK: - Presentation

extension CreateSpacePanel {
    private static let windowIdentifier = "Phi Create Space"

    /// Single entry point for "New Space" from the menu or the Spaces picker.
    /// Vertical layouts (Performance / Balanced) show the form inline in the
    /// sidebar; the horizontal layout (Comfortable) — or any window without a
    /// usable sidebar — falls back to the floating window.
    static func requestCreation(initialProfileId: String?) {
        if let wc = MainBrowserWindowControllersManager.shared.activeWindowController,
           !wc.browserState.layoutMode.isTraditional {
            let sidebar = wc.mainSplitViewController.sidebarViewController
            if sidebar.isViewLoaded, sidebar.view.window != nil, sidebar.view.bounds.width > 120 {
                sidebar.showCreateSpaceOverlay(initialProfileId: initialProfileId)
                return
            }
        }
        present(manager: .shared, initialProfileId: initialProfileId)
    }

    /// Brings up the create-Space panel in a single shared, chrome-light
    /// window. Reuses an already-open window so repeated invocations from the
    /// menu or the picker don't stack duplicates.
    @discardableResult
    static func present(manager: SpaceManager,
                        profileManager: ProfileManager = .shared,
                        initialProfileId: String?) -> NSWindow {
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue == windowIdentifier
        }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let panel = CreateSpacePanel(
            manager: manager,
            profileManager: profileManager,
            initialProfileId: initialProfileId
        ) { [weak window] in
            window?.close()
        }
        let hosting = ThemedHostingController(rootView: panel)
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}
