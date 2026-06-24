// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI

/// NSHostingView variant that ignores safe area insets.
private final class SafeAreaIgnoringHostingView<Content: View>: NSHostingView<Content>, TitlebarAwareHitTestable {
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        guard let event = NSApp.currentEvent else {
            return true
        }
        return event.type == .leftMouseDown || event.type == .rightMouseDown
    }
}

final class TabStripBarView: NSView, TitlebarAwareHitTestable {
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        return shouldConsumeHitTest(for: NSApp.currentEvent)
    }

    func shouldConsumeHitTest(for event: NSEvent?) -> Bool {
        return event?.type == .rightMouseDown
    }
}

/// Manages the tab strip and right-side button area in traditional layout mode.
final class TabStripBarController: NSViewController {
    
    // MARK: - Dependencies
    
    private let browserState: BrowserState
    
    // MARK: - UI Components
    
    /// Horizontal tab strip.
    private(set) lazy var tabStrip = TabStrip(browserState: browserState)
    
    /// Hosting view for the right-side button cluster.
    private var rightButtonsHostingView: SafeAreaIgnoringHostingView<TabStripRightButtons>?

    private lazy var contextMenuHelper = TabAreaContextMenuHelper(browserState: browserState, isHorizontalLayout: true)

    private lazy var stripContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()
    
    // MARK: - Callbacks
    
    /// Optional callback for the card-entry button.
    var onCardEntryTap: (() -> Void)?
    
    // MARK: - Initialization
    
    init(browserState: BrowserState) {
        self.browserState = browserState
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func loadView() {
        view = TabStripBarView()
        view.wantsLayer = true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    func setActive(_ active: Bool) {
        tabStrip.setActive(active)
    }

    /// Forwards to the underlying tab strip — used by the content border
    /// outline coordinator to find where to carve the gap for a specific tab.
    func tabFrame(for tab: Tab?, in coordView: NSView) -> CGRect? {
        tabStrip.tabFrame(for: tab, in: coordView)
    }

    /// Forwards to the underlying tab strip — used by the content border
    /// outline coordinator to draw per-group colored boundary paths
    /// (unified underline + active-tab outline) in WCC coords.
    func groupGeometries(in coordView: NSView, activeTab: Tab?) -> [TabStrip.GroupGeometry] {
        tabStrip.groupGeometries(in: coordView, activeTab: activeTab)
    }

    /// Set by the coordinator to receive a notification on each strip layout.
    var onTabStripLayoutChanged: (() -> Void)? {
        get { tabStrip.onLayoutChanged }
        set { tabStrip.onLayoutChanged = newValue }
    }
    
    // MARK: - Constants
    
    /// Horizontal inset that aligns the strip with the surrounding chrome.
    private static let horizontalInset: CGFloat = 78 + 10
    
    // MARK: - UI Setup
    
    private func setupUI() {
        let rightButtons = TabStripRightButtons(
            cardManager: NotificationCardManager.shared,
            onCardEntryTap: { [weak self] in
                self?.handleCardEntryTap()
            },
            onSearchTabsTap: { [weak self] anchorView in
                guard let self else { return }
                self.handleSearchTabsTap(anchorView: anchorView ?? self.rightButtonsHostingView)
            }
        )
        let hostingView = SafeAreaIgnoringHostingView(rootView: rightButtons)
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightButtonsHostingView = hostingView
        view.addSubview(hostingView)
        
        view.addSubview(tabStrip)
        view.menu = stripContextMenu
        tabStrip.menu = stripContextMenu
        hostingView.menu = stripContextMenu
        
        tabStrip.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(Self.horizontalInset)
            make.top.bottom.equalToSuperview()
            make.trailing.equalTo(hostingView.snp.leading)
        }
        
        hostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.centerY.equalToSuperview().offset(-2)
            make.width.equalTo(Self.horizontalInset)
        }
    }
    
    // MARK: - Card Entry Handling

    /// Shows the notification card entry in the legacy overlay container.
    private func handleCardEntryTap() {
        NotificationCardManager.shared.showManually(for: .legacy)
        onCardEntryTap?()
    }

    private func handleSearchTabsTap(anchorView: NSView?) {
        guard let anchorView else {
            return
        }
        browserState.windowController?.toggleSearchTabs(attachedTo: anchorView)
    }
}

// MARK: - Context Menu

extension TabStripBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === stripContextMenu else { return }
        contextMenuHelper.populate(menu)
    }
}
