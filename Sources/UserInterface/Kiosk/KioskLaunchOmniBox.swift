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
/// and Kiosk windows never host it. While Phi is not the active app (the
/// global shortcut from another app), the standalone panel asks as well.
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
    ///   - applicationIsActive: macOS may refuse to activate Phi from a
    ///     global shortcut, and a browser window of an inactive app gets no
    ///     typing. The non-activating panel takes key without activation.
    static func target(
        windowsFrontToBack: [Window],
        activeWindowId: Int?,
        applicationIsHidden: Bool,
        applicationIsActive: Bool
    ) -> Target {
        guard !applicationIsHidden, applicationIsActive else { return .standalone }
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

    /// Transparent room around the box for its shadow (`OmniBoxViewController`
    /// draws a 50pt blur offset 20pt down). The panel clips everything it
    /// draws, so a narrower margin cuts the soft shadow off at the panel's
    /// edges into a visible gray rectangle behind the rounded box.
    static let shadowMargin: CGFloat = 80
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
        // The host Browser only supplies suggestions: its window, sidebar,
        // and tabs are not behind this panel.
        container = OmniBoxContainerViewController(
            browserState: browserState,
            superView: backgroundView,
            isDetachedFromHostWindow: true
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

/// Opens the Kiosk picked in the launch omnibox only once Phi is active, so
/// the new Kiosk takes key and keeps it. A submission from the standalone
/// panel arrives while Phi may still be inactive (the panel does not
/// activate it), and activating can bring an existing window forward at
/// the end of the activation; opening after that settles lets the Kiosk win
/// the final ordering. An active app still waits one turn, for the omnibox
/// hide that is under way to hand key back first. If activation never
/// arrives, `fallbackDelay` later the Kiosk opens anyway.
@MainActor
struct KioskLaunchActivation {
    static let fallbackDelay: TimeInterval = 0.5

    var isApplicationActive: () -> Bool = { NSApp.isActive }
    var activateApplication: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var notificationCenter: NotificationCenter = .default
    var activationNotificationObject: Any? = NSApp
    var scheduleNextTurn: (@escaping () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }
    var scheduleFallback: (@escaping () -> Void) -> Void = {
        DispatchQueue.main.asyncAfter(deadline: .now() + KioskLaunchActivation.fallbackDelay, execute: $0)
    }

    func perform(_ action: @escaping () -> Void) {
        guard !isApplicationActive() else {
            scheduleNextTurn(action)
            return
        }
        let pending = Pending(
            action: action,
            notificationCenter: notificationCenter,
            scheduleNextTurn: scheduleNextTurn
        )
        pending.observer = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: activationNotificationObject,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                pending.runAfterActivation()
            }
        }
        scheduleFallback { pending.run() }
        activateApplication()
    }

    /// Runs its action at most once, whichever of activation and the
    /// fallback comes first.
    @MainActor
    private final class Pending {
        private var action: (() -> Void)?
        private let notificationCenter: NotificationCenter
        private let scheduleNextTurn: (@escaping () -> Void) -> Void
        var observer: NSObjectProtocol?

        init(
            action: @escaping () -> Void,
            notificationCenter: NotificationCenter,
            scheduleNextTurn: @escaping (@escaping () -> Void) -> Void
        ) {
            self.action = action
            self.notificationCenter = notificationCenter
            self.scheduleNextTurn = scheduleNextTurn
        }

        /// One turn after activation, once its own ordering pass is done.
        func runAfterActivation() {
            stopObserving()
            scheduleNextTurn { [self] in run() }
        }

        func stopObserving() {
            if let observer { notificationCenter.removeObserver(observer) }
            observer = nil
        }

        func run() {
            stopObserving()
            guard let action else { return }
            self.action = nil
            action()
        }
    }
}
