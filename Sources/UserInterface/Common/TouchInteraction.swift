// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Observes direct-touch taps on a view and its subviews.
///
/// Physical mouse and trackpad clicks never trigger it (`buttonMask = 0`), and
/// it recognizes alongside every other recognizer, so the views keep their own
/// click handling and AppKit's touch-to-mouse emulation. Touches reach AppKit
/// only through gesture recognizers: event monitors, `sendEvent(_:)` and
/// tracking areas never see them.
@MainActor
final class TouchTapObserver: NSObject, NSGestureRecognizerDelegate {
    private let recognizer = NSClickGestureRecognizer()
    private let onTouchBegan: (() -> Void)?
    private let onTap: (NSPoint) -> Void

    /// `onTouchBegan` runs when a finger lands, before that touch's tap or
    /// emulated click is handled. `onTap` receives the tap location in window
    /// coordinates.
    init(view: NSView, onTouchBegan: (() -> Void)? = nil, onTap: @escaping (NSPoint) -> Void) {
        self.onTouchBegan = onTouchBegan
        self.onTap = onTap
        super.init()
        recognizer.target = self
        recognizer.action = #selector(handleTap(_:))
        recognizer.buttonMask = 0
        recognizer.allowedTouchTypes = .direct
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delaysSecondaryMouseButtonEvents = false
        recognizer.delaysOtherMouseButtonEvents = false
        recognizer.delaysKeyEvents = false
        recognizer.delaysMagnificationEvents = false
        recognizer.delaysRotationEvents = false
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }

    func invalidate() {
        recognizer.view?.removeGestureRecognizer(recognizer)
    }

    @objc private func handleTap(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onTap(recognizer.location(in: nil))
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        onTouchBegan?()
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Reports, once, that the physical pointer moved inside a view after a touch.
///
/// Ends touch-revealed UI when someone goes back to the mouse or trackpad.
/// AppKit may place the cursor where the finger landed, so motion that stays
/// at the last touch location does not count as pointer use.
@MainActor
final class PointerMotionObserver: NSResponder {
    private static let touchLocationTolerance: CGFloat = 4

    private weak var view: NSView?
    private var trackingArea: NSTrackingArea?
    private var lastTouchLocationInWindow: NSPoint
    private let onPointerMoved: () -> Void

    init(view: NSView, touchLocationInWindow: NSPoint, onPointerMoved: @escaping () -> Void) {
        self.view = view
        self.lastTouchLocationInWindow = touchLocationInWindow
        self.onPointerMoved = onPointerMoved
        super.init()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func noteTouch(at locationInWindow: NSPoint) {
        lastTouchLocationInWindow = locationInWindow
    }

    func invalidate() {
        if let trackingArea {
            view?.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let location = event.locationInWindow
        guard abs(location.x - lastTouchLocationInWindow.x) > Self.touchLocationTolerance
                || abs(location.y - lastTouchLocationInWindow.y) > Self.touchLocationTolerance else {
            return
        }
        invalidate()
        onPointerMoved()
    }
}

extension View {
    /// Reveals hover-only controls on a direct-touch tap and hides them again
    /// after a few seconds (HIG, "Touch support for hidden controls"). Pointer
    /// clicks are unaffected.
    func revealsOnTouchTap(_ isRevealed: Binding<Bool>) -> some View {
        modifier(TouchTapRevealModifier(isRevealed: isRevealed))
    }
}

private struct TouchTapRevealModifier: ViewModifier {
    private static let revealDuration: Duration = .seconds(4)

    @Binding var isRevealed: Bool
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(macOS 27, *) {
            content.simultaneousGesture(
                TapGesture(count: 1, inputKinds: .directTouch).onEnded { reveal() }
            )
        } else {
            content
        }
    }

    private func reveal() {
        isRevealed = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.revealDuration)
            guard !Task.isCancelled else { return }
            isRevealed = false
        }
    }
}
