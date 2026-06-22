// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI

/// Right-clicks open the strip context menu; scroll gestures feed the
/// swipe-to-switch-Space handler (`TabStripBarView.scrollWheel`) and play
/// no part in window drag/zoom, so claiming them from titlebar space costs
/// nothing. Everything else falls through to the system titlebar.
private func shouldConsumeTitlebarEvent(_ event: NSEvent?) -> Bool {
    event?.type == .rightMouseDown || event?.type == .scrollWheel
}

/// NSHostingView variant that ignores safe area insets.
private final class SafeAreaIgnoringHostingView<Content: View>: NSHostingView<Content>, TitlebarAwareHitTestable {
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        // Right-buttons host wraps interactive SwiftUI controls, so claim
        // left/right clicks (origin/dev) and also scroll so swipe-to-switch-Space
        // works over this region too.
        guard let event = NSApp.currentEvent else {
            return true
        }
        return event.type == .leftMouseDown
            || event.type == .rightMouseDown
            || event.type == .scrollWheel
    }
}

/// ThemedHostingView variant that mirrors `SafeAreaIgnoringHostingView`'s
/// safe-area + titlebar hit-test handling. Used for SwiftUI content that
/// sits in the tab strip row and needs theme env injection (e.g. the
/// active-Space picker).
private final class SafeAreaIgnoringThemedHostingView: ThemedHostingView, TitlebarAwareHitTestable {
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        // This view hosts the interactive active-Space chip, so a left-click
        // must reach its SwiftUI button to open the Space-switcher popover
        // (the traditional-layout equivalent of the sidebar's ellipsis). Unlike
        // the empty tab-strip bar — where left-clicks must fall through to the
        // titlebar for window drag — clicks here are always meant for the chip.
        if NSApp.currentEvent?.type == .leftMouseDown { return true }
        return shouldConsumeTitlebarEvent(NSApp.currentEvent)
    }
}

final class TabStripBarView: NSView, TitlebarAwareHitTestable {
    /// Swipe-to-switch-Space gesture (see `SpaceSwipeTracker`) — the
    /// traditional-layout counterpart of the sidebar's handler. Gestures
    /// land here when made over the bar itself and when the tab strip
    /// declines them (content fits, or already scrolled to a clamp edge —
    /// see `TabStrip.scrollWheel`).
    private let spaceSwipe = SpaceSwipeTracker()
    var onSpaceSwipe: ((Int) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        switch spaceSwipe.handle(event) {
        case .passthrough:
            super.scrollWheel(with: event)
        case .consumed:
            break
        case .trigger(let step):
            onSpaceSwipe?(step)
        }
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        return shouldConsumeHitTest(for: NSApp.currentEvent)
    }

    func shouldConsumeHitTest(for event: NSEvent?) -> Bool {
        return shouldConsumeTitlebarEvent(event)
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

    /// Hosting view for the active-Space picker, pinned to the trailing edge
    /// of the tab strip row so it shares a horizontal line with the pinned
    /// tabs and the new-tab button.
    private var spacesPickerHostingView: SafeAreaIgnoringThemedHostingView?

    /// Last-applied picker visibility, so the toggle observer only remakes
    /// constraints when the master Spaces flag actually flips.
    private var lastSpacesPickerEnabled: Bool?
    private var cancellables = Set<AnyCancellable>()

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

    /// Leading inset that clears the macOS traffic-light buttons, so the
    /// active-Space switch sits just to their right (matching the design).
    private static let trafficLightInset: CGFloat = 70

    /// Maximum width budget for the leading active-Space chip. Short names hug
    /// their content; long names truncate inside this budget rather than
    /// stealing room from the tabs.
    private static let spacesPickerWidth: CGFloat = 150
    
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

        // Active-Space picker — a compact icon+name chip pinned to the leading
        // edge, just to the right of the macOS traffic lights, so the user can
        // switch Space from the same row that hosts the tabs. Falls back to the
        // manager's key slot during early window bringup before the controller
        // wires up.
        let slot = browserState.windowController?.slot
            ?? SpaceManager.shared.keySlot
            ?? SpaceManager.shared.createSlot(initialSpaceId: nil)
        let spacesPicker = SpacesStripView(
            manager: SpaceManager.shared,
            slot: slot,
            showsEllipsisAffordance: false
        )
        let spacesHostingView = SafeAreaIgnoringThemedHostingView(
            rootView: spacesPicker,
            themeSource: browserState.themeContext
        )
        spacesHostingView.setContentHuggingPriority(.required, for: .horizontal)
        spacesHostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        spacesPickerHostingView = spacesHostingView
        view.addSubview(spacesHostingView)

        view.addSubview(tabStrip)
        view.menu = stripContextMenu
        tabStrip.menu = stripContextMenu
        hostingView.menu = stripContextMenu

        // The tab strip's leading edge depends on the active-Space picker (it
        // starts just after it), so its constraints are made alongside the
        // picker's in `applySpacesPickerVisibility`.
        applySpacesPickerVisibility()
        observeSpacesFeatureFlag()

        (view as? TabStripBarView)?.onSpaceSwipe = { [weak self] step in
            self?.activateAdjacentSpace(by: step)
        }
    }

