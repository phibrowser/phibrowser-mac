// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Decides where a new empty Kiosk asks for its URL. The Kiosk window is
/// only created once the user has picked a destination: until then the
/// omnibox lives either in a main browser window already on screen, or in
/// the standalone `KioskLaunchOmniBoxPanelController` when there is none —
/// main windows that are closed, hidden, or miniaturized count as absent,
/// and Kiosk windows never host it.
enum KioskLaunchOmniBoxRouting {
    struct Window: Equatable {
        let windowId: Int
        /// A user-facing main browser window, not a Kiosk, shadow, popup,
        /// or other auxiliary Browser.
        let isMainBrowserWindow: Bool
        /// Ordered in, not miniaturized, and the presented session of its
        /// shell.
        let isOnScreen: Bool
        let isOnActiveSpace: Bool
    }

    enum Target: Equatable {
        case browserWindow(windowId: Int)
        case standalone
    }

    static func isMainBrowserWindowType(_ type: ChromiumBrowserType) -> Bool {
        switch type {
        case .normal, .incognito, .incognitoSpace:
            return true
        default:
            return false
        }
    }

    /// - Parameters:
    ///   - windowsFrontToBack: Phi's windows in z-order, frontmost first.
    ///   - activeWindowId: The manager's active browser window, preferred
    ///     among equally eligible windows.
    ///   - applicationIsHidden: Cmd+H hides every window; revealing one to
    ///     host the omnibox would bring them all back.
    static func target(
        windowsFrontToBack: [Window],
        activeWindowId: Int?,
        applicationIsHidden: Bool
    ) -> Target {
        guard !applicationIsHidden else { return .standalone }
        let eligible = windowsFrontToBack.filter {
            $0.isMainBrowserWindow && $0.isOnScreen
        }
        // A window on the current desktop wins over one that activating
        // would switch Spaces to; the active window wins among equals.
        let preferred = eligible.filter(\.isOnActiveSpace)
        let pool = preferred.isEmpty ? eligible : preferred
        if let activeWindowId,
           pool.contains(where: { $0.windowId == activeWindowId }) {
            return .browserWindow(windowId: activeWindowId)
        }
        if let frontmost = pool.first {
            return .browserWindow(windowId: frontmost.windowId)
        }
        return .standalone
    }
}

/// The standalone window that asks for a new Kiosk's URL when no main
/// browser window is on screen. It is a non-activating panel, like
/// Spotlight: it takes keyboard focus without activating Phi, so a hidden
/// app's other windows stay hidden. The omnibox in it runs against an
/// existing Browser's state (`browserState`), which supplies Chromium's
/// suggestions; no Kiosk exists until a submission arrives.
///
/// Exactly one `onFinish` call ends the panel: with the destination URL
/// on submission, or nil when it is dismissed (Escape, a click outside,
/// focus moving elsewhere, the host Browser closing).
@MainActor
final class KioskLaunchOmniBoxPanelController: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Room around the box for its shadow.
    static let shadowMargin: CGFloat = 30
    /// Share of the screen's visible height left above the box.
    static let topOffsetRatio: CGFloat = 0.22

    static var panelSize: NSSize {
        NSSize(
            width: OmniBoxViewController.boxWidth + shadowMargin * 2,
            height: OmniBoxContainerViewController.maxOmniBoxHeight + shadowMargin * 2
        )
    }

    /// Centered horizontally, with the box's top edge a fixed share of the
    /// visible height below the top, kept inside the visible frame. The box
    /// grows downward as suggestions arrive, so the panel is sized for the
    /// tallest box from the start.
    static func frame(size: NSSize, onVisibleFrame visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let boxTop = visibleFrame.maxY - visibleFrame.height * topOffsetRatio
        let proposedY = boxTop + shadowMargin - height
        let y = max(visibleFrame.minY, min(proposedY, visibleFrame.maxY - height))
        return NSRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: y.rounded(),
            width: width,
            height: height
        )
    }

    let panel: NSPanel
    let container: OmniBoxContainerViewController
    private let backgroundView = EventBlockBgView()
    private var onFinish: ((String?) -> Void)?
    private var hostCloseObserver: NSObjectProtocol?

    var isFinished: Bool { onFinish == nil }

    init(
        browserState: BrowserState,
        hostWindow: NSWindow?,
        onFinish: @escaping (String?) -> Void
    ) {
        panel = Panel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        container = OmniBoxContainerViewController(
            browserState: browserState,
            superView: backgroundView
        )
        self.onFinish = onFinish
        super.init()
        configurePanel()
        if let hostWindow {
            hostCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: hostWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                }
            }
        }
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Shown while Phi itself is hidden (Cmd+H) without unhiding it.
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle
        ]
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        panel.delegate = self
    }

    func present(on screen: NSScreen?) {
        guard !isFinished, let contentView = panel.contentView else { return }
        if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrame(
                Self.frame(size: Self.panelSize, onVisibleFrame: visibleFrame),
                display: false
            )
        }
        contentView.addSubview(backgroundView)
        backgroundView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        let containerView = container.view
        backgroundView.addSubview(containerView)
        containerView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        container.handOffNextSubmission(
            onSubmit: { [weak self] url in
                self?.finish(with: url)
            },
            onDismissWithoutSubmission: { [weak self] in
                self?.finish(with: nil)
            }
        )
        panel.orderFrontRegardless()
        panel.makeKey()
        contentView.layoutSubtreeIfNeeded()
        container.omniBoxController?.beginOpenTrace(
            trigger: "kiosk-launch",
            addressViewPresent: false
        )
        container.showOmniBox(fromAddressBar: false)
    }

    /// Ends the panel without a submission.
    func dismiss() {
        guard !isFinished else { return }
        if container.hasShown {
            // Ends the handoff, which finishes the panel.
            container.hideOmniBox()
        }
        finish(with: nil)
    }

    private func finish(with url: String?) {
        guard let onFinish else { return }
        self.onFinish = nil
        if let hostCloseObserver {
            NotificationCenter.default.removeObserver(hostCloseObserver)
        }
        hostCloseObserver = nil
        // While the panel is still key: a Kiosk opened from Return lands on
        // the screen of the key window.
        onFinish(url)
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}
