// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// Compact Kiosk presentation: profile and page controls around one Chromium view.
final class KioskBrowserContentViewController: NSViewController {
    private enum Layout {
        static let panelSpacing: CGFloat = 8
        static let panelInset: CGFloat = 8
    }

    private let state: KioskBrowserState
    private let toolbarView: KioskBrowserToolbar
    private let webContentHost = NSView()
    private var profileReplacementSnapshotView: NSImageView?
    private var profileReplacementSnapshotRemovalWorkItem: DispatchWorkItem?
    private var extensionSidePanelView: ExtensionSidePanelView?
    private var extensionSidePanelPreferredWidth: CGFloat = 400
    private var stateCancellables = Set<AnyCancellable>()
    private var tabCancellables = Set<AnyCancellable>()

    init(state: KioskBrowserState) {
        self.state = state
        toolbarView = KioskBrowserToolbar(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        webContentHost.wantsLayer = true
        webContentHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        view.addSubview(toolbarView)
        view.addSubview(webContentHost)

        toolbarView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(KioskBrowserToolbar.preferredHeight)
        }
        remakeContentLayout()

        bindState()
    }

    func configureActions(
        onProfileSelection: @escaping (String) -> Void,
        onSpaceSelection: @escaping (String) -> Void,
        onOmniBoxRequest: @escaping () -> Void
    ) {
        toolbarView.configureActions(
            onProfileSelection: onProfileSelection,
            onSpaceSelection: onSpaceSelection,
            onOmniBoxRequest: onOmniBoxRequest
        )
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

    private func bindState() {
        bind(tab: state.focusingTab)
        state.$focusingTab
            .dropFirst()
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
        toolbarView.updateCanGoBack(tab?.canGoBack ?? false)
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
        tab.$canGoBack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoBack in
                self?.toolbarView.updateCanGoBack(canGoBack)
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
        toolbarView.updateAddress(with: url)
    }

    var addressBarAnchorView: NSView {
        toolbarView.addressBarAnchorView
    }

    var extensionSidePanelViewForTesting: ExtensionSidePanelView? {
        extensionSidePanelView
    }

    var isBackButtonVisibleForTesting: Bool {
        toolbarView.isBackButtonVisibleForTesting
    }
}
