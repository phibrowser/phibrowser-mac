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
    /// Menu dropped on left-click — the Space switcher. Right-click keeps the
    /// standard `menu` (the tab-strip context menu), so the two gestures
    /// surface different menus from the same chip. Hovering no longer opens
    /// it: the chip shows the Space hover card instead (see
    /// `SpacesStripView.compactChip`), matching the sidebar pips.
    var primaryMenu: NSMenu?

    /// Runs just before the switcher pops, so the controller can drop the
    /// chip's hover card synchronously and arm the click suppression — the
    /// menu's modal tracking loop stops the main queue, so nothing deferred
    /// would run until the menu closes.
    var onPrimaryMenuWillOpen: (() -> Void)?

    /// How long the dropped Space switcher stays open before auto-dismissing,
    /// mirroring the sidebar hover card's cap so a forgotten menu can't linger.
    private static let menuAutoCloseAfter: TimeInterval = 10

    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        // This view hosts the active-Space chip, so a left-click must reach it
        // to drop the Space-switcher menu (see `mouseDown`). Unlike the empty
        // tab-strip bar — where left-clicks must fall through to the titlebar
        // for window drag — clicks here are always meant for the chip.
        if NSApp.currentEvent?.type == .leftMouseDown { return true }
        return shouldConsumeTitlebarEvent(NSApp.currentEvent)
    }

    /// Left-clicking the chip drops the Space switcher. The chip's SwiftUI
    /// content has no click gesture, so this `mouseDown` is reached for the click.
    override func mouseDown(with event: NSEvent) {
        if primaryMenu != nil {
            onPrimaryMenuWillOpen?()
            dropPrimaryMenu()
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Pops `primaryMenu` from the chip's bottom-leading corner, matching the old
    /// popover's placement below the icon.
    private func dropPrimaryMenu() {
        guard let primaryMenu else { return }
        let bottomLeading = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY)

        // Auto-dismiss a switcher that's left open. `popUp` blocks in a modal
        // tracking loop running in `.eventTracking`, so the timer is registered
        // for that mode (and `.common`) to fire while the menu is up;
        // `cancelTracking()` then tears it down and lets `popUp` return. The
        // timer is invalidated the instant `popUp` returns — whether the user or
        // the timeout closed the menu — so it never outlives this call.
        let autoClose = Timer(timeInterval: Self.menuAutoCloseAfter, repeats: false) { [weak primaryMenu] _ in
            primaryMenu?.cancelTracking()
        }
        RunLoop.main.add(autoClose, forMode: .eventTracking)
        RunLoop.main.add(autoClose, forMode: .common)

        primaryMenu.popUp(positioning: nil, at: bottomLeading, in: self)
        autoClose.invalidate()
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

    /// Floating hover-card panel for the active-Space chip, owned here (not by
    /// the SwiftUI strip) so the chip's hosting view can dismiss the card
    /// synchronously before popping the switcher menu — see
    /// `onPrimaryMenuWillOpen`.
    private let chipHoverTooltipController = SpaceHoverTooltipController()

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

    /// Space-switcher menu dropped by the active-Space chip on left-click (the
    /// menu rendition of the old switcher popover; hovering the chip shows the
    /// Space hover card instead). Populated lazily in `menuNeedsUpdate` so it
    /// always reflects the current Space list and active Space; distinct from
    /// `stripContextMenu`, which the chip shows on right-click.
    private lazy var spaceSwitcherMenu: NSMenu = {
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

    /// Leading inset for the active-Space chip, tuned so the Space icon sits
    /// between the macOS traffic-light buttons and the first pinned tab. The
    /// first tab is pinned to the chip's trailing edge, so moving the chip only
    /// changes the *left* gap (the icon→tab gap moves with it). The chip uses
    /// tight internal padding (`SpacesStripView.compactChipHorizontalPadding`),
    /// so the inset carries the left clearance.
    private static let trafficLightInset: CGFloat = 80

    /// Maximum width budget for the leading active-Space chip. Short names hug
    /// their content; long names truncate inside this budget rather than
    /// stealing room from the tabs.
    private static let spacesPickerWidth: CGFloat = 150
    
    // MARK: - UI Setup
    
    private func setupUI() {
        let rightButtons = TabStripRightButtons(
            cardManager: NotificationCardManager.shared,
            browserState: browserState,
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
            showsEllipsisAffordance: false,
            resolveOwnerController: { [weak browserState] in browserState?.windowController },
            chipTooltipController: chipHoverTooltipController
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
        // Right-clicking the active-Space chip shows the same strip context menu
        // as the rest of the tab bar (the active-Space controls). Left-clicking
        // it instead drops the Space-switcher menu, popped by
        // SafeAreaIgnoringThemedHostingView (mouseDown); hovering shows the
        // active Space's hover card (SpacesStripView.compactChip), matching
        // the sidebar pips.
        spacesHostingView.menu = stripContextMenu
        spacesHostingView.primaryMenu = spaceSwitcherMenu
        // Opening the switcher is a click, not a hover: drop the chip's card
        // NOW (the menu's modal loop would defer anything queued) and arm the
        // same click suppression the sidebar pips use, so the card doesn't
        // reappear under the resting cursor after the menu closes or the
        // selected Space's window swaps in.
        spacesHostingView.onPrimaryMenuWillOpen = { [chipHoverTooltipController] in
            if let activeId = slot.activeSpaceId {
                slot.suppressHoverCard(spaceId: activeId)
            }
            chipHoverTooltipController.dismissImmediately()
        }

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
              spacesPickerEligible else { return }
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
        slot.activate(spaceId: spaces[targetIdx].spaceId, userInitiated: true)
    }

    /// Shows or hides the active-Space picker to match the master Spaces
    /// feature flag, and lays out the row around it. The picker is a compact
    /// chip pinned to the leading edge (just past the traffic lights); the tab
    /// strip starts right after it. When the feature is off the picker
    /// collapses to zero width and the tab strip reclaims the leading inset.
    /// Whether the active-Space picker should appear in this window: the master
    /// Spaces flag must be on AND the window must participate in Spaces.
    /// Standalone incognito windows are a single ephemeral context with no
    /// Spaces, so the chip and its swipe-to-switch gesture are suppressed
    /// (mirroring the sidebar layout); the Incognito Space's window IS
    /// a Space and keeps the picker so the user can switch back.
    private var spacesPickerEligible: Bool {
        PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() && browserState.participatesInSpaces
    }

    private func applySpacesPickerVisibility() {
        guard let spacesView = spacesPickerHostingView,
              let rightButtons = rightButtonsHostingView else { return }
        // With a single Space there is nothing to switch to, so the chip is
        // pure noise next to the traffic lights — hide it until a second Space
        // exists. The swipe gesture keeps its eligibility-only guard so the
        // rubber-band end feedback still plays.
        let enabled = spacesPickerEligible && SpaceManager.shared.spaces.count > 1
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

    /// Re-applies the picker visibility whenever the master Spaces flag flips
    /// or the Space count crosses the single-Space threshold. The toggle writes
    /// `UserDefaults.standard`, so the change arrives via `didChangeNotification`;
    /// Space creation/deletion arrives via the manager's published list. The
    /// visibility applier no-ops unless the resolved state actually changed.
    private func observeSpacesFeatureFlag() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySpacesPickerVisibility()
            }
            .store(in: &cancellables)

        SpaceManager.shared.$spaces
            .map(\.count)
            .removeDuplicates()
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
        if menu === stripContextMenu {
            contextMenuHelper.populate(menu)
        } else if menu === spaceSwitcherMenu {
            AppController.shared?.populateSpaceSwitcherMenu(menu)
        }
    }
}
