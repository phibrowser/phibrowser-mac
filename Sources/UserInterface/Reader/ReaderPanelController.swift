// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// Reader View overlay panel: hosts the reader extension's reading-surface
/// tab in a child window covering the WHOLE page pane (the web-content area
/// only — the sidebar stays fully usable). The origin tab keeps its live
/// page underneath; closing the overlay simply reveals it again.
///
/// The peek panel's sibling, minus its chrome: the reader page carries its
/// own HUD (style controls, text-to-speech, close), so the panel is a bare
/// full-bleed host. Each reader belongs to its origin tab and every origin
/// can carry its own; the single panel always hosts the focused origin's
/// reader — switching tabs swaps the hosted content (or hides the panel
/// when the focused tab has none). Presentation only — every state
/// transition goes through `BrowserState` (`closeReaderOverlay` /
/// `expandReaderOverlayIntoTab`), whose `readerOverlayState` the window
/// controller observes. The hosted view belongs to a live Chromium strip
/// tab kept off the Mac tab list; a child window is required so the panel
/// reliably draws above the accelerated web-content surface and moves with
/// the parent.
final class ReaderPanelController {
    private final class ReaderPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Opaque backing matching the page pane's rounded corners, so the
    /// full-pane cover reads as the pane itself switching to the reader
    /// rather than a card floating over it.
    private final class ReaderContainerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            updateBackground()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBackground()
        }

        private func updateBackground() {
            // Layers don't track appearance changes; resolve the dynamic
            // color under the current effective appearance before assigning.
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        }
    }

    private weak var browserState: BrowserState?
    private weak var parentWindow: NSWindow?
    /// The web-content container view; geometry-observation anchor and the
    /// sizing fallback while no tab content is mounted.
    private weak var anchorView: NSView?
    /// Resolves the focused tab's rounded page card — the region the panel
    /// covers. A closure because the card view belongs to whichever
    /// `WebContentViewController` is currently displayed.
    private let cardViewProvider: () -> NSView?
    private let panel: ReaderPanel
    private let containerView = ReaderContainerView()
    private weak var hostedTab: Tab?
    private var eventMonitor: Any?
    private var parentResizeObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    /// Frame observation of the card itself: the card can move without the
    /// container or window resizing (AI Chat dock, layout-mode insets).
    private var cardFrameObserver: NSObjectProtocol?
    private weak var observedCardView: NSView?
    /// See `setConcealedByInWindowOverlay`.
    private var isConcealedByInWindowOverlay = false
    /// See `setEclipsedByInWindowOverlay`.
    private var isEclipsedByInWindowOverlay = false

    init(browserState: BrowserState,
         parentWindow: NSWindow,
         anchorView: NSView,
         cardViewProvider: @escaping () -> NSView?) {
        self.browserState = browserState
        self.parentWindow = parentWindow
        self.anchorView = anchorView
        self.cardViewProvider = cardViewProvider
        anchorView.postsFrameChangedNotifications = true

        panel = ReaderPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        // Full cover — a shadow could only bleed onto the sidebar.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false

        panel.contentView = containerView
    }

    deinit {
        removeEventMonitor()
        removeGeometryObservers()
    }

    // MARK: - Presentation

    func present(tab: Tab) {
        guard let browserState else { return }

        // Re-focus of the origin tab with the same reader still mounted:
        // just reveal — the panel is coming back from a tab switch.
        if hostedTab === tab, !containerView.subviews.isEmpty {
            reveal()
            return
        }

        guard let webView = tab.webContentView else {
            // Without a native view there is nothing to host — degrade to a
            // regular tab instead of showing an empty panel.
            AppLogWarn("📖 [ReaderOverlay] tab \(tab.guid) has no webContentView — expanding into a tab")
            browserState.expandReaderOverlayIntoTab(readerTabId: tab.guid)
            return
        }

        detachHostedContent()
        hostedTab = tab

        containerView.addSubview(webView)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        reveal()
    }

    /// Temporarily hides the panel while the origin tab is not focused. The
    /// hosted content stays alive; `present(tab:)` reveals again.
    func hide() {
        guard panel.isVisible else { return }
        removeEventMonitor()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// While the omnibox floats over the panel (it lives in its own child
    /// window one level up), the panel stays visible but goes input-inert:
    /// its local key monitor must not fight the omnibox for Esc and
    /// shortcuts, and reveals must not steal the omnibox's key. On
    /// un-eclipse the panel takes key back so the reader page keeps
    /// receiving keystrokes.
    func setEclipsedByInWindowOverlay(_ eclipsed: Bool) {
        guard isEclipsedByInWindowOverlay != eclipsed else { return }
        isEclipsedByInWindowOverlay = eclipsed
        if !eclipsed {
            revealIfStillCurrent()
        }
    }

    /// While an in-window blocking overlay (tab search) is up, the panel
    /// steps aside entirely: it is a child window, which draws above every
    /// in-window view, so left in place it would cover the overlay. Content
    /// stays mounted — the origin page shows beneath, which is what the
    /// overlay targets anyway (a committed navigation closes the reader
    /// through `closeReaderOverlayForAddressBarNavigation`).
    func setConcealedByInWindowOverlay(_ concealed: Bool) {
        guard isConcealedByInWindowOverlay != concealed else { return }
        isConcealedByInWindowOverlay = concealed
        if concealed {
            hide()
        } else {
            revealIfStillCurrent()
        }
    }

    /// Un-conceal path: the hosted reader may have closed, or the focused
    /// tab may have changed, while the overlay was up — only come back when
    /// this panel's content is still the focused origin's reader.
    private func revealIfStillCurrent() {
        guard let tab = hostedTab,
              let browserState,
              let focusedTabId = browserState.focusingTab?.guid,
              browserState.readerOverlayState.reader(forOrigin: focusedTabId) === tab else {
            return
        }
        reveal()
    }

    /// Idempotent teardown of the panel. Never closes the tab itself — that
    /// is `BrowserState`'s job (`closeReaderOverlay`) or Chromium's (window
    /// teardown).
    func dismiss() {
        removeEventMonitor()
        removeGeometryObservers()
        // Detach the Chromium view BEFORE the window goes away: its lifetime
        // is owned by Chromium and it must not linger in a dying hierarchy.
        detachHostedContent()
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
            panel.orderOut(nil)
            parent.makeKey()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Synchronous best-effort detach used from `tabWillBeRemove`, while the
    /// closing WebContents is still alive. The full dismiss follows through
    /// the async `closeTab` → `readerOverlayState` path.
    func detachContentIfHosting(tabId: Int) {
        guard hostedTab?.guid == tabId else { return }
        detachHostedContent()
    }

    // MARK: - Internals

    /// Closes the reader the panel is currently hosting (the focused
    /// origin's).
    private func closeHostedReader() {
        guard let tab = hostedTab else { return }
        browserState?.closeReaderOverlay(readerTabId: tab.guid)
    }

    private func reveal() {
        // Content mounts regardless, but the panel stays down until the
        // in-window overlay it stepped aside for goes away.
        guard !isConcealedByInWindowOverlay else { return }
        guard let parentWindow else { return }
        layoutOnAnchor()
        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        if isEclipsedByInWindowOverlay {
            // Visible beneath the floating omnibox, but never its key.
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let webView = containerView.subviews.first {
                // Re-parenting a Chromium view clears the first responder;
                // without this, keyboard input inside the reader page is
                // dead.
                panel.makeFirstResponder(webView)
                hostedTab?.webContentWrapper?.focus()
            }
        }
        installEventMonitorIfNeeded()
        installGeometryObserversIfNeeded()
    }

    private func detachHostedContent() {
        containerView.subviews.forEach { $0.removeFromSuperview() }
        hostedTab = nil
    }

    /// Screen rect of the page card the panel covers: the focused tab's
    /// rounded page card when one is mounted, else the whole container as a
    /// degraded fallback (the card excludes the window margins and the tab
    /// strip, which the panel must leave visible).
    private func paneScreenRect() -> NSRect? {
        let target = cardViewProvider() ?? anchorView
        guard let target, let window = target.window else { return nil }
        refreshCardFrameObserverIfNeeded(for: target)
        let inWindow = target.convert(target.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func layoutOnAnchor() {
        guard let paneRect = paneScreenRect() else { return }
        // The whole card, edge to edge — the reader stands in for the page.
        panel.setFrame(paneRect, display: true)
    }

    /// Follows the card view currently being covered; re-registered when the
    /// displayed tab (and so the card view) changes.
    private func refreshCardFrameObserverIfNeeded(for view: NSView) {
        guard observedCardView !== view else { return }
        if let cardFrameObserver {
            NotificationCenter.default.removeObserver(cardFrameObserver)
        }
        observedCardView = view
        view.postsFrameChangedNotifications = true
        cardFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.relayoutIfVisible()
        }
    }

    private func installGeometryObserversIfNeeded() {
        if parentResizeObserver == nil, let parentWindow {
            // Child windows do not follow parent resizes on their own.
            parentResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.relayoutIfVisible()
            }
        }
        if anchorFrameObserver == nil, let anchorView {
            // Sidebar collapse / split-divider drags resize the page pane
            // without resizing the window.
            anchorFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: anchorView,
                queue: .main
            ) { [weak self] _ in
                self?.relayoutIfVisible()
            }
        }
    }

    private func relayoutIfVisible() {
        guard panel.isVisible else { return }
        layoutOnAnchor()
    }

    private func removeGeometryObservers() {
        if let parentResizeObserver {
            NotificationCenter.default.removeObserver(parentResizeObserver)
        }
        parentResizeObserver = nil
        if let anchorFrameObserver {
            NotificationCenter.default.removeObserver(anchorFrameObserver)
        }
        anchorFrameObserver = nil
        if let cardFrameObserver {
            NotificationCenter.default.removeObserver(cardFrameObserver)
        }
        cardFrameObserver = nil
        observedCardView = nil
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible,
                  !self.isEclipsedByInWindowOverlay else { return event }
            // Esc closes the reader. Cmd-W must be swallowed here: strip-
            // active is the origin while the overlay is up, so letting it
            // reach Chromium's IDC_CLOSE_TAB would close the origin.
            if event.keyCode == 53 {
                self.closeHostedReader()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.closeHostedReader()
                return nil
            }
            // The reader's web view holds focus while the panel is key, so
            // app shortcuts never reach their normal handlers — the hosted
            // Chromium view consumes key equivalents before the menu or
            // `CommandDispatcher` sees them. Match the closing shortcuts
            // here instead:
            // - Toggle Reader View itself: the same press that opened the
            //   reader must close it.
            // - Back/Forward read as "leave the reader" — matching the
            //   in-place reader, where back left the reading surface.
            if let eventKeys = ShortcutsKey.eventKeys(for: event) {
                let closeKeys = [Shortcuts.key(for: .PHI_TOGGLE_READER),
                                 Shortcuts.key(for: .IDC_BACK),
                                 Shortcuts.key(for: .IDC_FORWARD)].compactMap { $0 }
                if eventKeys.matchingKeys.contains(where: closeKeys.contains) {
                    self.closeHostedReader()
                    return nil
                }
                // Focus Address Bar targets the origin — open the omnibox
                // (the panel then steps aside for it, see
                // setConcealedByInWindowOverlay).
                if let focusLocationKey = Shortcuts.key(for: .IDC_FOCUS_LOCATION),
                   eventKeys.matchingKeys.contains(focusLocationKey) {
                    self.browserState?.windowController?.openLocationBar(nil)
                    return nil
                }
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
