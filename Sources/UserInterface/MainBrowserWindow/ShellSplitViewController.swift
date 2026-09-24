// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

/// The shell window's one split: the sidebar column on the left, the page
/// area on the right. It belongs to the window, not to any Space session,
/// which is what makes the sidebar read as one sidebar across Space
/// switches: its width, collapsed state, vibrancy backdrop and divider never
/// rebuild when the presented session changes. A session contributes two
/// views — its sidebar content (`SidebarViewController.view`, painting no
/// backdrop of its own) into `sidebarHost`, and its page tree
/// (`MainSplitViewController.view`) into `contentHost` — and the
/// vertical-layout switch slides the sidebar band inside the column while
/// the page area swaps underneath (`SpaceWindowSlot.HostedBandSlide`).
///
/// The split item is the sole owner of sidebar geometry. Sessions observe
/// it through read-only publishers; presenting or creating a Space never
/// writes width or collapsed state back into the shell.
final class ShellSplitViewController: NSViewController {
    static let leftItemMinWidth = MainSplitViewController.leftItemMinWidth
    static let leftItemMaxWidth = MainSplitViewController.leftItemMaxWidth
    /// The column holds its width against window resizes ahead of the page
    /// area, and — through `ShellSidebarHostViewController.residentTrailingPriority`
    /// — ahead of any width its resident trees would prefer.
    static let sidebarHoldingPriority = NSLayoutConstraint.Priority(260)
    static let contentHoldingPriority = NSLayoutConstraint.Priority(240)
    private static let splitViewAutosaveName = "phiMainBrowserSplitView"

    private let splitViewController = NSSplitViewController()
    let sidebarHost = ShellSidebarHostViewController()
    let contentHost = ShellContentHostViewController()
    let floatingSidebarHost = FloatingSidebarHostViewController()
    private var sidebarSplitViewItem: NSSplitViewItem!
    private var contentSplitViewItem: NSSplitViewItem!
    private var cancellables = Set<AnyCancellable>()
    private var lastTraditionalLayout: Bool?

