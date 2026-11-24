// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// The edge of the tab list the active tab went past, so the arrow sits there
/// and points toward it.
enum SidebarActiveTabArrowEdge: Equatable {
    case top
    case bottom
}

/// Geometry for `SidebarActiveTabArrowView`, kept static so it is tested
/// without a window.
enum SidebarActiveTabArrowResolver {
    /// Height of the strip the arrow slides within, one sidebar row.
    static let stripHeight: CGFloat = 36

    /// The edge whose arrow leads back to the active row, or nil while any of
    /// the row is in view. A partly visible row already tells the user where
    /// the active tab is. Both rects are in the flipped outline's coordinates,
    /// and `unobscuredVisibleRect` leaves out the sticky New Tab row.
    static func edge(activeRowRect: CGRect?, unobscuredVisibleRect: CGRect) -> SidebarActiveTabArrowEdge? {
        guard let rowRect = activeRowRect else { return nil }
        if rowRect.maxY <= unobscuredVisibleRect.minY { return .top }
        if rowRect.minY >= unobscuredVisibleRect.maxY { return .bottom }
        return nil
    }

    /// Where the arrow may draw: the visible list up to the New Tab row's
    /// near edge on its side, whether that is the sticky bar or the row
    /// itself scrolled into view. The arrow leaves past this edge, so it
    /// always disappears under the New Tab row, wherever the row is when it
    /// leaves. Flipped outline coordinates.
    static func clipRect(visibleRect: CGRect, overlayHeight: CGFloat,
                         newTabRowRect: CGRect?, newTabAtTop: Bool) -> CGRect {
        var minY = visibleRect.minY
        var maxY = visibleRect.maxY
        if newTabAtTop {
            minY += overlayHeight
            if let row = newTabRowRect, row.maxY > minY, row.maxY <= maxY {
                minY = row.maxY
            }
        } else {
            maxY -= overlayHeight
            if let row = newTabRowRect, row.minY < maxY, row.minY >= minY {
                maxY = row.minY
            }
        }
        return CGRect(x: visibleRect.minX, y: minY, width: visibleRect.width, height: max(0, maxY - minY))
    }

    /// The strip along `edge` of `unobscuredRect`, both in the container's
    /// coordinates. It stays inside the rect, so the arrow never covers the
    /// sticky New Tab row, and is never taller than the list.
    static func stripFrame(unobscuredRect: CGRect, edge: SidebarActiveTabArrowEdge,
                           containerIsFlipped: Bool) -> CGRect {
        let height = max(0, min(stripHeight, unobscuredRect.height))
        let atLowY = (edge == .top) == containerIsFlipped
        return CGRect(x: unobscuredRect.minX,
                      y: atLowY ? unobscuredRect.minY : unobscuredRect.maxY - height,
                      width: unobscuredRect.width, height: height)
    }
}

/// A filled arrow in a circle at the top or bottom edge of the tab list, shown
/// while the active tab is scrolled out of view. Clicking it scrolls the
/// active tab back. The view spans the list: the arrow rests in `stripRect`
/// and slides in from beyond the edge of `clipRect` and out the same way. A
/// mask clips it to `clipRect`, which the owner keeps on the New Tab row on
/// every scroll tick, so the arrow always slides out under that row. With
/// Reduce Motion it fades in place instead.
final class SidebarActiveTabArrowView: NSView {
    /// Runs when the arrow is clicked; the owner scrolls to the active tab.
    var clickAction: (() -> Void)?
    /// Reports the pointer entering and leaving the button. Rows beneath an
    /// overlay still get their own tracking events, so the owner suppresses
    /// row hover while this is true, as it does for `FloatingNewTabView`.
    var hoverStateChanged: ((Bool) -> Void)?
    /// The strip sits above the scroll view rather than inside it, so wheel
    /// events over the arrow are handed back to the list explicitly, as
    /// `FloatingNewTabView` does.
    weak var scrollView: NSScrollView?
    /// The edge the arrow is shown at, or nil while hidden or sliding out.
    private(set) var edge: SidebarActiveTabArrowEdge?

    /// The arrow inside the circle: Phi's primary text color of the opposite
    /// mode, the inverse of the strong-text circle (near-white on black in
    /// light mode, near-black on white in dark mode).
    static let arrowFill = ThemedColor { theme, appearance in
        theme.color(for: .textPrimary, appearance: appearance.opposite)
    }


    private static let buttonSize = NSSize(width: 32, height: 32)
    private static let symbolPointSize: CGFloat = 24
    private static let slideDuration: TimeInterval = 0.2

