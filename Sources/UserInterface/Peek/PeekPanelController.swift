// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// Floating Peek panel: previews a cross-site page opened from a bookmark- or
/// pinned-bound tab in a child window floating over the page pane (the web-
/// content area only — the sidebar stays fully usable), instead of a normal
/// tab.
///
/// Each peek belongs to its opener tab and every opener can carry its own;
/// the single panel always hosts the focused opener's peek — switching tabs
/// swaps the hosted content (or hides the panel when the focused tab has no
/// peek), and only closing a peek (X, Esc, Cmd-W, click on the page around
/// it) or expanding it ends it. Presentation only — every state transition
/// goes through `BrowserState` (`closePeek` / `expandPeekIntoTab`), whose
/// `peekState` the window controller observes. The hosted view belongs to a live Chromium strip tab
/// kept off the Mac tab list; a child window is required so the panel
/// reliably draws above the accelerated web-content surface and moves with
/// the parent.
final class PeekPanelController {
    private final class PeekPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Rounded opaque backing for the panel. A plain layer-backed view
    /// instead of NSVisualEffectView: the effect view's behind-window
    /// backdrop is composited by the window server and ignores
    /// `layer.cornerRadius`, which left the panel corners square.
    private final class PeekContainerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PeekPanelController.cornerRadius
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

    /// Header button with a rounded hover background (AppKit counterpart of
    /// the sidebar's `themedFill(.hover)` button styling).
    private final class PeekHeaderButton: NSButton {
        private var isHovered = false {
            didSet { updateBackground() }
        }
        private var hoverTrackingArea: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            isHovered = true
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            isHovered = false
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBackground()
        }