    override func loadView() {
        view = TitlebarTransparentView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let splitView = PhiSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thick
        splitView.delegate = self
        splitViewController.splitView = splitView
        addChild(splitViewController)
        view.addSubview(splitViewController.view)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        if #available(macOS 26.0, *) {
            sidebarSplitViewItem = NSSplitViewItem(viewController: sidebarHost)
        } else {
            sidebarSplitViewItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        }
        sidebarSplitViewItem.minimumThickness = Self.leftItemMinWidth
        sidebarSplitViewItem.maximumThickness = Self.leftItemMaxWidth
        sidebarSplitViewItem.canCollapse = true
        sidebarSplitViewItem.holdingPriority = Self.sidebarHoldingPriority
        if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            sidebarSplitViewItem.isCollapsed = true
        }
        splitViewController.addSplitViewItem(sidebarSplitViewItem)

        contentSplitViewItem = NSSplitViewItem(contentListWithViewController: contentHost)
        contentSplitViewItem.holdingPriority = Self.contentHoldingPriority
        splitViewController.addSplitViewItem(contentSplitViewItem)

        // The same autosave name the per-session split used, so the width
        // the user had carries over.
        splitView.autosaveName = Self.splitViewAutosaveName
        // The width the column had when last expanded: what the floating
        // panel opens at while the column is collapsed. Seeded from the
        // account so a launch with a collapsed sidebar still opens the panel
        // at the user's width; every expanded-column frame updates it.
        lastExpandedSidebarWidth = AccountController.shared.localDataAccount?
            .userDefaults.lastKnownSidebarWidth ?? 0

        sidebarSplitViewItem.publisher(for: \.isCollapsed)
            .sink { [weak self] isCollapsed in
                guard let self else { return }
                if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                    // Traditional layout keeps the sidebar collapsed even if
                    // split-view state restoration tries to expand it.
                    if !isCollapsed {
                        self.sidebarSplitViewItem.isCollapsed = true
                    }
                    return
                }
                self.recordSidebarWidth()
            }
            .store(in: &cancellables)
        sidebarHost.view.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: sidebarHost.view)
            .sink { [weak self] _ in self?.recordSidebarWidth() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLayoutForHorizontalTabs() }
            .store(in: &cancellables)
        updateLayoutForHorizontalTabs()
        floatingSidebarHost.install(in: self, over: contentHost.view)
    }

    /// Observes the actual split item, including AppKit collapse/restore.
    var sidebarCollapsedPublisher: AnyPublisher<Bool, Never> {
        sidebarSplitViewItem.publisher(for: \.isCollapsed)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var sidebarWidthPublisher: AnyPublisher<CGFloat, Never> {
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: sidebarHost.view)
            .map { _ in () }
            .merge(with: sidebarCollapsedPublisher.map { _ in () })
            .map { [weak self] _ in self?.sidebarWidth ?? 0 }
            .prepend(sidebarWidth)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var isSidebarCollapsed: Bool { sidebarSplitViewItem?.isCollapsed ?? false }

    var sidebarWidth: CGFloat {
        guard let item = sidebarSplitViewItem, !item.isCollapsed else { return 0 }
        return item.viewController.view.frame.width
    }

    func toggleSidebar(_ collapsed: Bool? = nil) {
        setSidebarCollapsed(collapsed ?? !isSidebarCollapsed, animated: true)
    }

    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        let target = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional || collapsed
        guard sidebarSplitViewItem.isCollapsed != target else { return }
        if animated {
            sidebarSplitViewItem.animator().isCollapsed = target
        } else {
            sidebarSplitViewItem.isCollapsed = target
        }
    }

    /// Aligns the column to `width` / `collapsed`. The column persists across
    /// Spaces, so this only matters when a caller wants a shape other than
    /// the one on screen.
    func setSidebarGeometry(width: CGFloat?, collapsed: Bool) {
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional else { return }
        if sidebarSplitViewItem.isCollapsed != collapsed {
            sidebarSplitViewItem.isCollapsed = collapsed
        }
        guard !collapsed, let width, width > 0 else { return }
        let clamped = min(max(width, Self.leftItemMinWidth), Self.leftItemMaxWidth)
        splitViewController.splitView.setPosition(clamped, ofDividerAt: 0)
    }

    func containsSidebarTabDragBoundary(at screenLocation: CGPoint) -> Bool {
        guard !sidebarSplitViewItem.isCollapsed else { return false }
        return sidebarHost.view.containsScreenLocation(screenLocation)
    }

    private func updateLayoutForHorizontalTabs() {
        let traditional = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if let last = lastTraditionalLayout, last == traditional { return }
        let changingLayout = lastTraditionalLayout != nil
        lastTraditionalLayout = traditional
        if traditional || changingLayout {
            setSidebarCollapsed(traditional, animated: false)
        }
    }

    /// The column's width the last time it was expanded, or 0 before any.
    private(set) var lastExpandedSidebarWidth: CGFloat = 0

    private var sidebarWidthPersistWorkItem: DispatchWorkItem?
    private var lastRecordedSidebarWidth: CGFloat?
    /// Quiet period after the column's last width change before the width is
    /// written to the account's defaults.
    private static let sidebarWidthPersistDelay: TimeInterval = 0.3

    /// Records the column's width: at once in memory, for the floating panel,
    /// and on disk once the width settles. Each account-defaults write
    /// serializes and atomically rewrites the whole store, and a divider drag
    /// reports a new width (twice) on every frame.
    private func recordSidebarWidth() {
        guard let item = sidebarSplitViewItem else { return }
        let width = item.isCollapsed ? 0 : item.viewController.view.frame.width
        guard width != lastRecordedSidebarWidth else { return }
        lastRecordedSidebarWidth = width
        if width >= Self.leftItemMinWidth {
            lastExpandedSidebarWidth = width
        }
        guard width != Self.leftItemMinWidth else { return }
        sidebarWidthPersistWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            AccountController.shared.localDataAccount?.userDefaults.setLastKnownSidebarWidth(width)
        }
        sidebarWidthPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarWidthPersistDelay, execute: workItem)
    }
}

extension ShellSplitViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedPosition
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        recordSidebarWidth()
    }
}

/// The sidebar column: the vibrancy material and themed fill every Space's
/// sidebar content shows through, and the host of that content. The
/// backdrop follows the theme of the session the column stands for —
/// normally the presented one; during a band slide the leaving one, whose
/// theme is ramping to the entering Space's colors — through
/// `BrowserThemeContextProviding`, which the views' theme lookup consults
/// on the responder chain.
///
/// Every session of the slot keeps its sidebar content *resident* here —
/// added once, sized with the column, hidden unless presented. That is what
/// lets a Space switch start on the next frame: a resident view's layers
/// exist and its layout is current, so presenting it is a flag flip, where
/// a view brought into the window on the switch pays for its layer tree,
/// its layout and the theme rebinds of everything in it first.
final class ShellSidebarHostViewController: NSViewController, BrowserThemeContextProviding {
    private(set) weak var themeSession: SpaceSessionController?

