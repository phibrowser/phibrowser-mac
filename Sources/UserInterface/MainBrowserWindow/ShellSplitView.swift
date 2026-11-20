// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// A sidebar column and a page area side by side, placed by frame from a
/// `ShellSplitGeometry`. No constraint ties one to the other, so resizing
/// the container costs one frame for the page area, and the column moves
/// only when its own width or side changes.
///
/// The page area is at the back and the column above it: while the column
/// is collapsed or a toggle is in flight the page area spans the container
/// and the column, if showing, lies over it. The divider is on top.
///
/// A toggle's motion is Core Animation's (`slideColumn`): explicit
/// animations on the two panes' layers, running on the render server while
/// the frames stay where the toggle's state put them. The main thread lays
/// nothing out per frame, and a busy one cannot stall the slide.
///
/// The view knows nothing about Spaces or the shell window.
final class ShellSplitView: NSView {
    /// How far under the column the page area's near edge is with the column
    /// fully in, tapering to nothing as the column leaves. Two layers that
    /// move on their own and only meet show what is behind them along the
    /// seam, as a line down the column's edge. And with the page card's
    /// margin, which is this wide, under the column, the card's edge is
    /// where it sits beside an open column: it does not step when the page
    /// area takes its narrow frame.
    static let pageOverlap = WebContentConstant.edgesSpacing
    static let slideAnimationKey = "shellSplit.slide"
    /// How long after a slide's duration its completion is called anyway.
    private static let slideCompletionMargin: TimeInterval = 0.3

    let divider = ShellSplitDividerView()
    private weak var columnView: NSView?
    private weak var pageView: NSView?

    var geometry = ShellSplitGeometry() {
        didSet {
            if geometry != oldValue { needsLayout = true }
        }
    }

    /// The container's width changed, and with it what the column can have.
    var onWidthChange: (() -> Void)?

    var isColumnHidden: Bool {
        get { columnView?.isHidden ?? true }
        set {
            guard let columnView, columnView.isHidden != newValue else { return }
            columnView.isHidden = newValue
        }
    }

    /// The fraction a slide added in this turn of the run loop starts from.
    /// Until Core Animation commits that slide, this is what is on screen;
    /// the presentation layer only answers for what has been committed.
    private var uncommittedSlideStart: CGFloat?

    /// How much of the column shows on screen right now: 1 for all of it, 0
    /// for none, in between during a slide.
    var shownColumnFraction: CGFloat {
        if let uncommittedSlideStart { return uncommittedSlideStart }
        guard let columnView, !columnView.isHidden else { return 0 }
        guard let layer = columnView.layer, layer.animation(forKey: Self.slideAnimationKey) != nil,
              columnView.frame.width > 0,
              let offset = (layer.presentation() ?? layer).value(forKeyPath: "transform.translation.x") as? NSNumber
        else { return 1 }
        return 1 - min(abs(CGFloat(offset.doubleValue)) / columnView.frame.width, 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizesSubviews = false
        divider.isHidden = true
        addSubview(divider)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitGroup)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(column: NSView, page: NSView) {
        for view in [page, column] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            // Each pane ends at its own frame, as an NSSplitView's do. Without
            // it nothing up to the window clips, and a pane's `visibleRect`,
            // with every `.inVisibleRect` tracking area in it, is the whole
            // window: the sidebar took a pointer over the page for its own.
            view.clipsToBounds = true
            addSubview(view, positioned: .below, relativeTo: divider)
        }
        columnView = column
        pageView = page
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        // Placed, never animated: a layout pass inside someone else's
        // animation group must not turn these frames into implicit motion.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        place(pageView, at: geometry.pageFrame(in: size))
        place(columnView, at: geometry.columnFrame(in: size))
        place(divider, at: geometry.dividerFrame(in: size))
        NSAnimationContext.endGrouping()
    }

    private func place(_ view: NSView?, at frame: NSRect) {
        guard let view, view.frame != frame else { return }
        view.frame = frame
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }

