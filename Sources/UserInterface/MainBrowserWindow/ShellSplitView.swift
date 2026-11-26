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
/// A toggle's motion is Core Animation's (`slideColumn`): the column's layer
/// slides and a mask on the page draws the card's near edge beside it, on
/// the render server while the frames stay where the toggle's state put
/// them. The main thread lays nothing out per frame, and a busy one cannot
/// stall the slide.
///
/// The view knows nothing about Spaces or the shell window.
final class ShellSplitView: NSView {
    /// The page's card as a toggle draws it: the page tree, laid out for the
    /// page area's in-flight frame, shows from the card's near edge on.
    struct SlidingPageCard {
        /// The presented page tree, filling the page area.
        let view: NSView
        /// The card's frame in `view`. Its top, bottom and corners shape the
        /// near edge; where that edge is comes from the column.
        let frame: NSRect
        let cornerRadius: CGFloat
        /// The card's margin on the column's side with the column away.
        let margin: CGFloat
    }

    static let slideAnimationKey = "shellSplit.slide"
    /// How long after a slide's duration its completion is called anyway.
    private static let slideCompletionMargin: TimeInterval = 0.3
    /// How often an expansion lays the page out on its way: a few times a
    /// toggle, not per frame.
    static let pageStepInterval = SidebarToggleAnimation.duration / 5

    let divider = ShellSplitDividerView()
    private weak var columnView: NSView?
    private weak var pageView: NSView?
    /// The card a toggle's mask draws; nil leaves the page unmasked.
    var pageCard: (() -> SlidingPageCard?)?
    private var pageCardMask: CALayer?
    private weak var maskedPageView: NSView?
    /// What a slide in flight takes off the page on the column's side, past
    /// the card's margin: the page area keeps its frame and its card, and
    /// the page in the card (`onPageInsetInFlight`) is laid out narrower.
    private(set) var pageInsetInFlight: CGFloat = 0
    /// Lays the page in the card out `pageInsetInFlight` in from the card's
    /// near edge. Called with 0 when the slide ends.
    var onPageInsetInFlight: ((CGFloat) -> Void)?
    /// Bumped by `endSlide()`, so a step of a slide that ended is dropped.
    private var pageStepsGeneration = 0

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
    /// its edge. The page area does not move. A mask on the page
    /// (`maskPageCard`) hides it up to where the card's near edge would be
    /// beside the column on screen, on the same curve from the same commit,
    /// so the card's edge stays on the column however late the main thread
    /// is. In the card the page is laid out for the slide (`stepPage`), its
    /// far side still and its near side at the column or under it.
    ///
    /// The animations hold their end value until `endSlide()`, which the
    /// caller pairs with the frames' end state in one turn: a main thread
    /// that is late to the landing delays the layout, not a frame.
    ///
    /// A slide with nowhere to go, or in a window that is not on screen, is
    /// not animated; its completion comes on the main queue's next turn.
    /// `completion` may be called more than once.
    func slideColumn(for flight: SidebarTransitions.Flight, completion: @escaping () -> Void) {
        guard flight.duration > 0, window?.isVisible == true, let columnLayer = columnView?.layer else {
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
        let card = pageCard?()
        if let card, let mask = maskPageCard(card) {
            // The card's near edge, `margin` from the container's edge with
            // the column away and at the column's inner edge with it in.
            func nearEdge(_ fraction: CGFloat) -> CGFloat {
                let inset = card.margin + (width - card.margin) * fraction
                return geometry.sidebarOnRight ? bounds.width - inset : inset
            }
            slide(mask, from: nearEdge(flight.startFraction), to: nearEdge(flight.endFraction))
        }
        CATransaction.commit()
        stepPage(for: flight, travel: width - (card?.margin ?? 0))
        noteUncommittedSlide(startingAt: flight.startFraction)
        // The completion block is Core Animation's to call; a slide must
        // land even if it never does.
        DispatchQueue.main.asyncAfter(deadline: .now() + flight.duration + Self.slideCompletionMargin,
                                      execute: completion)
    }

    /// Lays the page in the card out for the slide, never narrower than the
    /// card shows: Chromium draws a width some frames late, and a page laid
    /// out short of the column leaves a strip of bare card between them.
    ///
    /// A collapse uncovers the page, so it takes the landing's width now and
    /// Chromium draws it once, under the column. An expansion covers it: the
    /// page follows the column (`followColumn`), and the landing has little
    /// or no width left to lay out.
    ///
    /// What it costs:
    /// - A collapse shows the page laid out for the landing while the card
    ///   is still narrower, its content off center until the column is out.
    ///   Until Chromium draws that width, a frame or two, the card (in the
    ///   page's background) shows beside the column: a short notch where the
    ///   page's near content differs from its background.
    /// - An expansion trails the column: when the column stops, the page is
    ///   up to a step (about 50pt) short and gets there 2–3 frames later,
    ///   the toolbar's leading buttons under the column meanwhile. Stepping
    ///   ahead of the column settled a frame sooner but left bare card
    ///   between them.
    private func stepPage(for flight: SidebarTransitions.Flight, travel: CGFloat) {
        guard !flight.collapsing else {
            setPageInsetInFlight(0)
            return
        }
        setPageInsetInFlight(travel * flight.startFraction)
        followColumn(travel: travel, generation: pageStepsGeneration)
    }

    /// Every `pageStepInterval` until the column is all in, lays the page
    /// out to where the column is on screen.
    private func followColumn(travel: CGFloat, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageStepInterval) { [weak self] in
            guard let self, self.pageStepsGeneration == generation else { return }
            let shown = self.shownColumnFraction
            self.setPageInsetInFlight(travel * shown)
            if shown < 1 {
                self.followColumn(travel: travel, generation: generation)
            }
        }
    }