    var providedBrowserThemeContext: BrowserThemeContext? {
        themeSession?.browserState.themeContext
    }

    var backdrop: ColoredVisualEffectView { view as! ColoredVisualEffectView }

    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        self.view = view
    }

    /// Points the backdrop at `session`'s theme.
    func followTheme(of session: SpaceSessionController?) {
        themeSession = session
        backdrop.rebindThemeProvider()
    }

    /// How firmly a resident's trailing edge follows the column's: just
    /// under the column's own holding priority, so nothing a resident asks
    /// for can move the divider, and above every default content preference
    /// (`NSLayoutConstraint.Priority.defaultLow`), so a resident with no
    /// demand of its own spans the column exactly.
    static let residentTrailingPriority = NSLayoutConstraint.Priority(
        ShellSplitViewController.sidebarHoldingPriority.rawValue - 1)

    /// Makes `sidebarView` resident in the column, hidden, filling it and
    /// following its size. A view already resident is left as it is.
    ///
    /// Residents follow the column; the column never follows a resident.
    /// The leading, top and bottom edges are pinned outright, but the
    /// trailing edge follows at `residentTrailingPriority`, far below the
    /// priority AppKit applies a divider drag at (490,
    /// `NSLayoutConstraint.Priority.dragThatCannotResizeWindow`). An
    /// autoresizing mask would bind the edges with required constraints, and
    /// then any minimum width a resident tree carried at a higher priority
    /// — an `NSHostingView` left with its default `sizingOptions` pins its
    /// SwiftUI content's minimum and maximum width at 999.9 — became the
    /// column's: every shrink drag lost to it while a collapse (required)
    /// still went through, so a sidebar dragged to its maximum stuck there.
    /// Such a tree now overruns the column instead, which is visible and
    /// fixable where it happens; the divider stays the user's.
    ///
    /// Only the presented resident follows the column's width live. A hidden
    /// one holds its width (`heldWidth`, at the same priority) and catches up
    /// once the column has stopped changing: AppKit lays out hidden views
    /// too, so with every resident following, a divider drag re-laid out
    /// every Space's sidebar on every frame. They are caught up well before
    /// a switch can present one, so presenting stays a flag flip.
    func host(_ sidebarView: NSView) {
        guard sidebarView.superview !== view else { return }
        sidebarView.removeFromSuperview()
        sidebarView.isHidden = true
        sidebarView.frame = view.bounds
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarView)
        let trailing = sidebarView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        trailing.priority = Self.residentTrailingPriority
        let heldWidth = sidebarView.widthAnchor.constraint(equalToConstant: view.bounds.width)
        heldWidth.priority = Self.residentTrailingPriority
        residentWidthConstraints[ObjectIdentifier(sidebarView)] = ResidentWidthConstraints(
            trailing: trailing,
            heldWidth: heldWidth
        )
        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heldWidth,
        ])
    }

    /// Shows a resident `sidebarView` as the column's content, above the
    /// other resident views. The reorder is a sort, not a re-add: re-adding
    /// takes the view out of the window and back, which is the cost
    /// residency exists to avoid.
    func present(_ sidebarView: NSView) {
        host(sidebarView)
        if let constraints = residentWidthConstraints[ObjectIdentifier(sidebarView)] {
            constraints.heldWidth.isActive = false
            constraints.trailing.isActive = true
        }
        sidebarView.isHidden = false
        if view.subviews.last !== sidebarView {
            let presented = Unmanaged.passUnretained(sidebarView).toOpaque()
            view.sortSubviews({ a, b, context in
                let presented = context!
                if Unmanaged.passUnretained(a).toOpaque() == presented { return .orderedDescending }
                if Unmanaged.passUnretained(b).toOpaque() == presented { return .orderedAscending }
                return .orderedSame
            }, context: presented)
        }
    }

    /// Hides a resident `sidebarView`; it stays resident for its next turn.
    func conceal(_ sidebarView: NSView) {
        guard sidebarView.superview === view else { return }
        sidebarView.isHidden = true
        if let constraints = residentWidthConstraints[ObjectIdentifier(sidebarView)] {
            constraints.heldWidth.constant = view.bounds.width
            constraints.trailing.isActive = false
            constraints.heldWidth.isActive = true
        }
    }

    /// Takes `sidebarView` out of the column for good: its session is
    /// leaving the shell.
    func evict(_ sidebarView: NSView) {
        guard sidebarView.superview === view else { return }
        // The held width is the view's own constraint and would outlive the
        // removal, following the view wherever it goes next.
        residentWidthConstraints.removeValue(forKey: ObjectIdentifier(sidebarView))?
            .heldWidth.isActive = false
        sidebarView.removeFromSuperview()
        sidebarView.translatesAutoresizingMaskIntoConstraints = true
        sidebarView.isHidden = false
    }

    private struct ResidentWidthConstraints {
        /// Follows the column; active while the resident is presented.
        let trailing: NSLayoutConstraint
        /// Holds a width; active while the resident is hidden.
        let heldWidth: NSLayoutConstraint
    }

    private var residentWidthConstraints: [ObjectIdentifier: ResidentWidthConstraints] = [:]
    private var heldWidthSyncWorkItem: DispatchWorkItem?
    /// Quiet period after the column's last width change before the hidden
    /// residents take the new width.
    private static let heldWidthSyncDelay: TimeInterval = 0.2

    override func viewDidLoad() {
        super.viewDidLoad()
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(columnFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: view
        )
    }

    @objc private func columnFrameDidChange(_ notification: Notification) {
        heldWidthSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.heldWidthSyncWorkItem = nil
            self?.syncHeldWidths()
        }
        heldWidthSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.heldWidthSyncDelay, execute: workItem)
    }

    /// Brings every hidden resident to the column's current width.
    private func syncHeldWidths() {
        let width = view.bounds.width
        for constraints in residentWidthConstraints.values
        where constraints.heldWidth.isActive && constraints.heldWidth.constant != width {
            constraints.heldWidth.constant = width
        }
    }
}

