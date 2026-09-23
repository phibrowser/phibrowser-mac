// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
class MainSplitViewController: NSViewController, BrowserThemeContextProviding {
    static let leftItemMinWidth: CGFloat = 193
    static let leftItemMaxWidth: CGFloat = 500
    
    private let splitViewController = NSSplitViewController()

    /// Hosted: the session presents into a shell window whose
    /// `ShellSplitViewController` owns the split. This controller then
    /// builds no split of its own — its view is the page tree alone, the
    /// sidebar view is handed to the shell's column separately, and the
    /// sidebar geometry calls forward to the shell. Standalone Incognito
    /// windows (adopted NSWindows) keep the split here.
    let isHosted: Bool

    /// Resolved through the session's owning window, including while dormant
    /// or concealed. Presentation never changes sidebar ownership.
    private var shellSplit: ShellSplitViewController? { state.windowController?.shellSplit }
    private let sidebarGeometryChanges = PassthroughSubject<Void, Never>()

    var isSidebarCollapsed: Bool {
        if isHosted { return shellSplit?.isSidebarCollapsed ?? false }
        return sideBarSplitViewItem?.isCollapsed
            ?? PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
    }

    var sidebarWidth: CGFloat {
        if isHosted { return shellSplit?.sidebarWidth ?? 0 }
        guard let item = sideBarSplitViewItem, !item.isCollapsed else { return 0 }
        return item.viewController.view.frame.width
    }

    var sidebarCollapsedPublisher: AnyPublisher<Bool, Never> {
        if isHosted, let shellSplit { return shellSplit.sidebarCollapsedPublisher }
        return sidebarGeometryChanges
            .map { [weak self] _ in self?.isSidebarCollapsed ?? false }
            .prepend(isSidebarCollapsed)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var sidebarWidthPublisher: AnyPublisher<CGFloat, Never> {
        if isHosted, let shellSplit { return shellSplit.sidebarWidthPublisher }
        return sidebarGeometryChanges
            .map { [weak self] _ in self?.sidebarWidth ?? 0 }
            .prepend(sidebarWidth)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var providedBrowserThemeContext: BrowserThemeContext? { state.themeContext }

    private lazy var verticalTabListViewController: SidebarViewController = { SidebarViewController(browserState: state) }()

    /// Per-Space content only; the panel and its visibility belong to the shell.
    /// Retaining this tree makes a return switch as ready as the docked sidebar.
    private(set) lazy var floatingSidebarContent = FloatingSidebarViewController(browserState: state)


    /// This window's sidebar controller. Exposed so `SpaceManager` can drive
    /// the vertical-layout Space-switch push-in (snapshot a window's content
    /// band, run the slide overlay) without reaching through private state.
    var sidebarViewController: SidebarViewController { verticalTabListViewController }

    let webContentContainerViewController: WebContentContainerViewController

    private var sideBarSplitViewItem: NSSplitViewItem!
    private var webContentSplitViewItem: NSSplitViewItem!
    private lazy var cancellables = Set<AnyCancellable>()

    private var lastUseHorizontalTabs: Bool?

    let state: BrowserState
    init(state: BrowserState, hosted: Bool = false) {
        self.state = state
        self.isHosted = hosted
        self.webContentContainerViewController = WebContentContainerViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = TitlebarTransparentView()
    }

    private static let splitViewAutosaveName = "phiMainBrowserSplitView"

    override func viewDidLoad() {
        super.viewDidLoad()

        if isHosted {
            setupHostedContent()
            return
        }
        setupChildSplitViewController()
        setupSplitViewItems()
        setupTitlebarAwareLayout()
        updateSidebarWidth()

        DispatchQueue.main.async { [weak self] in
            self?.splitViewController.splitView.autosaveName = Self.splitViewAutosaveName
        }
    }

    /// Hosted: the page tree fills this view; the sidebar paints no backdrop
    /// of its own since it sits on the shell column's.
    private func setupHostedContent() {
        webContentContainerViewController.paintsOwnBackdrop = false
        addChild(webContentContainerViewController)
        let content = webContentContainerViewController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        verticalTabListViewController.paintsOwnBackdrop = false
        addChild(verticalTabListViewController)
    }

    /// Applies the persisted split position now instead of waiting for the
    /// deferred viewDidLoad tick above. Session-restored windows are surfaced
    /// by Chromium while the main thread is still replaying the session, so
    /// that tick cannot run before their first visible frame — the sidebar
    /// would show its default width and visibly jump once the tick lands.
    /// AppKit restores the saved divider position when `autosaveName` is
    /// assigned; the deferred tick re-assigning the same name is a no-op.
    func adoptAutosavedSplitPositionNow() {
        guard !isHosted else { return }
        splitViewController.splitView.autosaveName = Self.splitViewAutosaveName
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        cancellables.removeAll()
        guard !isHosted else { return }

        sideBarSplitViewItem.publisher(for: \.isCollapsed)
            .sink { [weak self] isCollapsed in
                guard let self else { return }
                self.updateSidebarWidth()
                // Traditional layout must keep the sidebar collapsed even if split view state
                // restoration or other external changes try to expand it.
                if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                    if !isCollapsed {
                        self.sideBarSplitViewItem.isCollapsed = true
                    }
                    return
                }
            }
            .store(in: &cancellables)

        // Track sidebar width changes from frame updates.
        verticalTabListViewController.view.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: verticalTabListViewController.view)
            .sink { [weak self] _ in
                self?.updateSidebarWidth()
            }
            .store(in: &cancellables)

        // Rebuild layout when the layout preference changes.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutForHorizontalTabs()
            }
            .store(in: &cancellables)