    private func setPageInsetInFlight(_ inset: CGFloat) {
        let inset = inset.rounded(.down)
        guard inset != pageInsetInFlight else { return }
        pageInsetInFlight = inset
        onPageInsetInFlight?(inset)
    }

    /// Masks `card.view` to everything on the far side of an edge at the
    /// mask's x translation, with the card's near corners rounded there.
    private func maskPageCard(_ card: SlidingPageCard) -> CALayer? {
        guard let layer = card.view.layer else { return nil }
        let onRight = geometry.sidebarOnRight
        // Well past the container on every side the mask leaves open.
        let reach = 4 * max(bounds.width, bounds.height)
        let cardRect = card.view.convertToLayer(card.frame)
        let x = onRight ? -reach : 0
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: bounds.size)
        let cardPiece = CALayer()
        cardPiece.frame = CGRect(x: x, y: cardRect.minY, width: reach, height: cardRect.height)
        cardPiece.cornerRadius = card.cornerRadius
        cardPiece.cornerCurve = .continuous
        cardPiece.maskedCorners = onRight
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let above = CALayer()
        above.frame = CGRect(x: x, y: cardRect.maxY, width: reach, height: reach)
        let below = CALayer()
        below.frame = CGRect(x: x, y: cardRect.minY - reach, width: reach, height: reach)
        for piece in [cardPiece, above, below] {
            piece.backgroundColor = NSColor.black.cgColor
            mask.addSublayer(piece)
        }
        removePageCardMask()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = mask
        CATransaction.commit()
        pageCardMask = mask
        maskedPageView = card.view
        return mask
    }

    private func removePageCardMask() {
        if let pageCardMask, let layer = maskedPageView?.layer, layer.mask === pageCardMask {
            layer.mask = nil
        }
        pageCardMask = nil
    }

    /// Takes the slide's animations off, leaving the panes at their frames.
    func endSlide() {
        columnView?.layer?.removeAnimation(forKey: Self.slideAnimationKey)
        removePageCardMask()
        pageStepsGeneration += 1
        setPageInsetInFlight(0)
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