    /// Slides the column from where `flight` starts to where it ends, on the
    /// toggle's curve, and calls `completion` when it is there. The caller
    /// has the frames in their in-flight state already: the column shown at
    /// its place, the page area spanning the container.
    ///
    /// The column moves by its own width times the fraction hidden, toward
    /// its edge. The column pushes the page area along: the page's near edge
    /// stays under the column's inner edge (`pageOverlap`) and its far side
    /// overhangs the container. Both animations run on the same curve from
    /// the same commit, so the page stays under the column's edge on every
    /// frame.
    ///
    /// The animations hold their end value until `endSlide()`, which the
    /// caller pairs with the frames' end state in one turn: a main thread
    /// that is late to the landing delays the layout, not a frame.
    ///
    /// A slide with nowhere to go, or in a window that is not on screen, is
    /// not animated; its completion comes on the main queue's next turn.
    /// `completion` may be called more than once.
    func slideColumn(for flight: SidebarTransitions.Flight, completion: @escaping () -> Void) {
        guard flight.duration > 0, window?.isVisible == true,
              let columnLayer = columnView?.layer, let pageLayer = pageView?.layer else {
            endSlide()
            DispatchQueue.main.async(execute: completion)
            return
        }
        let width = geometry.columnFrame(in: bounds.size).width
        let outward: CGFloat = geometry.sidebarOnRight ? 1 : -1
        func slide(_ layer: CALayer, from: CGFloat, to: CGFloat) {
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = flight.duration
            animation.timingFunction = SidebarToggleAnimation.timingFunction
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: Self.slideAnimationKey)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        slide(columnLayer, from: outward * (1 - flight.startFraction) * width,
              to: outward * (1 - flight.endFraction) * width)
        let pageTravel = -outward * max(width - Self.pageOverlap, 0)
        slide(pageLayer, from: pageTravel * flight.startFraction, to: pageTravel * flight.endFraction)
        CATransaction.commit()
        noteUncommittedSlide(startingAt: flight.startFraction)
        // The completion block is Core Animation's to call; a slide must
        // land even if it never does.
        DispatchQueue.main.asyncAfter(deadline: .now() + flight.duration + Self.slideCompletionMargin,
                                      execute: completion)
    }

    /// Takes the slide's animations off, leaving the panes at their frames.
    func endSlide() {
        columnView?.layer?.removeAnimation(forKey: Self.slideAnimationKey)
        pageView?.layer?.removeAnimation(forKey: Self.slideAnimationKey)
        uncommittedSlideStart = nil
    }

    /// Remembers `fraction` as what is on screen until this turn's commit.
    /// The observer runs after Core Animation's own, which commits.
    private func noteUncommittedSlide(startingAt fraction: CGFloat) {
        uncommittedSlideStart = fraction
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, false, CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.uncommittedSlideStart = nil
            }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    override func accessibilitySplitters() -> [Any]? {
        divider.isHidden ? [] : [divider]
    }
}

/// The split's divider: the same strip, cursor and drag as the floating
/// panel's resize edge, and a splitter to accessibility.
final class ShellSplitDividerView: FloatingSidebarResizeHandleView {
    struct Range {
        var position: CGFloat
        var min: CGFloat
        var max: CGFloat
    }

    /// The divider's position in the split and how far it can go.
    var range: (() -> Range)?
    /// Moves the divider a step toward `range().max` or away from it.
    var onAccessibilityStep: ((_ towardMax: Bool) -> Void)?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }
    override func accessibilityValue() -> Any? { range.map { NSNumber(value: Double($0().position)) } }
    override func accessibilityMinValue() -> Any? { range.map { NSNumber(value: Double($0().min)) } }
    override func accessibilityMaxValue() -> Any? { range.map { NSNumber(value: Double($0().max)) } }

    override func accessibilityPerformIncrement() -> Bool {
        onAccessibilityStep?(true)
        return onAccessibilityStep != nil
    }

    override func accessibilityPerformDecrement() -> Bool {
        onAccessibilityStep?(false)
        return onAccessibilityStep != nil
    }
}