    private let button = NSButton()
    /// Bumped by every `setEdge(_:animated:reduceMotion:)` call, so the
    /// completion of a slide that was overtaken does nothing.
    private var transitionGeneration = 0
    /// While a slide runs, `layout()` leaves the button's frame to the animation.
    private var isSliding = false
    /// The band the arrow rests centered in, in this view's coordinates; the
    /// whole view when nil.
    var stripRect: NSRect? {
        didSet { if stripRect != oldValue { needsLayout = true } }
    }
    /// The area the arrow may draw in, in this view's coordinates; the whole
    /// view when nil. Moves without animation, so the edge stays on the New
    /// Tab row while the list scrolls.
    var clipRect: NSRect? {
        didSet {
            guard clipRect != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipMask.frame = clipRect ?? bounds
            CATransaction.commit()
        }
    }
    private let clipMask = CALayer()
    /// Whether `hoverStateChanged` last reported true.
    private var isPointerOverButton = false
    /// The symbol's palette: the arrow in `arrowFill`, the circle in Phi's
    /// opaque strong text color. Resolved each time the arrow appears and on
    /// appearance changes, as `SidebarDragAutoscrollCueView` does.
    private(set) var paletteColors: [NSColor] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = true
        clipMask.backgroundColor = NSColor.black.cgColor
        clipMask.frame = bounds
        layer?.mask = clipMask
        isHidden = true

        let title = NSLocalizedString(
            "sidebar.tabList.showActiveTabButton",
            value: "Show Active Tab",
            comment: "Sidebar tab list - Arrow button at the top or bottom edge of the list, shown while the active tab is scrolled out of view; clicking scrolls back to it")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = #selector(buttonClicked)
        button.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
        addSubview(button)
    }

    override func mouseEntered(with event: NSEvent) {
        guard edge != nil, !isPointerOverButton else { return }
        isPointerOverButton = true
        hoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        endHover()
    }

    /// A hidden view gets no exit event, so hiding ends the hover itself;
    /// otherwise the rows would stay hover-suppressed.
    private func endHover() {
        guard isPointerOverButton else { return }
        isPointerOverButton = false
        hoverStateChanged?(false)
    }

    override func layout() {
        super.layout()
        if clipRect == nil {
            clipMask.frame = bounds
        }
        guard !isSliding, edge != nil else { return }
        button.frame = restingFrame
    }

    /// Only the button takes clicks; the rest of the strip lets them through
    /// to the rows beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Shows the arrow at `edge`, or hides it for nil. Calling it again with
    /// the current edge does nothing, so the owner can call it on every scroll
    /// tick without restarting the slide.
    func setEdge(_ edge: SidebarActiveTabArrowEdge?, animated: Bool,
                 reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard edge != self.edge else { return }
        let previousEdge = self.edge
        self.edge = edge
        transitionGeneration += 1
        let generation = transitionGeneration

        guard let edge else {
            endHover()
            guard animated, let previousEdge else {
                finishHiding()
                return
            }
            runSlide(timing: .easeIn, generation: generation) {
                if reduceMotion {
                    self.button.animator().alphaValue = 0
                } else {
                    self.button.animator().frame = self.offscreenFrame(beyond: previousEdge)
                }
            } completion: { [weak self] in
                self?.finishHiding()
            }
            return
        }

        updateImage(for: edge)
        isHidden = false
        guard animated else {
            isSliding = false
            button.alphaValue = 1
            button.frame = restingFrame
            return
        }
        if reduceMotion {
            button.frame = restingFrame
            button.alphaValue = 0
        } else {
            button.alphaValue = 1
            button.frame = offscreenFrame(beyond: edge)
        }
        runSlide(timing: .easeOut, generation: generation) {
            if reduceMotion {
                self.button.animator().alphaValue = 1
            } else {
                self.button.animator().frame = self.restingFrame
            }
        } completion: {}
    }

    private func runSlide(timing: CAMediaTimingFunctionName, generation: Int,
                          changes: @escaping () -> Void,
                          completion: @escaping () -> Void) {
        isSliding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            changes()
        } completionHandler: { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            self.isSliding = false
            completion()
        }
    }

    private func finishHiding() {
        isSliding = false
        isHidden = true
        button.alphaValue = 1
    }

    /// Centered in the strip.
    private var restingFrame: NSRect {
        let size = Self.buttonSize
        let strip = stripRect ?? bounds
        return NSRect(x: strip.midX - size.width / 2,
                      y: strip.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Just past the clip edge on `edge`'s side, where the slide starts and
    /// ends; the mask hides it there.
    private func offscreenFrame(beyond edge: SidebarActiveTabArrowEdge) -> NSRect {
        var frame = restingFrame
        let clip = clipRect ?? bounds
        let beyondHighY = (edge == .top) != isFlipped
        frame.origin.y = beyondHighY ? clip.maxY : clip.minY - frame.height
        return frame
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let edge { updateImage(for: edge) }
    }

    private func updateImage(for edge: SidebarActiveTabArrowEdge) {
        // Opaque circle, so the rows beneath never show through.
        paletteColors = [Self.arrowFill.resolve(in: self),
                         ThemedColor.textPrimaryStrong.resolve(in: self)]
        let name = edge == .top ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: paletteColors))
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    @objc private func buttonClicked() {
        clickAction?()
    }
}