        updateLayoutForHorizontalTabs()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        #if DEBUG
        applySidebarHeaderWidthOverrideForUITestsIfNeeded()
        #endif
    }

    /// A window created minimized never runs `viewWillAppear` for this tree,
    /// and deminiaturizing doesn't re-trigger it — so layout and the web
    /// content mount never happen, leaving the restored window blank. Re-run
    /// the appearance-time setup explicitly (idempotent) once visible again.
    func phiHandleRestoreFromMinimized() {
        viewWillAppear()
        verticalTabListViewController.bindDownloadsManagerIfNeeded()
        webContentContainerViewController.mountActiveTabForRestore()
    }

    func toggleSidebar(_ sender: Any?) {
        // Sidebar is always collapsed in traditional layout.
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional else { return }
        if isHosted {
            shellSplit?.toggleSidebar()
            return
        }
        setSidebarCollapsed(!isSidebarCollapsed, animated: true)
    }

    /// The per-Space chrome that should slide during a cross-Space swap.
    /// Traditional (horizontal) layout only — the full content view slides
    /// so the tab strip and page content move together as a coherent page
    /// swipe. Vertical layout runs its own transition instead (the sidebar
    /// content band pushes in over a ramping tint gradient; see
    /// `SpaceManager.performVerticalSidebarPushIn`), so a nil return here
    /// means the horizontal slide shouldn't run. Read-only; never used for
    /// layout.
    var swapAnchorView: NSView? {
        PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional ? view : nil
    }

    /// Explicit window geometry changes (for example the UI-test width
    /// override). Space creation and switching never call this.
    func setSidebarGeometry(width: CGFloat?, collapsed: Bool) {
        if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            // Traditional layout pins the sidebar collapsed regardless of the
            // source window's state; don't fight that here.
            return
        }
        if isHosted {
            shellSplit?.setSidebarGeometry(width: width, collapsed: collapsed)
            return
        }
        setSidebarCollapsed(collapsed, animated: false)
        guard !collapsed, let width, width > 0 else { return }
        let clamped = min(max(width, Self.leftItemMinWidth), Self.leftItemMaxWidth)
        splitViewController.splitView.setPosition(clamped, ofDividerAt: 0)
    }

    func toggleAIChat(_ sender: Any?) {
        webContentContainerViewController.toggleAIChat()
    }

    func containsSidebarTabDragBoundary(at screenLocation: CGPoint) -> Bool {
        if isHosted {
            return shellSplit?.containsSidebarTabDragBoundary(at: screenLocation) ?? false
        }
        guard sideBarSplitViewItem.isCollapsed == false else {
            return false
        }
        return verticalTabListViewController.view.containsScreenLocation(screenLocation)
    }

    private func setupChildSplitViewController() {
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
            splitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupSplitViewItems() {
        setupLeftSplitViewItem()
        setupWebContentSplitViewItem()
    }

    private func setupLeftSplitViewItem() {
        if #available(macOS 26.0, *) {
            sideBarSplitViewItem = NSSplitViewItem(viewController: verticalTabListViewController)
        } else {
            sideBarSplitViewItem = NSSplitViewItem(sidebarWithViewController: verticalTabListViewController)
        }
        sideBarSplitViewItem.minimumThickness = Self.leftItemMinWidth
        sideBarSplitViewItem.maximumThickness = Self.leftItemMaxWidth
        sideBarSplitViewItem.canCollapse = true
        sideBarSplitViewItem.holdingPriority = .init(rawValue: 260)
        
        if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            sideBarSplitViewItem.isCollapsed = true
        }

        splitViewController.addSplitViewItem(sideBarSplitViewItem)
    }

    private func setupWebContentSplitViewItem() {
        webContentSplitViewItem = NSSplitViewItem(contentListWithViewController: webContentContainerViewController)
        webContentSplitViewItem.holdingPriority = .init(rawValue: 240)
        splitViewController.addSplitViewItem(webContentSplitViewItem)
    }

    /// Updates the split-view layout based on the current tab-bar mode.
    private func updateLayoutForHorizontalTabs() {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if lastUseHorizontalTabs != nil && traditionalLayout == lastUseHorizontalTabs {
            return
        }

        let changingLayout = lastUseHorizontalTabs != nil
        lastUseHorizontalTabs = traditionalLayout
        if traditionalLayout || changingLayout {
            setSidebarCollapsed(traditionalLayout, animated: false)
        }
    }

    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        if isHosted {
            shellSplit?.setSidebarCollapsed(collapsed, animated: animated)
            return
        }
        loadViewIfNeeded()
        let target = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional || collapsed
        guard sideBarSplitViewItem.isCollapsed != target else { return }
        if animated {
            sideBarSplitViewItem.animator().isCollapsed = target
        } else {
            sideBarSplitViewItem.isCollapsed = target
        }
        updateSidebarWidth()
    }

    #if DEBUG
    private func applySidebarHeaderWidthOverrideForUITestsIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitest"),
              let widthFlagIndex = arguments.firstIndex(of: "-sidebarHeaderWidth"),
              arguments.indices.contains(widthFlagIndex + 1),
              let requestedWidth = Double(arguments[widthFlagIndex + 1]),
              !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional else {
            return
        }

        let width = CGFloat(requestedWidth)
        [0.0, 0.2, 0.8, 1.5, 3.0, 5.0].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applySidebarHeaderWidthOverrideForUITests(width: width)
            }
        }
    }

    private func applySidebarHeaderWidthOverrideForUITests(width: CGFloat) {
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional else {
            return
        }

        setSidebarGeometry(width: width, collapsed: false)
        view.layoutSubtreeIfNeeded()
        splitViewController.splitView.layoutSubtreeIfNeeded()
        updateSidebarWidth()
    }
    #endif

    private func setupTitlebarAwareLayout() {
        if let window = view.window, window.styleMask.contains(.fullSizeContentView) {
            verticalTabListViewController.view.wantsLayer = true
            
            let titleBarHeight: CGFloat = 28
            let topInset = NSView()
            topInset.translatesAutoresizingMaskIntoConstraints = false
            topInset.wantsLayer = true
            topInset.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            
            verticalTabListViewController.view.addSubview(topInset)
            
            NSLayoutConstraint.activate([
                topInset.topAnchor.constraint(equalTo: verticalTabListViewController.view.topAnchor),
                topInset.leadingAnchor.constraint(equalTo: verticalTabListViewController.view.leadingAnchor),
                topInset.trailingAnchor.constraint(equalTo: verticalTabListViewController.view.trailingAnchor),
                topInset.heightAnchor.constraint(equalToConstant: titleBarHeight)
            ])
            
            if let scrollView = verticalTabListViewController.view.subviews.first(where: { $0 is NSScrollView }) {
                scrollView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    scrollView.topAnchor.constraint(equalTo: topInset.bottomAnchor),
                    scrollView.leadingAnchor.constraint(equalTo: verticalTabListViewController.view.leadingAnchor),
                    scrollView.trailingAnchor.constraint(equalTo: verticalTabListViewController.view.trailingAnchor),
                    scrollView.bottomAnchor.constraint(equalTo: verticalTabListViewController.view.bottomAnchor)
                ])
            }
        }
    }
}

