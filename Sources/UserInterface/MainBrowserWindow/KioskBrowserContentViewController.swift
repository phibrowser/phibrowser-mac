// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// Minimal Kiosk presentation: a native address field above one Chromium view.
final class KioskBrowserContentViewController: NSViewController, NSTextFieldDelegate {
    private enum Layout {
        static let toolbarHeight: CGFloat = 52
        static let trafficLightInset: CGFloat = 78
    }

    private let state: KioskBrowserState
    private let toolbarView = NSVisualEffectView()
    private let addressField = NSTextField()
    private let webContentHost = NSView()
    private var stateCancellables = Set<AnyCancellable>()
    private var tabCancellables = Set<AnyCancellable>()

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

        addressField.placeholderString = NSLocalizedString(
            "addressBar.input.placeholder",
            value: "Search or Enter URL",
            comment: "Address bar - Text field placeholder prompting the user to search or enter a URL"
        )
        addressField.font = .systemFont(ofSize: 13)
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(submitAddress(_:))

        webContentHost.wantsLayer = true
        webContentHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        view.addSubview(toolbarView)
        toolbarView.addSubview(addressField)
        view.addSubview(webContentHost)

        toolbarView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Layout.toolbarHeight)
        }
        addressField.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Layout.trafficLightInset)
            make.trailing.equalToSuperview().inset(14)
            make.centerY.equalToSuperview().offset(4)
            make.height.equalTo(28)
        }
        webContentHost.snp.makeConstraints { make in
            make.top.equalTo(toolbarView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        bindState()
    }

    func focusAddressBar(clearContents: Bool = false) {
        guard let window = view.window else { return }
        if clearContents {
            addressField.stringValue = ""
        }
        window.makeFirstResponder(addressField)
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

    func controlTextDidEndEditing(_ obj: Notification) {
        updateAddressField(with: state.focusingTab?.url)
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

    private func updateAddressField(with url: String?) {
        if let editor = addressField.currentEditor(),
           view.window?.firstResponder === editor {
            return
        }
        addressField.stringValue = url.map(URLProcessor.phiBrandEnsuredUrlString) ?? ""
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
}
