// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// The standalone window that asks for a new Kiosk's URL, in the top-right
/// corner of the screen the user is working on. It is a non-activating
/// panel, like Spotlight: it takes keyboard focus without activating Phi, so
/// a hidden app's other windows stay hidden. The omnibox in it runs against an
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

        /// The transparent shadow margin reaches into the menu bar; AppKit's
        /// default would push the whole panel, and the box, down below it.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// Transparent room around the box for its shadow (`OmniBoxViewController`
    /// draws a 50pt blur offset 20pt down). The panel clips everything it
    /// draws, so a narrower margin cuts the soft shadow off at the panel's
    /// edges into a visible gray rectangle behind the rounded box.
    static let shadowMargin: CGFloat = 80
    static let boxWidth: CGFloat = 450
    static let rightInset: CGFloat = 12
    static let topInset: CGFloat = 40

    static var panelSize: NSSize {
        NSSize(
            width: boxWidth + shadowMargin * 2,
            height: OmniBoxContainerViewController.maxOmniBoxHeight + shadowMargin * 2
        )
    }

    /// The box's top-right corner, inset from the visible frame's top-right
    /// corner and moved in only when the box would not fit.
    static func boxTopRight(onVisibleFrame visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: max(visibleFrame.maxX - rightInset, visibleFrame.minX + boxWidth),
            y: max(
                visibleFrame.maxY - topInset,
                visibleFrame.minY + OmniBoxContainerViewController.maxOmniBoxHeight
            )
        )
    }

    /// The box is centered in the panel, so only the transparent shadow
    /// margin reaches past the visible frame. The box grows downward as
    /// suggestions arrive, so the panel is sized for the tallest box from the
    /// start.
    static func frame(onVisibleFrame visibleFrame: NSRect) -> NSRect {
        let topRight = boxTopRight(onVisibleFrame: visibleFrame)
        return NSRect(
            x: (topRight.x + shadowMargin - panelSize.width).rounded(),
            y: (topRight.y + shadowMargin - panelSize.height).rounded(),
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// The screen of the window the user is working in: Phi's key window
    /// while Phi is active, otherwise the frontmost window of the active app
    /// (the global shortcut pressed in another app).
    static func activeWindowScreen() -> NSScreen? {
        if NSApp.isActive, let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen {
            return screen
        }
        if let frame = frontmostApplicationWindowFrame(),
           let screen = NSScreen.screens.first(where: {
               $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
           }) {
            return screen
        }
        return NSScreen.main
    }

    /// Window bounds need no Screen Recording permission, unlike titles.
    private static func frontmostApplicationWindowFrame() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primaryScreenFrame = NSScreen.screens.first?.frame,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }
            // Quartz window bounds are top-left based on the primary screen.
            return NSRect(
                x: bounds.minX,
                y: primaryScreenFrame.maxY - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
        }
        return nil
    }

    let panel: NSPanel
    let container: OmniBoxContainerViewController
    private let backgroundView = EventBlockBgView()
    private var onFinish: ((String?) -> Void)?
    private var hostCloseObserver: NSObjectProtocol?

    var isFinished: Bool { onFinish == nil }

    var boxTopRight: NSPoint {
        NSPoint(
            x: panel.frame.maxX - Self.shadowMargin,
            y: panel.frame.maxY - Self.shadowMargin
        )
    }

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
            isDetachedFromHostWindow: true,
            fixedBoxWidth: Self.boxWidth
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
                Self.frame(onVisibleFrame: visibleFrame),
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

/// A Kiosk keyed while Phi is still inactive loses key when Phi's
/// activation lands: AppKit's activation pass re-keys the window Phi last
/// had key. One turn after an activation within `timeout`, the Kiosk takes
/// key back.
@MainActor
enum KioskActivationKeyReclaim {
    static let timeout: TimeInterval = 1

    private static var observer: NSObjectProtocol?
    private static var generation = 0

    static func start(
        for window: NSWindow,
        notificationCenter: NotificationCenter = .default,
        activationNotificationObject: Any? = NSApp
    ) {
        stop(notificationCenter: notificationCenter)
        generation += 1
        let startedGeneration = generation
        observer = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: activationNotificationObject,
            queue: nil
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                stop(notificationCenter: notificationCenter)
                DispatchQueue.main.async {
                    guard let window, window.isVisible, !window.isKeyWindow else { return }
                    AppLogDebug("[KioskLaunch] reclaiming key after activation")
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard generation == startedGeneration else { return }
            stop(notificationCenter: notificationCenter)
        }
    }

    private static func stop(notificationCenter: NotificationCenter) {
        if let observer { notificationCenter.removeObserver(observer) }
        observer = nil
    }
}
