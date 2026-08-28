// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Holds the native traffic lights at a fixed distance below the top of the
/// window, without reparenting or redrawing them.
///
/// The placement is absolute, not an offset from AppKit's: the titlebar height
/// Chromium reports is what AppKit centres the discs in, and anything that
/// re-heights or re-tiles that titlebar mid-session would leave a remembered
/// offset describing the wrong place. Asking for a distance from the top of
/// the window instead means every re-assert lands on the same line whatever
/// AppKit has just done.
///
/// AppKit owns the buttons' frames and restores them whenever it re-tiles the
/// titlebar (live resize, becoming key, navigation, fullscreen exit, …), so
/// this positioner re-asserts the shifted placement from observers on every
/// event known to trigger a restore. The titlebar container is grown to keep
/// the moved buttons inside it for hit-testing, and tracking areas are
/// refreshed so hover keeps working.
///
/// Two lifetimes exist today: the Kiosk window starts one at window setup and
/// never stops it, and `MainBrowserWindowController` runs one per layout — each
/// layout runs a different chrome row beside the lights, so it rebuilds the
/// positioner with a freshly measured offset whenever the layout changes,
/// calling `stop(restoringPlacement:)` first so the next measurement reads
/// AppKit's placement rather than this one.
@MainActor
final class TrafficLightPositioner: NSObject {
    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton,
    ]

    private weak var window: NSWindow?
    private weak var observedTitlebarContainer: NSView?
    private var observedTrafficLightButtons: [NSButton] = []
    private var titleObservation: NSKeyValueObservation?
    /// Where the discs' centre line should sit, as a distance from the top of
    /// the window.
    private let centerFromWindowTop: CGFloat
    /// The pre-shift placement, captured on the first apply so
    /// `stop(restoringPlacement: true)` can hand the titlebar back to AppKit
    /// exactly as it was found.
    private var originalTopMargin: CGFloat?
    private var originalContainerHeight: CGFloat?
    private var isApplying = false
    private var preFlushObserver: CFRunLoopObserver?
    /// Ahead of AppKit's flush observer, which sits at a large positive order,
    /// so the correction is in the frame AppKit is about to present.
    private static let preFlushObserverOrder: CFIndex = -1

    init(window: NSWindow, centerFromWindowTop: CGFloat) {
        self.window = window
        self.centerFromWindowTop = centerFromWindowTop
        super.init()
    }

    func start() {
        guard let window else { return }
        window.layoutIfNeeded()
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
        ]
        for notification in notifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowLayoutDidChange),
                name: notification,
                object: window
            )
        }
        titleObservation = window.observe(\.title, options: [.new]) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.apply()
            }
        }
        startPreFlushReassert()
        apply()
        DispatchQueue.main.async { [weak self] in
            self?.apply()
        }
    }

    /// Re-asserts once per run-loop pass, ahead of the window flush.
    ///
    /// The notifications above only cover re-tiles AppKit announces. It does
    /// not announce all of them — parenting the shared-window button onto a
    /// window being captured puts the discs back with no notification we
    /// observe — and correcting that one pass later is a correction the eye
    /// catches: the disc is seen at AppKit's line before it is seen at ours.
    ///
    /// A `beforeWaiting` observer ordered ahead of AppKit's own flush observer
    /// runs late enough to be after whatever moved them and early enough to be
    /// in the same presented frame, so the intermediate placement is corrected
    /// before it is ever drawn. `apply()` returns without writing a frame when
    /// the placement already holds, which is what makes running it this often
    /// affordable.
    private func startPreFlushReassert() {
        guard preFlushObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            Self.preFlushObserverOrder
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.apply()
            }
        }
        preFlushObserver = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func stopPreFlushReassert() {
        guard let preFlushObserver else { return }
        CFRunLoopRemoveObserver(
            CFRunLoopGetMain(),
            preFlushObserver,
            .commonModes
        )
        self.preFlushObserver = nil
    }

    /// Detaches every observer and stops holding the buttons. With
    /// `restoringPlacement` true (and the window not fullscreen), also puts
    /// the titlebar container and buttons back where AppKit had them; pass
    /// false when AppKit is about to rebuild the titlebar itself (a
    /// fullscreen transition), which restores the default placement on its
    /// own.
    func stop(restoringPlacement: Bool) {
        stopPreFlushReassert()
        titleObservation?.invalidate()
        titleObservation = nil
        NotificationCenter.default.removeObserver(self)

        defer {
            observedTitlebarContainer = nil
            observedTrafficLightButtons = []
            originalTopMargin = nil
            originalContainerHeight = nil
        }

        guard restoringPlacement,
              let window,
              !window.styleMask.contains(.fullScreen),
              let originalTopMargin,
              let originalContainerHeight,
              let titlebarContainer = observedTitlebarContainer,
              let containerSuperview = titlebarContainer.superview else {
            return
        }

        var containerFrame = titlebarContainer.frame
        containerFrame.size.height = originalContainerHeight
        containerFrame.origin.y = containerSuperview.bounds.maxY
            - originalContainerHeight
        titlebarContainer.setFrameOrigin(containerFrame.origin)
        titlebarContainer.setFrameSize(containerFrame.size)

        for button in observedTrafficLightButtons {
            guard let buttonSuperview = button.superview else { continue }
            let frameInContainer = buttonSuperview.convert(
                button.frame,
                to: titlebarContainer
            )
            let targetOriginInContainer = NSPoint(
                x: frameInContainer.minX,
                y: titlebarContainer.bounds.maxY - originalTopMargin
                    - button.frame.height
            )
            button.setFrameOrigin(
                buttonSuperview.convert(
                    targetOriginInContainer,
                    from: titlebarContainer
                )
            )
            button.updateTrackingAreas()
        }
        titlebarContainer.updateTrackingAreas()
    }

    func apply() {
        guard !isApplying,
              let window,
              !window.styleMask.contains(.fullScreen) else { return }
        let buttons = Self.buttonTypes.compactMap {
            window.standardWindowButton($0)
        }
        guard buttons.count == Self.buttonTypes.count,
              let closeButton = buttons.first,
              let closeButtonSuperview = closeButton.superview,
              let titlebarContainer = closeButton.superview?.superview,
              let containerSuperview = titlebarContainer.superview else {
            return
        }
        observeFrameChanges(
            of: titlebarContainer,
            trafficLightButtons: buttons
        )
        isApplying = true
        defer { isApplying = false }

        let buttonHeight = closeButton.frame.height
        if originalTopMargin == nil {
            let closeFrameInContainer = closeButtonSuperview.convert(
                closeButton.frame,
                to: titlebarContainer
            )
            originalTopMargin = titlebarContainer.bounds.maxY
                - closeFrameInContainer.maxY
            originalContainerHeight = titlebarContainer.frame.height
        }
        // Derived on every pass instead of remembered. The container is pinned
        // to the top of the frame view just below, so a margin measured from
        // its top is a margin from the top of the window — and one AppKit
        // cannot invalidate by changing its own idea of the titlebar.
        let targetTopMargin = max(0, centerFromWindowTop - buttonHeight / 2)

        // Every button, not just the leading one. AppKit does not always put
        // the three back together — installing the shared-window button on a
        // window being captured restores miniaturize and zoom while leaving
        // close where it was found — so a check that trusts one disc to speak
        // for the group reports that the placement holds and returns with the
        // other two still on AppKit's line.
        let placementHolds = abs(
            titlebarContainer.frame.height - (buttonHeight + 2 * targetTopMargin)
        ) < 0.01 && buttons.allSatisfy { button in
            guard let superview = button.superview else { return false }
            let frameInContainer = superview.convert(
                button.frame,
                to: titlebarContainer
            )
            return abs(
                titlebarContainer.bounds.maxY
                    - frameInContainer.maxY - targetTopMargin
            ) < 0.01
        }
        if placementHolds { return }

        var containerFrame = titlebarContainer.frame
        containerFrame.size.height = buttonHeight + 2 * targetTopMargin
        containerFrame.origin.y = containerSuperview.bounds.maxY
            - containerFrame.height
        titlebarContainer.setFrameOrigin(containerFrame.origin)
        titlebarContainer.setFrameSize(containerFrame.size)

        for button in buttons {
            guard let buttonSuperview = button.superview else { continue }
            let frameInContainer = buttonSuperview.convert(
                button.frame,
                to: titlebarContainer
            )
            let targetOriginInContainer = NSPoint(
                x: frameInContainer.minX,
                y: titlebarContainer.bounds.minY + targetTopMargin
            )
            button.setFrameOrigin(
                buttonSuperview.convert(
                    targetOriginInContainer,
                    from: titlebarContainer
                )
            )
            button.updateTrackingAreas()
        }
        titlebarContainer.updateTrackingAreas()
    }

    @objc private func windowLayoutDidChange(_ notification: Notification) {
        apply()
    }

    @objc private func nativeTitlebarFrameDidChange(
        _ notification: Notification
    ) {
        apply()
    }

    private func observeFrameChanges(
        of titlebarContainer: NSView,
        trafficLightButtons: [NSButton]
    ) {
        let hierarchyChanged = observedTitlebarContainer !== titlebarContainer
            || observedTrafficLightButtons.count != trafficLightButtons.count
            || !zip(observedTrafficLightButtons, trafficLightButtons)
                .allSatisfy { $0 === $1 }
        guard hierarchyChanged else { return }

        if let observedTitlebarContainer {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedTitlebarContainer
            )
        }
        for button in observedTrafficLightButtons {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: button
            )
        }
        observedTitlebarContainer = titlebarContainer
        observedTrafficLightButtons = trafficLightButtons

        // AppKit restores these frames during live resize and navigation.
        // Reapply synchronously so its default position is never presented.
        let observedViews = [titlebarContainer]
            + trafficLightButtons.map { $0 as NSView }
        for view in observedViews {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(nativeTitlebarFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: view
            )
        }
    }

    deinit {
        if let preFlushObserver {
            CFRunLoopRemoveObserver(
                CFRunLoopGetMain(),
                preFlushObserver,
                .commonModes
            )
        }
        NotificationCenter.default.removeObserver(self)
    }
}
