// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Combine
import SwiftUI

class SidebarHeaderView: NSView, TitlebarAwareHitTestable {
    private lazy var cancellables = Set<AnyCancellable>()
    private var sidebarButtonLeftConstraint: Constraint?
    private var upgradeButtonLeftConstraint: Constraint?
    private var addressViewHeightConstraint: Constraint?
    private let defaultSidebarButtonTopOffset: CGFloat = 8
    private let legacySidebarButtonTopOffset: CGFloat = 15.5
    private let addressViewHeight: CGFloat = 32
    private var sidebarButtonLeftOffset: CGFloat = 78
    private var layoutSettleCancellable: AnyCancellable?
    /// Currently available app update version.
    private var availableUpdateVersion: String?
    private var currentWidth: CGFloat = 0
    
    private var isFloating: Bool = false
    
    private lazy var sidebarButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(image: .leftSidebarToggle,
//                                           imageSize: .init(width: 18, height: 13),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(sidebarButtonClicked))
        return button
    }()

    private lazy var upgradeButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(
            title: NSLocalizedString("Update", comment: "Sidebar header upgrade button title"),
            displayMode: .titleOnly,
            backgroundColor: .themeColor,
            hoverBackgroundColor: .themeColorOnHover,
            titleColor: .custom(light: .white, dark: .white),
            titleFont: .system(size: 11, weight: .medium),
            edgeInsets: EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4),
            cornerRadius: 6
        )
        let button = HoverableButtonNSView(config: config) { [weak self] in
            self?.upgradeButtonClicked()
        }
        button.isHidden = true
        return button
    }()
    
    
    private lazy var backButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "chevron.left", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarBackward,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(backButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var forwardButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "chevron.right", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarForward,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(forwardButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var refreshButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "arrow.clockwise", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarReload,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(refreshButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var stopButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "xmark", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: image,
                                           imageSize: .init(width: 14, height: 14),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(stopButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        button.isHidden = true
        return button
    }()

    private lazy var stackView: NSStackView = {
        let stack = NSStackView(views: [backButton, forwardButton, refreshButton, stopButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        return stack
    }()
    
    
    private lazy var addressView: SideAddressBar = {
        let addressView = SideAddressBar()
        return addressView
    }()
    
    private weak var browserState: BrowserState?
    
    init(state: BrowserState?, isFloating: Bool = false) {
        self.browserState = state
        self.isFloating = isFloating
        super.init(frame: .zero)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    // MARK: - TitlebarAwareHitTestable
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        return false
    }
    
    private func setupViews() {
        let initialLayoutMode = browserState?.layoutMode ?? .performance
        let showInSidebar = isSidebarLayout(initialLayoutMode)

        addSubview(sidebarButton)
        addSubview(upgradeButton)

        sidebarButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(sidebarButtonTopOffset(for: showInSidebar))
            sidebarButtonLeftConstraint = make.left.equalToSuperview().offset(78).constraint
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        upgradeButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(defaultSidebarButtonTopOffset)
            upgradeButtonLeftConstraint = make.left.equalToSuperview().offset(sidebarButtonLeftOffset).constraint
            make.size.equalTo(NSSize(width: 56, height: 24))
        }
        
        addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.centerY.equalTo(sidebarButton)
            make.height.equalTo(24)
            make.right.equalToSuperview().inset(2)
        }
        
        addSubview(addressView)
        addressView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.top.equalTo(stackView.snp.bottom).offset(12)
            addressViewHeightConstraint = make.height.equalTo(addressViewHeight).constraint
        }

        updateLayoutVisibility(layoutMode: initialLayoutMode)
    }

    private func isSidebarLayout(_ layoutMode: LayoutMode) -> Bool {
        layoutMode == .performance
    }

    private func sidebarButtonTopOffset(for showInSidebar: Bool) -> CGFloat {
        if isFloating {
            return defaultSidebarButtonTopOffset
        }
        return showInSidebar ? defaultSidebarButtonTopOffset : legacySidebarButtonTopOffset
    }

    /// Update view visibility based on configuration
    private func updateLayoutVisibility(layoutMode: LayoutMode) {
        let showInSidebar = isSidebarLayout(layoutMode)
        AppLogDebug("[SidebarHeader] updateLayoutVisibility showInSidebar=\(showInSidebar)")

        // Default layout: navigation buttons and address bar in sidebar
        stackView.isHidden = !showInSidebar
        addressView.isHidden = !showInSidebar

        // Update addressView height constraint
        addressViewHeightConstraint?.update(offset: showInSidebar ? addressViewHeight : 0)

        // Adjust sidebarButton position
        sidebarButton.snp.remakeConstraints { make in
            make.top.equalToSuperview().offset(sidebarButtonTopOffset(for: showInSidebar))
            make.size.equalTo(NSSize(width: 24, height: 24))

            if showInSidebar {
                // Default layout: sidebarButton on left (after traffic light buttons)
                AppLogDebug("[SidebarHeader] updateLayoutVisibility apply default constraints offset=\(sidebarButtonLeftOffset)")
                sidebarButtonLeftConstraint = make.left.equalToSuperview().offset(sidebarButtonLeftOffset).constraint
            } else {
                // Legacy layout: sidebarButton aligned right
                AppLogDebug("[SidebarHeader] updateLayoutVisibility apply legacy constraints")
                make.right.equalToSuperview().inset(5)
            }
        }

        // In default layout mode, update sidebarButton left position based on window buttons
        if showInSidebar {
            scheduleSidebarButtonUpdateAfterLayoutChange()
        }

        updateUpgradeAndSidebarVisibility(layoutMode: layoutMode)
    }

    /// Observe configuration changes
    private func setupConfigObserver() {
        guard let browserState else {
            return
        }
        browserState.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink {  [weak self] mode in
                guard let self else {
                    return
                }
                updateLayoutVisibility(layoutMode: mode)
            }
            .store(in: &cancellables)
    }
    
    /// Returns the maxX of a standard window button (e.g. .zoomButton or .fullScreenButton)
    /// in the current view's coordinate space. If the button doesn't exist, returns nil.
    private func windowButtonMaxXRelativeToSelf(button type: NSWindow.ButtonType) -> CGFloat? {
        if isFloating || browserState?.isInFullScreenMode == true {
            return 0
        }
        
        guard let window, let btn = window.standardWindowButton(type) else { return nil }
        // Convert via window coordinates to avoid view-hierarchy mismatches during layout transitions.
        let rectInWindow = btn.convert(btn.bounds, to: nil)
        let rectInSelf = convert(rectInWindow, from: nil)
        AppLogDebug("[SidebarHeader] windowButtonMaxXRelativeToSelf type=\(type.rawValue) maxX=\(rectInSelf.maxX)")
        return rectInSelf.maxX
    }

    /// Updates the left constraint for `sidebarButton` based on the right edge of the window's
    /// green traffic-light button (zoom) or, if not available, the fullscreen button.
    private func updateSidebarButtonLeftConstraint() {
        // Prefer the zoom (green) button; fall back to the fullscreen button if needed
        let maxX = windowButtonMaxXRelativeToSelf(button: .zoomButton)
            ?? windowButtonMaxXRelativeToSelf(button: .closeButton)

        guard let x = maxX else {
            AppLogDebug("[SidebarHeader] updateSidebarButtonLeftConstraint maxX=nil (window buttons unavailable)")
            return
        }
        // Add a small padding (8pt) to keep some space from the system button group
        AppLogDebug("[SidebarHeader] updateSidebarButtonLeftConstraint update offset=\(x + 10)")
        sidebarButtonLeftOffset = x + 10
        sidebarButtonLeftConstraint?.update(offset: sidebarButtonLeftOffset)
        upgradeButtonLeftConstraint?.update(offset: sidebarButtonLeftOffset)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func scheduleSidebarButtonUpdateAfterLayoutChange() {
        layoutSettleCancellable?.cancel()
        postsFrameChangedNotifications = true
        layoutSettleCancellable = NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: self)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                AppLogDebug("[SidebarHeader] frameDidChange settled updateSidebarButtonLeftConstraint")
                self.updateSidebarButtonLeftConstraint()
                self.layoutSettleCancellable?.cancel()
                self.layoutSettleCancellable = nil
            }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // React to layout-mode and preference changes.
        setupConfigObserver()
        updateLayoutVisibility(layoutMode: browserState?.layoutMode ?? .performance)

        browserState?.$focusingTab
            .compactMap { $0 }
            .map { tab in Publishers.CombineLatest3(Just(tab), tab.$canGoBack, tab.$canGoForward) }
            .switchToLatest()
            .sink { [weak self] tab, canBack, canForward in
                guard let self else { return }
                self.backButton.isEnabled = canBack
                self.forwardButton.isEnabled = canForward
            }
            .store(in: &cancellables)

        browserState?.$focusingTab
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                guard let self else { return }
                self.refreshButton.isHidden = false
                self.stopButton.isHidden = true
                self.addressView.currentTab = tab
            }
            .store(in: &cancellables)

        browserState?.$focusingTab
            .compactMap { $0 }
            .map { tab in
                tab.$isLoading.combineLatest(tab.$loadingProgress)
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading, progress in
                guard let self else { return }
                self.updateStopRefreshButton(isLoading: isLoading, progress: CGFloat(progress))
            }
            .store(in: &cancellables)
        
        // React to width changes that may affect header layout.
        publisher(for: \.frame)
            .map { $0.width }
            .removeDuplicates()
            .sink { [weak self] newWidth in
                guard let self else { return }
                self.handleWidthChange(newWidth)
            }
            .store(in: &cancellables)
        
        // Position sidebar button relative to the window's traffic-light buttons
        updateSidebarButtonLeftConstraint()

        // Keep updated on window resize and when titlebar layout changes
        if let win = window {
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: win)
                .sink { [weak self] _ in self?.updateSidebarButtonLeftConstraint() }
                .store(in: &cancellables)

            NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification, object: win)
                .sink { [weak self] _ in self?.updateSidebarButtonLeftConstraint() }
                .store(in: &cancellables)
        }

        // Show the upgrade button once Sparkle reports a downloaded update.
        NotificationCenter.default.publisher(for: .sparkleDidDownloadUpdate)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                let displayVersion = notification.userInfo?["displayVersion"] as? String ?? ""
                self?.showUpgradeButton(version: displayVersion)
            }
            .store(in: &cancellables)
    }
    
    private func handleWidthChange(_ newWidth: CGFloat) {
        currentWidth = newWidth
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }
    
    @objc private func sidebarButtonClicked() {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.toggleSidebar(nil)
    }
    
    @objc private func backButtonClicked() {
        browserState?.focusingTab?.goBack()
    }
    
    @objc private func forwardButtonClicked() {
        browserState?.focusingTab?.goForward()
    }
    
    @objc private func refreshButtonClicked() {
        browserState?.focusingTab?.reload()
    }

    @objc private func stopButtonClicked() {
        browserState?.focusingTab?.stopLoading()
    }

    private func updateStopRefreshButton(isLoading: Bool, progress: CGFloat) {
        let isNTP = browserState?.focusingTab?.isNTP == true
        let showStop = isLoading && !isNTP && progress > 0 && progress < 1.0
        refreshButton.isHidden = showStop
        stopButton.isHidden = !showStop
    }

    private func upgradeButtonClicked() {
        guard let version = availableUpdateVersion else { return }
        let response = AppController.shared.showInstallAvailableAlert(version: version)
        if response == .alertFirstButtonReturn {
            AppController.shared.installUpdateImmediately()
        }
    }

    /// Shows the upgrade button for a downloaded update.
    private func showUpgradeButton(version: String) {
        availableUpdateVersion = version
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }

    /// Hides the upgrade button.
    private func hideUpgradeButton() {
        availableUpdateVersion = nil
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }

    private func updateUpgradeAndSidebarVisibility(layoutMode: LayoutMode) {
        guard availableUpdateVersion != nil else {
            upgradeButton.isHidden = true
            sidebarButton.isHidden = false
            return
        }

        let tooNarrowForUpgrade = !isFloating && currentWidth <= 225
        upgradeButton.isHidden = tooNarrowForUpgrade
        sidebarButton.isHidden = tooNarrowForUpgrade ? false : (layoutMode != .balanced)
    }
}
