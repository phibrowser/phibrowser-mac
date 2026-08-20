// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// Compact Kiosk presentation: profile and page controls around one Chromium view.
final class KioskBrowserContentViewController: NSViewController, NSTextFieldDelegate {
    private enum Layout {
        static let toolbarHeight: CGFloat = 52
        static let trafficLightInset: CGFloat = 78
        static let toolbarVerticalOffset: CGFloat = 4
        static let addressBarHeight: CGFloat = 32
        static let spaceMenuWidth: CGFloat = 176
        static let panelSpacing: CGFloat = 8
        static let panelInset: CGFloat = 8
    }

    private let state: KioskBrowserState
    private let toolbarView = NSVisualEffectView()
    private let addressBarContainer = NSView()
    private let addressField = NSTextField()
    private let webContentHost = NSView()
    private var profileReplacementSnapshotView: NSImageView?
    private var profileReplacementSnapshotRemovalWorkItem: DispatchWorkItem?
    private var extensionSidePanelView: ExtensionSidePanelView?
    private var extensionSidePanelPreferredWidth: CGFloat = 400
    private var stateCancellables = Set<AnyCancellable>()
    private var tabCancellables = Set<AnyCancellable>()

    private var onProfileSelection: ((String) -> Void)?
    private var onSpaceSelection: ((String) -> Void)?

    private lazy var profileHostingView = NSHostingView(
        rootView: KioskProfileMenu(
            currentProfileId: state.profileId,
            onSelect: { [weak self] profileId in
                self?.onProfileSelection?(profileId)
            }
        )
    )

    private lazy var toolbarActionsHostingView = NSHostingView(
        rootView: KioskToolbarActions(
            state: state,
            onReload: { [weak self] in
                self?.state.focusingTab?.reload()
            }
        )
    )

    private lazy var spaceHostingView = NSHostingView(
        rootView: KioskSpaceMenu(
            state: state,
            onSelect: { [weak self] spaceId in
                self?.onSpaceSelection?(spaceId)
            }
        )
    )