/// The page area: the host of the presented session's page tree
/// (`MainSplitViewController.view`), which fills it, and — like the sidebar
/// column — the painter of the themed backdrop around the page: the toolbar
/// strip and the margins. Hosted page trees paint none of their own
/// (`WebContentContainerViewController.paintsOwnBackdrop`), so a Space
/// switch ramps this one backdrop on the slide's clock, in step with the
/// column, instead of leaving the frame to the leaving tree's theme.
final class ShellContentHostViewController: NSViewController, BrowserThemeContextProviding {
    private(set) weak var themeSession: SpaceSessionController?

    var providedBrowserThemeContext: BrowserThemeContext? {
        themeSession?.browserState.themeContext
    }

    var backdrop: ColoredVisualEffectView { view as! ColoredVisualEffectView }

    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.autoresizesSubviews = true
        self.view = view
    }

    /// Points the backdrop at `session`'s theme.
    func followTheme(of session: SpaceSessionController?) {
        themeSession = session
        backdrop.rebindThemeProvider()
    }

    /// Keep page trees attached just like sidebar content. A hidden ancestor
    /// delivers WebContentsViewCocoa.viewDidHide and Chromium kHidden without
    /// repeating the window attachment callbacks on every Space switch.
    func host(_ contentView: NSView) {
        guard contentView.superview !== view else { return }
        contentView.removeFromSuperview()
        contentView.isHidden = true
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        view.addSubview(contentView)
    }

    func install(_ contentView: NSView) {
        host(contentView)
        // AppKit can defer autoresizing for hidden trees. Reconcile only an
        // actual size change, before revealing the resident page.
        if contentView.frame != view.bounds { contentView.frame = view.bounds }
        contentView.layer?.transform = CATransform3DIdentity
        contentView.isHidden = false
        if view.subviews.last !== contentView {
            let presented = Unmanaged.passUnretained(contentView).toOpaque()
            view.sortSubviews({ a, b, context in
                if Unmanaged.passUnretained(a).toOpaque() == context! { return .orderedDescending }
                if Unmanaged.passUnretained(b).toOpaque() == context! { return .orderedAscending }
                return .orderedSame
            }, context: presented)
        }
    }

    func conceal(_ contentView: NSView) {
        guard contentView.superview === view else { return }
        contentView.layer?.transform = CATransform3DIdentity
        contentView.isHidden = true
    }

    func evict(_ contentView: NSView) {
        contentView.removeFromSuperview()
        contentView.isHidden = false
    }
}