extension MainSplitViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return proposedPosition
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        updateSidebarWidth()
    }

    private func updateSidebarWidth() {
        guard sideBarSplitViewItem != nil else { return }
        let width = sidebarWidth
        sidebarGeometryChanges.send(())
        guard width != Self.leftItemMinWidth else {
            return
        }
        AccountController.shared.localDataAccount?.userDefaults.setLastKnownSidebarWidth(width)
    }
}

protocol TitlebarAwareHitTestable: NSView {
    /// Returns whether this view should consume a hit inside titlebar space.
    func shouldConsumeHitTest(at point: NSPoint) -> Bool
}

/// Coordinates hit testing for Phi content that extends into the native titlebar.
///
/// Returning `nil` for empty or explicitly non-consuming titlebar regions lets
/// AppKit handle native window dragging and the system titlebar double-click
/// action. Ordinary descendant hits—including Chromium WebContents—must remain
/// unchanged so their mouse events reach the original view.
class TitlebarTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies `point` in the superview's coordinate space. Convert
        // it before local bounds/titlebar checks; treating it as local can make
        // an offset WebContents miss the hit and fall through to the titlebar.
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else {
            return nil
        }

        let superHit = super.hitTest(point)
        guard let window else {
            return superHit
        }

        guard isPointInTitlebar(localPoint, window: window) else {
            return superHit
        }

        if let titlebarAwareView = superHit as? TitlebarAwareHitTestable {
            let hitPoint = titlebarAwareView.convert(localPoint, from: self)
            if !titlebarAwareView.shouldConsumeHitTest(at: hitPoint) {
                return nil
            }
        }

        if superHit == nil || superHit === self {
            return nil
        }

        // Preserve normal descendants, especially Chromium's native view.
        // Chromium then decides whether that WebContents may move the window.
        return superHit
    }

    private func isPointInTitlebar(_ point: NSPoint, window: NSWindow) -> Bool {
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let heightFromTop = bounds.height - point.y
        return heightFromTop <= titlebarHeight
    }
}
