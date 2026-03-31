// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
class MainSplitViewController: NSViewController {
    private let splitViewController = NSSplitViewController()

    private lazy var verticalTabListViewController: SidebarViewController = { SidebarViewController(browserState: state) }()
    
    let webContentContainerViewController: WebContentContainerViewController

    private var sideBarSplitViewItem: NSSplitViewItem!
    private var webContentSplitViewItem: NSSplitViewItem!
    private lazy var cancellables = Set<AnyCancellable>()

    private var lastUseHorizontalTabs: Bool?

    let state: BrowserState
    init(state: BrowserState) {
        self.state = state
        self.webContentContainerViewController = WebContentContainerViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = TitlebarTransparentView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupChildSplitViewController()
        setupSplitViewItems()
        setupTitlebarAwareLayout()

        DispatchQueue.main.async { [weak self] in
            self?.splitViewController.splitView.autosaveName = "phiMainBrowserSplitView"
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        cancellables.removeAll()

        state.$sidebarCollapsed
            .sink { [weak self] collapsed in
                guard let self else { return }
                // Ignore sidebar expansion updates while traditional layout is active.
                if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                    if !self.sideBarSplitViewItem.isCollapsed {
                        self.sideBarSplitViewItem.animator().isCollapsed = true
                    }
                    return
                }
                if self.sideBarSplitViewItem.isCollapsed != collapsed {
                    self.toggleSidebar(nil)
                }
            }
            .store(in: &cancellables)

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
                    self.state.sidebarCollapsed = true
                    return
                }
                self.state.toggleSidebar(isCollapsed)
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
            .sink { [weak self] _ in
                self?.updateLayoutForHorizontalTabs()
            }
            .store(in: &cancellables)

        updateLayoutForHorizontalTabs()
    }

    func toggleSidebar(_ sender: Any?) {
        // Sidebar is always collapsed in traditional layout.
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional else { return }
        sideBarSplitViewItem.animator().isCollapsed.toggle()
    }

    func toggleAIChat(_ sender: Any?) {
        webContentContainerViewController.toggleAIChat()
    }

    func adjustSidebarWidthWithDeadZone(by deltaX: CGFloat, currentMouseX: CGFloat, resizeHandleRightEdge: CGFloat, accumulatedDelta: inout CGFloat) -> CGFloat {
        let collapseBufferDistance: CGFloat = 70

        if sideBarSplitViewItem.isCollapsed {
            if deltaX > 0 {
                let minWidth = sideBarSplitViewItem.minimumThickness
                let expandThreshold = min(minWidth, 120)

                if currentMouseX >= expandThreshold {
                    sideBarSplitViewItem.isCollapsed = false
                    let initialWidth = minWidth
                    splitViewController.splitView.setPosition(initialWidth, ofDividerAt: 0)
                    accumulatedDelta = 0

                    let expandedHandleLeftEdge = initialWidth
                    let expandedHandleRightEdge = initialWidth + 10
                    let mouseInExpandedHandle = currentMouseX >= expandedHandleLeftEdge && currentMouseX <= expandedHandleRightEdge

                    if !mouseInExpandedHandle {
                        return 0
                    }
                } else {
                    return 0
                }
            } else {
                return 0
            }
        }

        let currentWidth = sideBarSplitViewItem.viewController.view.frame.width
        let newWidth = currentWidth + deltaX
        let minWidth = sideBarSplitViewItem.minimumThickness
        let maxWidth = sideBarSplitViewItem.maximumThickness

        let atMinimum = currentWidth <= minWidth + 1.0
        let atMaximum = currentWidth >= maxWidth - 1.0

        if atMinimum && deltaX < 0 {
            accumulatedDelta += abs(deltaX)
            if accumulatedDelta >= collapseBufferDistance {
                sideBarSplitViewItem.isCollapsed = true
                accumulatedDelta = 0
            }
            return 0
        }

        let mouseOutsideHandle = currentMouseX > resizeHandleRightEdge
        let resizeHandleLeftEdge = resizeHandleRightEdge - 10
        let mouseLeftOfHandle = currentMouseX < resizeHandleLeftEdge

        if atMaximum && deltaX < 0 && mouseOutsideHandle {
            return 0
        }

        if deltaX > 0 && mouseLeftOfHandle {
            return 0
        }

        if (atMinimum && deltaX > 0) || (!atMinimum && !atMaximum) {
            if accumulatedDelta > 0 {
                accumulatedDelta = 0
            }
        }

        let constrainedWidth = max(minWidth, min(newWidth, maxWidth))

        guard abs(constrainedWidth - currentWidth) > 0.1 else {
            return 0
        }

        splitViewController.splitView.setPosition(constrainedWidth, ofDividerAt: 0)
        return constrainedWidth - currentWidth
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
        sideBarSplitViewItem.minimumThickness = 220
        sideBarSplitViewItem.maximumThickness = 500
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

        lastUseHorizontalTabs = traditionalLayout

        if traditionalLayout {
            setSidebarCollapsed(true, animated: false)
        } else {
            setSidebarCollapsed(false, animated: false)
        }
    }

    private func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        if animated {
            sideBarSplitViewItem.animator().isCollapsed = collapsed
        } else {
            sideBarSplitViewItem.isCollapsed = collapsed
        }
        state.sidebarCollapsed = collapsed
    }

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
        let width = sideBarSplitViewItem.isCollapsed ? 0 : sideBarSplitViewItem.viewController.view.frame.width
        state.sidebarWidth = width
    }
}

protocol TitlebarAwareHitTestable: NSView {
    /// Returns whether this view should consume a hit inside titlebar space.
    func shouldConsumeHitTest(at point: NSPoint) -> Bool
}

class TitlebarTransparentView: NSView {
    /// Lets titlebar gestures fall through when a descendant view does not need the event.

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        let superHit = super.hitTest(point)

        if let titlebarAwareView = superHit as? TitlebarAwareHitTestable {
            if !titlebarAwareView.shouldConsumeHitTest(at: point) {
                if let window = self.window, isPointInTitlebar(point, window: window) {
                    return nil
                }
            }
        }

        if superHit == nil || superHit === self {
            if let window = self.window, isPointInTitlebar(point, window: window) {
                return nil
            }
        }
        
        return superHit
    }

    private func isPointInTitlebar(_ point: NSPoint, window: NSWindow) -> Bool {
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let heightFromTop = bounds.height - point.y
        return heightFromTop <= titlebarHeight
    }
}