    init(state: KioskBrowserState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        toolbarView.material = .headerView
        toolbarView.blendingMode = .withinWindow
        toolbarView.state = .active

        addressBarContainer.wantsLayer = true
        addressBarContainer.layer?.cornerCurve = .continuous
        addressBarContainer.layer?.cornerRadius = 9
        addressBarContainer.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.55)
            .cgColor
        addressBarContainer.layer?.borderWidth = 0.5
        addressBarContainer.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.28)
            .cgColor

        addressField.placeholderString = NSLocalizedString(
            "addressBar.input.placeholder",
            value: "Search or Enter URL",
            comment: "Address bar - Text field placeholder prompting the user to search or enter a URL"
        )
        addressField.font = .systemFont(ofSize: 13)
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.alignment = .center
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(submitAddress(_:))

        webContentHost.wantsLayer = true
        webContentHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        view.addSubview(toolbarView)
        toolbarView.addSubview(addressBarContainer)
        addressBarContainer.addSubview(profileHostingView)
        addressBarContainer.addSubview(addressField)
        addressBarContainer.addSubview(toolbarActionsHostingView)
        toolbarView.addSubview(spaceHostingView)
        view.addSubview(webContentHost)

        toolbarView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Layout.toolbarHeight)
        }
        spaceHostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.centerY.equalToSuperview().offset(Layout.toolbarVerticalOffset)
            make.width.equalTo(Layout.spaceMenuWidth)
            make.height.equalTo(34)
        }
        addressBarContainer.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Layout.trafficLightInset)
            make.trailing.equalTo(spaceHostingView.snp.leading).offset(-8)
            make.centerY.equalToSuperview().offset(Layout.toolbarVerticalOffset)
            make.height.equalTo(Layout.addressBarHeight)
        }
        profileHostingView.setContentHuggingPriority(.required, for: .horizontal)
        profileHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profileHostingView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(5)
            make.centerY.equalToSuperview()
            make.height.equalTo(26)
            make.width.lessThanOrEqualTo(138)
        }
        toolbarActionsHostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(5)
            make.centerY.equalToSuperview()
            make.width.equalTo(52)
            make.height.equalTo(26)
        }
        addressField.snp.makeConstraints { make in
            make.leading.equalTo(profileHostingView.snp.trailing).offset(6)
            make.trailing.equalTo(toolbarActionsHostingView.snp.leading).offset(-6)
            make.centerY.equalToSuperview()
            make.height.equalTo(24)
        }
        remakeContentLayout()

        bindState()
        state.extensionManager.refreshExtensions()
    }

    func configureActions(
        onProfileSelection: @escaping (String) -> Void,
        onSpaceSelection: @escaping (String) -> Void
    ) {
        self.onProfileSelection = onProfileSelection
        self.onSpaceSelection = onSpaceSelection
    }

    func focusAddressBar(clearContents: Bool = false) {
        guard let window = view.window else { return }
        window.makeFirstResponder(addressField)
        if clearContents {
            addressField.stringValue = ""
        } else {
            addressField.stringValue = editableAddressText(
                for: state.focusingTab?.url
            )
        }
        addressField.selectText(nil)
    }

    func handlePreviousTabReadyForCleanup(tabId: Int) {
        guard state.focusingTab?.guid != tabId else { return }
        mountFocusedTab()
    }

    func handleTabReadyToDisplay(tabId: Int) {
        guard state.focusingTab?.guid == tabId else { return }
        mountFocusedTab()
    }

    func captureProfileReplacementSnapshot() -> NSImage? {
        guard isViewLoaded,
              view.window?.isVisible == true else { return nil }
        view.layoutSubtreeIfNeeded()
        return WebContentSnapshotter.captureOnScreen(
            webContentHost,
            resolution: .bestResolution
        )
    }

    func showProfileReplacementSnapshot(_ image: NSImage) {
        guard isViewLoaded else { return }
        clearProfileReplacementSnapshot()

        let snapshotView = NSImageView(image: image)
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.imageAlignment = .alignTopLeft
        snapshotView.wantsLayer = true
        snapshotView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        profileReplacementSnapshotView = snapshotView
        view.addSubview(
            snapshotView,
            positioned: .above,
            relativeTo: webContentHost
        )
        snapshotView.snp.makeConstraints { make in
            make.edges.equalTo(webContentHost)
        }
        view.layoutSubtreeIfNeeded()
    }

    func dismissProfileReplacementSnapshot(
        after delay: TimeInterval,
        duration: TimeInterval
    ) {
        profileReplacementSnapshotRemovalWorkItem?.cancel()
        guard let snapshotView = profileReplacementSnapshotView else { return }

        let workItem = DispatchWorkItem { [weak self, weak snapshotView] in
            guard let self, let snapshotView,
                  self.profileReplacementSnapshotView === snapshotView else {
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(
                    name: .easeOut
                )
                snapshotView.animator().alphaValue = 0
            } completionHandler: { [weak self, weak snapshotView] in
                DispatchQueue.main.async {
                    guard let self, let snapshotView,
                          self.profileReplacementSnapshotView === snapshotView else {
                        return
                    }
                    self.clearProfileReplacementSnapshot()
                }
            }
        }
        profileReplacementSnapshotRemovalWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func clearProfileReplacementSnapshot() {
        profileReplacementSnapshotRemovalWorkItem?.cancel()
        profileReplacementSnapshotRemovalWorkItem = nil
        profileReplacementSnapshotView?.removeFromSuperview()
        profileReplacementSnapshotView = nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        addressField.alignment = .center
        updateAddressField(with: state.focusingTab?.url)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        addressField.alignment = .left
        addressField.stringValue = editableAddressText(
            for: state.focusingTab?.url
        )
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === addressField else { return false }

        if commandSelector == #selector(NSTextView.insertNewline(_:)) ||
            commandSelector == #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)) {
            // AppKit ends editing before sending NSTextField's action. Capture
            // the field editor text before controlTextDidEndEditing restores
            // the last committed URL.
            submitAddress(input: textView.string)
            return true
        }

        return false
    }

    private func bindState() {
        state.$focusingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                self?.bind(tab: tab)
            }
            .store(in: &stateCancellables)

        // Synchronous by design. Chromium may destroy an outgoing side-panel
        // NSView immediately after the bridge event returns, so Kiosk must
        // detach it in the same turn, just like the regular content container.
        state.$extensionSidePanel
            .sink { [weak self] panel in
                if let panel {
                    self?.attachExtensionSidePanel(panel)
                } else {
                    self?.detachExtensionSidePanel()
                }
            }
            .store(in: &stateCancellables)
    }

    private func bind(tab: Tab?) {
        tabCancellables.removeAll()
        mountFocusedTab()
        updateAddressField(with: tab?.url)
        view.window?.title = tab?.title ?? ""

        guard let tab else { return }
        tab.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.updateAddressField(with: url)
            }
            .store(in: &tabCancellables)
        tab.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.view.window?.title = title
            }
            .store(in: &tabCancellables)
    }

    private func mountFocusedTab() {
        guard isViewLoaded else { return }
        let focusedView = state.focusingTab?.webContentView
        for subview in webContentHost.subviews where subview !== focusedView {
            subview.removeFromSuperview()
        }
        guard let focusedView else { return }
        if focusedView.superview !== webContentHost {
            focusedView.removeFromSuperview()
            webContentHost.addSubview(focusedView)
        }
        focusedView.isHidden = false
        focusedView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        ChromiumLauncher.sharedInstance().bridge?
            .confirmViewSwitchCompleted(Int64(state.windowId))
    }

    private func attachExtensionSidePanel(
        _ panel: BrowserState.ExtensionSidePanelState
    ) {
        guard let nativeView = panel.wrapper.nativeView else {
            AppLogWarn("[Kiosk] Extension side panel has no native view")
            return
        }

        let isFreshOpen = extensionSidePanelView == nil
        let panelView: ExtensionSidePanelView
        if let existing = extensionSidePanelView {
            panelView = existing
        } else {
            panelView = ExtensionSidePanelView(
                initialWidth: extensionSidePanelPreferredWidth
            )
            panelView.onCloseRequested = { [weak self] in
                self?.state.requestExtensionSidePanelClose()
            }
            extensionSidePanelView = panelView
            view.addSubview(panelView)
            remakeContentLayout()
        }

        panelView.updateHeader(
            displayName: panel.displayName,
            iconPNG: panel.iconPNG
        )
        if nativeView.superview !== panelView.contentHostView {
            nativeView.removeFromSuperview()
            panelView.contentHostView.addSubview(nativeView)
            nativeView.translatesAutoresizingMaskIntoConstraints = false
            nativeView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        if isFreshOpen {
            nativeView.window?.makeFirstResponder(nativeView)
            if panel.wrapper.responds(to: #selector(WebContentWrapper.focus)) {
                panel.wrapper.focus()
            }
        }
    }

    private func detachExtensionSidePanel() {
        guard let panelView = extensionSidePanelView else { return }
        extensionSidePanelPreferredWidth = panelView.preferredWidth
        for subview in panelView.contentHostView.subviews {
            subview.removeFromSuperview()
        }
        extensionSidePanelView = nil
        panelView.removeFromSuperview()
        remakeContentLayout()

        // Match the regular content host: the close event originates in a
        // synchronous Chromium callback, so restore page focus on the next turn
        // and only when no other native control has claimed it.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.extensionSidePanelView == nil,
                  let window = self.view.window,
                  window.firstResponder == nil || window.firstResponder === window,
                  let tab = self.state.focusingTab,
                  let focusedView = tab.webContentView,
                  window.makeFirstResponder(focusedView) else { return }
            if tab.isNTP {
                tab.webContentWrapper?.focus()
            } else {
                tab.webContentWrapper?.restoreFocus()
            }
        }
    }

    private func remakeContentLayout() {
        webContentHost.snp.remakeConstraints { make in
            make.top.equalTo(toolbarView.snp.bottom)
            make.leading.bottom.equalToSuperview()
            if let extensionSidePanelView {
                make.trailing.equalTo(extensionSidePanelView.snp.leading)
                    .offset(-Layout.panelSpacing)
            } else {
                make.trailing.equalToSuperview()
            }
        }

        extensionSidePanelView?.snp.remakeConstraints { make in
            make.top.equalTo(toolbarView.snp.bottom).offset(Layout.panelInset)
            make.trailing.bottom.equalToSuperview().inset(Layout.panelInset)
        }
    }

    private func updateAddressField(with url: String?) {
        if let editor = addressField.currentEditor(),
           view.window?.firstResponder === editor {
            return
        }
        addressField.stringValue = displayAddressText(for: url)
    }

    private func displayAddressText(for url: String?) -> String {
        guard let url, !url.isEmpty, !url.isNTP else { return "" }
        return URLProcessor.displayName(
            for: URLProcessor.phiBrandEnsuredUrlString(url)
        )
    }

    private func editableAddressText(for url: String?) -> String {
        url.map(URLProcessor.phiBrandEnsuredUrlString) ?? ""
    }

    @objc private func submitAddress(_ sender: NSTextField) {
        submitAddress(input: sender.stringValue)
    }

    private func submitAddress(input: String) {
        guard let tab = state.focusingTab else { return }
        state.navigateCurrentWebContents(to: input)
        guard let webContentView = tab.webContentView,
              view.window?.makeFirstResponder(webContentView) == true else {
            return
        }
        if tab.isNTP {
            tab.webContentWrapper?.focus()
        } else {
            tab.webContentWrapper?.restoreFocus()
        }
    }

    var extensionSidePanelViewForTesting: ExtensionSidePanelView? {
        extensionSidePanelView
    }
}