        private func updateBackground() {
            // Layers don't track appearance changes; resolve the dynamic
            // color under the current effective appearance before assigning.
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = isHovered
                    ? NSColor(resource: .sidebarTabHovered).cgColor
                    : NSColor.clear.cgColor
            }
        }
    }

    /// Horizontal margin between the page pane's edges and the panel; the
    /// panel spans the pane's height minus a small fixed breathing margin.
    private static let paneInsetRatio: CGFloat = 0.04
    private static let minPaneInset: CGFloat = 16
    private static let paneVerticalInset: CGFloat = 14
    private static let headerHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 12

    private weak var browserState: BrowserState?
    private weak var parentWindow: NSWindow?
    /// The page-pane view the panel is anchored over (web-content container).
    private weak var anchorView: NSView?
    private let panel: PeekPanel
    private let containerView = PeekContainerView()
    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let webHostView = NSView()
    private weak var hostedTab: Tab?
    private var eventMonitor: Any?
    private var parentResizeObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    private var titleCancellable: AnyCancellable?

    init(browserState: BrowserState, parentWindow: NSWindow, anchorView: NSView) {
        self.browserState = browserState
        self.parentWindow = parentWindow
        self.anchorView = anchorView
        anchorView.postsFrameChangedNotifications = true

        panel = PeekPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false

        panel.contentView = containerView

        buildHeader()

        containerView.addSubview(webHostView)
        webHostView.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    deinit {
        removeEventMonitor()
        removeGeometryObservers()
    }

    // MARK: - Presentation

    func present(tab: Tab) {
        guard let browserState else { return }

        // Re-focus of the opener tab with the same peek still mounted: just
        // reveal, no re-mount.
        if hostedTab === tab, !webHostView.subviews.isEmpty {
            reveal(focusContent: true)
            return
        }

        guard let webView = tab.webContentView else {
            // Without a native view there is nothing to host — degrade to a
            // regular tab instead of showing an empty panel.
            AppLogWarn("👀 [Peek] tab \(tab.guid) has no webContentView — expanding into a tab")
            browserState.expandPeekIntoTab(peekTabId: tab.guid)
            return
        }

        detachHostedContent()
        hostedTab = tab
        bindTitle(to: tab)

        webHostView.addSubview(webView)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        reveal(focusContent: true)
    }

    /// Temporarily hides the panel while the opener tab is not focused. The
    /// hosted content and bindings stay alive; `present(tab:)` reveals again.
    func hide() {
        guard panel.isVisible else { return }
        removeEventMonitor()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Idempotent teardown of the panel. Never closes the tab itself — that
    /// is `BrowserState`'s job (`closePeek`) or Chromium's (window teardown).
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
    /// the async `closeTab` → `peekState` path.
    func detachContentIfHosting(tabId: Int) {
        guard hostedTab?.guid == tabId else { return }
        detachHostedContent()
    }

    // MARK: - Actions

    @objc private func closeButtonClicked(_ sender: Any?) {
        closeHostedPeek()
    }

    @objc private func expandButtonClicked(_ sender: Any?) {
        guard let tab = hostedTab else { return }
        browserState?.expandPeekIntoTab(peekTabId: tab.guid)
    }

    @objc private func splitButtonClicked(_ sender: Any?) {
        guard let tab = hostedTab else { return }
        browserState?.openPeekAsSplitWithOpener(peekTabId: tab.guid)
    }

    /// Closes the peek the panel is currently hosting (the focused opener's).
    private func closeHostedPeek() {
        guard let tab = hostedTab else { return }
        browserState?.closePeek(peekTabId: tab.guid)
    }

    // MARK: - Internals

    private func reveal(focusContent: Bool) {
        guard let parentWindow else { return }
        layoutOnAnchor()
        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        if focusContent, let webView = webHostView.subviews.first {
            // Re-parenting a Chromium view clears the first responder;
            // without this, keyboard input inside the peek page is dead.
            panel.makeFirstResponder(webView)
            hostedTab?.webContentWrapper?.focus()
        }
        installEventMonitorIfNeeded()
        installGeometryObserversIfNeeded()
    }

    private func detachHostedContent() {
        titleCancellable = nil
        webHostView.subviews.forEach { $0.removeFromSuperview() }
        hostedTab = nil
    }

    private func bindTitle(to tab: Tab) {
        titleCancellable = tab.$title
            .combineLatest(tab.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, url in
                let fallbackHost = url.flatMap { URL(string: $0)?.host } ?? ""
                self?.titleLabel.stringValue = title.isEmpty ? fallbackHost : title
            }
    }

    private func buildHeader() {
        containerView.addSubview(headerView)
        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Self.headerHeight)
        }

        let closeButton = makeHeaderButton(
            symbolName: "xmark",
            tooltip: NSLocalizedString(
                "peek.panel.closeButtonTooltip",
                value: "Close",
                comment: "Peek popup panel - Tooltip of the button that closes the floating page preview and its page"
            ),
            action: #selector(closeButtonClicked(_:))
        )
        let expandButton = makeHeaderButton(
            symbolName: "arrow.up.left.and.arrow.down.right",
            tooltip: NSLocalizedString(
                "peek.panel.expandButtonTooltip",
                value: "Open as Tab",
                comment: "Peek popup panel - Tooltip of the button that converts the floating page preview into a regular tab"
            ),
            action: #selector(expandButtonClicked(_:))
        )
        let splitButton = makeHeaderButton(
            symbolName: "rectangle.split.2x1",
            tooltip: NSLocalizedString(
                "peek.panel.splitButtonTooltip",
                value: "Open as Split View",
                comment: "Peek popup panel - Tooltip of the button that pairs the floating page preview with its bound tab in a side-by-side split view"
            ),
            action: #selector(splitButtonClicked(_:))
        )

        headerView.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }

        headerView.addSubview(expandButton)
        expandButton.snp.makeConstraints { make in
            make.leading.equalTo(closeButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }

        headerView.addSubview(splitButton)
        splitButton.snp.makeConstraints { make in
            make.leading.equalTo(expandButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        headerView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerX.centerY.equalToSuperview()
            make.leading.greaterThanOrEqualTo(splitButton.snp.trailing).offset(12)
            make.trailing.lessThanOrEqualToSuperview().inset(72)
        }
    }

    private func makeHeaderButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = PeekHeaderButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        return button
    }

    /// Screen rect of the page pane the panel floats over.
    private func anchorScreenRect() -> NSRect? {
        guard let anchorView, let window = anchorView.window else { return nil }
        let inWindow = anchorView.convert(anchorView.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func layoutOnAnchor() {
        guard let paneRect = anchorScreenRect() else { return }
        // Near-full pane height; width follows the pane (and thus the
        // window) with a proportional side margin.
        let insetX = max(Self.minPaneInset, paneRect.width * Self.paneInsetRatio)
        panel.setFrame(paneRect.insetBy(dx: insetX, dy: Self.paneVerticalInset),
                       display: true)
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
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            switch event.type {
            case .keyDown:
                // Esc closes the peek. Cmd-W must be swallowed here: strip-
                // active is the bound opener while the peek is up, so letting
                // it reach Chromium's IDC_CLOSE_TAB would close the opener.
                if event.keyCode == 53 {
                    self.closeHostedPeek()
                    return nil
                }
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "w" {
                    self.closeHostedPeek()
                    return nil
                }
                return event
            case .leftMouseDown, .rightMouseDown:
                // Only clicks on the page pane around the panel close the
                // peek (Arc behavior). Sidebar/toolbar clicks pass through so
                // the user can switch tabs — the peek then hides with its
                // opener instead of closing.
                let location = NSEvent.mouseLocation
                if self.panel.frame.contains(location) {
                    return event
                }
                if let paneRect = self.anchorScreenRect(), paneRect.contains(location) {
                    self.closeHostedPeek()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