    /// Switches THIS window's active Space, clamped at the first/last Space
    /// (no wrap-around) so the slide animation direction always matches the
    /// swipe. At a clamp edge a rubber-band end effect plays instead of the
    /// swipe being swallowed. Traditional-layout counterpart of
    /// `SidebarViewController.activateAdjacentSpace` — the sidebar owns the
    /// gesture in vertical layouts.
    private func activateAdjacentSpace(by step: Int) {
        guard PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else { return }
        let spaces = SpaceManager.shared.spaces
        guard let slot = browserState.windowController?.slot ?? SpaceManager.shared.keySlot,
              let currentId = slot.activeSpaceId,
              let currentIdx = spaces.firstIndex(where: { $0.spaceId == currentId }) else { return }
        let targetIdx = currentIdx + step
        guard spaces.indices.contains(targetIdx) else {
            // Already at the first/last Space (or only one exists) — nowhere to
            // switch, so play the rubber-band end effect instead of silently
            // swallowing the swipe.
            browserState.windowController?.bounceContentForSpaceSwitchEdge(forward: step > 0)
            return
        }
        slot.activate(spaceId: spaces[targetIdx].spaceId)
    }

    /// Shows or hides the active-Space picker to match the master Spaces
    /// feature flag, and lays out the row around it. The picker is a compact
    /// chip pinned to the leading edge (just past the traffic lights); the tab
    /// strip starts right after it. When the feature is off the picker
    /// collapses to zero width and the tab strip reclaims the leading inset.
    private func applySpacesPickerVisibility() {
        guard let spacesView = spacesPickerHostingView,
              let rightButtons = rightButtonsHostingView else { return }
        let enabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        guard lastSpacesPickerEnabled != enabled else { return }
        lastSpacesPickerEnabled = enabled

        spacesView.isHidden = !enabled
        spacesView.snp.remakeConstraints { make in
            make.leading.equalToSuperview().inset(Self.trafficLightInset)
            make.centerY.equalToSuperview().offset(-2)
            if enabled {
                // Hug the icon+name (content hugging is required) but never
                // grow past the budget — long names truncate instead.
                make.width.lessThanOrEqualTo(Self.spacesPickerWidth)
            } else {
                make.width.equalTo(0)
            }
            make.height.equalTo(SpacesStripView.height)
        }
        rightButtons.snp.remakeConstraints { make in
            make.centerY.equalToSuperview().offset(-2)
            make.width.equalTo(Self.horizontalInset)
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
        }
        tabStrip.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.trailing.equalTo(rightButtons.snp.leading)
            if enabled {
                make.leading.equalTo(spacesView.snp.trailing).offset(6)
            } else {
                make.leading.equalToSuperview().inset(Self.horizontalInset)
            }
        }
    }

    /// Re-applies the picker visibility whenever the master Spaces flag flips.
    /// The toggle writes `UserDefaults.standard`, so the change arrives via
    /// `didChangeNotification`; the visibility applier no-ops unless the
    /// resolved state actually changed.
    private func observeSpacesFeatureFlag() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySpacesPickerVisibility()
            }
            .store(in: &cancellables)
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