private struct KioskProfileMenu: View {
    @ObservedObject private var profileManager: ProfileManager
    let currentProfileId: String
    let onSelect: (String) -> Void

    init(
        currentProfileId: String,
        profileManager: ProfileManager = .shared,
        onSelect: @escaping (String) -> Void
    ) {
        self.currentProfileId = currentProfileId
        self.profileManager = profileManager
        self.onSelect = onSelect
    }

    private var currentProfileName: String {
        profileManager.profile(for: currentProfileId)?.displayName
            ?? currentProfileId
    }

    var body: some View {
        Menu {
            ForEach(profileManager.userAssignableProfiles) { profile in
                Button {
                    onSelect(profile.profileId)
                } label: {
                    HStack {
                        Text(verbatim: profile.displayName)
                        if profile.profileId == currentProfileId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(profile.profileId == currentProfileId)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: currentProfileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(
            "kiosk.toolbar.profileMenu.accessibilityLabel",
            value: "Switch Profile",
            comment: "Kiosk toolbar - Accessibility label for the current-profile menu"
        ))
        .onAppear {
            profileManager.refresh()
        }
    }
}

private struct KioskToolbarActions: View {
    let state: KioskBrowserState
    let onReload: () -> Void

    @State private var isExtensionPopoverShown = false

    var body: some View {
        HStack(spacing: 2) {
            HeaderExtensionMenuButton(
                extensionManager: state.extensionManager,
                browserState: state,
                isPopoverShown: $isExtensionPopoverShown,
                showsManagement: false
            )
            CircularIconButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: NSLocalizedString(
                    "kiosk.toolbar.reloadPage.accessibilityLabel",
                    value: "Reload Page",
                    comment: "Kiosk toolbar - Accessibility label and tooltip for the reload button"
                ),
                action: onReload
            )
        }
        .frame(height: 26)
    }
}

private struct KioskSpaceMenu: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    let state: KioskBrowserState
    let onSelect: (String) -> Void

    private var availableSpaces: [SpaceModel] {
        guard !state.isIncognito,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else {
            return []
        }
        return spaceManager.spaces
    }

    private var title: String {
        NSLocalizedString(
            "kiosk.toolbar.openInSpace",
            value: "Open in Space",
            comment: "Kiosk toolbar - Menu that transfers the current page into a selected Space"
        )
    }

    var body: some View {
        Menu {
            ForEach(availableSpaces, id: \.spaceId) { space in
                Button {
                    onSelect(space.spaceId)
                } label: {
                    Label {
                        Text(verbatim: space.name)
                    } icon: {
                        SpaceIconView(
                            storedValue: space.iconName,
                            size: 13,
                            symbolWeight: .semibold,
                            tint: .primary
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(availableSpaces.isEmpty)
        .accessibilityLabel(title)
        .help(title)
    }
}
