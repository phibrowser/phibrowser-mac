// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Container view for the active WebContent area that also accepts a tab drag
/// dropped on one of its four edge thirds to start a new split:
///
/// - Left / right third → side-by-side split (`.vertical`). The dragged tab
///   lands in the dropped pane; the focused tab takes the other.
/// - Top / bottom third → stacked split (`.horizontal`). The dragged tab
///   lands in the dropped pane (top = primary, bottom = secondary).
///
/// The drop is only accepted when:
/// - the drag comes from the same window (cross-window drops fall through to
///   the existing new-window tear-off flow);
/// - the focused tab exists and is not the dragged tab;
/// - the focused tab is not already part of a split (per user requirement —
///   "When you drag a tab to a splitview page, remain the old logic");
/// - the cursor sits in one of the four edge thirds of the container.
///
/// Visual hint: while a valid drag is hovering anywhere over the page area,
/// all four directional hint cards are shown with a dashed border. The center
/// band is a no-drop area. Replace mode still shows only the existing panes.
///
/// Mouse events are not affected: `contentContainer` does not override
/// `hitTest`, so children (the Chromium native view) continue to receive
/// clicks as before.
final class SplitTabDropContainer: NSView {

    /// Fraction of the container's width that counts as a "drop here to
    /// split" zone, measured from each side edge.
    private static let edgeDropZoneFraction: CGFloat = 1.0 / 3.0

    /// Reference geometry from Figma node 5653:25780. Visual hint cards scale
    /// uniformly inside the page area so wide or tall windows cannot stretch
    /// them back into the neighboring directional cards. Hit testing remains
    /// based on the edge thirds above and is intentionally independent.
    private static let dropHintReferenceSize = CGSize(width: 1290, height: 689)
    private static let sideDropHintReferenceSize = CGSize(width: 160, height: 460)
    private static let horizontalDropHintReferenceSize = CGSize(width: 300, height: 120)
    private static let sideDropHintReferenceInset: CGFloat = 14
    private static let horizontalDropHintReferenceInset: CGFloat = 18
    private static let activeDropHintScale: CGFloat = 1.1
    private static let dropHintCornerRadius: CGFloat = 32
    private static let dropHintLineWidth: CGFloat = 1
    private static let dropHintLineDashPattern: [NSNumber] = [8, 10]
    private static let dropHintWhiteOverlayOpacity: CGFloat = 0.60
    private static let dropHintLabelHorizontalInset: CGFloat = 16
    private static let dropHintLabelVerticalInset: CGFloat = 12
    private static let dropHintAttractAnimationDuration: CFTimeInterval = 0.16
    private static let dropHintFollowAnimationDuration: CFTimeInterval = 0.12
    private static let dropHintSettleAnimationDuration: CFTimeInterval = 0.20
    // Approach closes the primary-axis gap in one animated target. Follow uses
    // lower gains so pointer tremor becomes sub-point card movement.
    private static let approachingPrimaryAxisGain: CGFloat = 1.0
    private static let approachingSecondaryAxisGain: CGFloat = 0
    private static let dropHintApproachCaptureDepth: CGFloat = 2
    private static let followingPrimaryAxisGain: CGFloat = 0.30
    private static let followingSecondaryAxisGain: CGFloat = 0.10
    private static let dropHintContainmentTolerance: CGFloat = 1
    private static let dropHintZoneExitTolerance: CGFloat = 12
    /// Portion of the page width/height available to each directional card.
    /// `0.5` reaches the center line; `0.45` leaves a 10% central dead band.
    /// Values are constrained to the minimum needed to contain the expanded
    /// card...0.5. Initial activation remains based on the edge thirds above.
    static let dropHintMovementRangeFraction: CGFloat = 0.25
    /// Scales only the space in which the card can translate, excluding the
    /// card's own width or height from the configured movement range.
    static let dropHintMovementTravelScale: CGFloat = 0.25
    /// Overall opacity of the frosted-glass card. Kept at 1.0 so the
    /// material's own translucency carries the see-through effect —
    /// `NSGlassEffectView` and `.fullScreenUI` already let page content
    /// bleed through; dropping `alphaValue` further makes the card read
    /// as thin film rather than a solid glass panel.
    private static let dropHintGlassOpacity: CGFloat = 1.0

    /// Supplies the actual web-page area (in this view's coordinate space)
    /// so the highlight and trigger zones avoid covering the URL bar and
    /// bookmark bar above it. Returns nil if no page is currently mounted,
    /// in which case the full bounds are used as a fallback.
    var pageAreaProvider: (() -> CGRect?)?

    enum DropZone: Hashable {
        case left
        case right
        case top
        case bottom

        /// Layout a create-mode drop onto this zone produces. The layout cases
        /// name the divider orientation, not the pane arrangement.
        var layout: SplitLayout {
            switch self {
            case .left, .right: return .vertical
            case .top, .bottom: return .horizontal
            }
        }

        /// Whether the dragged content lands in Chromium's primary slot.
        var isPrimarySlot: Bool {
            switch self {
            case .left, .top: return true
            case .right, .bottom: return false
            }
        }

        var labelText: String {
            switch self {
            case .left:   return NSLocalizedString("browser.splitDropHint.leftThird", value: "Add Left Split", comment: "Drop-zone hint shown when dragging a tab over the left third of the page")
            case .right:  return NSLocalizedString("browser.splitDropHint.rightThird", value: "Add Right Split", comment: "Drop-zone hint shown when dragging a tab over the right third of the page")
            case .top:    return NSLocalizedString("browser.splitDropHint.topThird", value: "Add Top Split", comment: "Drop-zone hint shown when dragging a tab over the top third of the page")
            case .bottom: return NSLocalizedString("browser.splitDropHint.bottomThird", value: "Add Bottom Split", comment: "Drop-zone hint shown when dragging a tab over the bottom third of the page")
            }
        }
    }

    private static let allZones: [DropZone] = [.left, .right, .top, .bottom]

    /// What a drop will do, decided by whether the focused tab is a split.
    /// `create` (focused tab not a split): four directional edge zones form a
    /// side-by-side or stacked split. `replace` (focused tab is a split):
    /// per-pane zones swap the dragged tab into one existing pane.
    private enum Mode: Equatable {
        case create
        case replace(splitId: String)
    }

    private enum HintFrameTransition {
        case attract
        case follow
        case settle

        var duration: CFTimeInterval {
            switch self {
            case .attract: return dropHintAttractAnimationDuration
            case .follow: return dropHintFollowAnimationDuration
            case .settle: return dropHintSettleAnimationDuration
            }
        }

        var timingFunction: CAMediaTimingFunction {
            switch self {
            case .attract:
                return CAMediaTimingFunction(name: .easeOut)
            case .follow:
                return CAMediaTimingFunction(name: .linear)
            case .settle:
                return CAMediaTimingFunction(name: .easeInEaseOut)
            }
        }
    }

    weak var browserState: BrowserState?

    /// Groups every material-backed surface element under one transform. The
    /// view is presentation-only and must never intercept Chromium input.
    private final class HintSurfaceView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct HintCard {
        let surface: HintSurfaceView
        let glass: NSView
        let highlight: CAGradientLayer
        let whiteOverlay: CAShapeLayer
        let activeMask: CAShapeLayer
        let border: CAShapeLayer
        let label: NSTextField
    }

    /// Left/right cards are also reused for replace mode. Top/bottom are only
    /// visible while creating a new split.
    private let cards: [DropZone: HintCard]

    private static func makeSurfaceView() -> HintSurfaceView {
        let view = HintSurfaceView()
        view.wantsLayer = true
        view.layer?.zPosition = 9_999
        view.isHidden = true
        return view
    }

    /// macOS 26+ exposes `NSGlassEffectView` (Apple's Liquid Glass) which
    /// already renders with its own blur, refraction, and edge highlight
    /// — exactly the look we were faking with NSVisualEffectView + white
    /// fill + gradient. On older systems we keep the
    /// ColoredVisualEffectView fallback used by the floating sidebar
    /// (`WebContentContainerViewController+FloatingSidebar.swift:91`) so
    /// the drop hint stays consistent with the rest of the app's chrome.
    private static func makeGlassView() -> NSView {
        let view: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = dropHintCornerRadius
            // `NSGlassEffectView` requires a contentView; an empty layer-
            // backed view is fine since the label and dashed border are
            // siblings of the glass (drawn directly by the container) and
            // the highlight gradient is added to `glass.layer` below.
            let content = NSView()
            content.wantsLayer = true
            glass.contentView = content
            view = glass
        } else {
            let fx = ColoredVisualEffectView()
            fx.backgroundColor = NSColor.white.withAlphaComponent(0.85)
            fx.material = .fullScreenUI
            fx.blendingMode = .withinWindow
            fx.state = .active
            view = fx
        }
        view.alphaValue = dropHintGlassOpacity
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = dropHintCornerRadius
        view.layer?.masksToBounds = true
        // The surface container owns stacking above Chromium. Keep the effect
        // view at the bottom of that local layer tree so its tint and active
        // scrim can render above the material.
        view.layer?.zPosition = 0
        view.isHidden = true
        return view
    }

    /// Subtle white-to-transparent gradient sublayer that fakes the
    /// top-edge "glass shine" from the Figma. NSVisualEffectView alone
    /// can't render an inner highlight, so we paint one ourselves and
    /// clip it to the card's rounded shape via the glass view's layer.
    /// Gradient unit space: (0,0) bottom-left, (1,1) top-right — so a
    /// `(0.5, 1) → (0.5, 0.5)` axis lights the top half and fades out
    /// to clear by mid-card.
    private static func makeHighlightGradient() -> CAGradientLayer {
        // NSGlassEffectView on macOS 26+ already ships with its own edge
        // shine; on the NSVisualEffectView fallback path this gradient
        // does the "top glass highlight" by itself. Keep the alpha modest
        // so both paths read consistently — the Liquid Glass effect won't
        // be doubled up by a strong overlay.
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.4)
        return gradient
    }

    /// Theme tint drawn above the clear glass and below the active scrim. It
    /// keeps the page visible through the card while improving legibility.
    private static func makeWhiteOverlayLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.white
            .withAlphaComponent(dropHintWhiteOverlayOpacity)
            .cgColor
        layer.strokeColor = nil
        layer.isHidden = true
        layer.zPosition = 0.25
        return layer
    }

    /// Darkening scrim layered over whichever card the cursor is currently
    /// resolving to as the drop target, so the user can tell the two hint
    /// cards apart at a glance (Figma shows the active card tinted grey
    /// against the sibling's plain glass). A flat black alpha reads
    /// consistently on both the light glass fill and arbitrary page content
    /// behind it, unlike a literal light-grey fill which would wash out in
    /// dark mode — same reasoning as `applyThemeColors`' stroke color.
    ///
    /// A `CAShapeLayer` sibling of the glass inside the shared surface rather
    /// than a sublayer of the glass itself: `NSGlassEffectView` composites its
    /// Liquid Glass content over its own sublayers on macOS 26+, so a scrim
    /// placed there can sit invisibly underneath it.
    private static func makeActiveMaskLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.black.withAlphaComponent(0.06).cgColor
        layer.strokeColor = nil
        layer.isHidden = true
        // Sits above the glass and white tint inside the surface, below the
        // dashed border.
        layer.zPosition = 0.5
        return layer
    }

    private static func makeBorderLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineWidth = dropHintLineWidth
        layer.lineDashPattern = dropHintLineDashPattern
        layer.lineCap = .round
        layer.isHidden = true
        // Shares the surface transform so the stroke cannot lag behind the
        // material during attraction or settling.
        layer.zPosition = 1
        return layer
    }

    private static func makeDropLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.textColor = .labelColor
        field.font = .systemFont(ofSize: 14, weight: .regular)
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.translatesAutoresizingMaskIntoConstraints = true
        field.isHidden = true
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.wantsLayer = true
        return field
    }

    /// Constrains localized copy to the card and lets AppKit measure as many
    /// wrapped lines as the available height can display. Insets scale down on
    /// very small cards so padding cannot consume the entire text area.
    static func dropHintLabelFrame(for label: NSTextField,
                                   in hintRect: CGRect) -> CGRect {
        guard hintRect.width > 0, hintRect.height > 0 else {
            return CGRect(origin: hintRect.origin, size: .zero)
        }
        let horizontalInset = min(
            dropHintLabelHorizontalInset,
            hintRect.width * 0.1
        )
        let verticalInset = min(
            dropHintLabelVerticalInset,
            hintRect.height * 0.1
        )
        let availableWidth = max(0, hintRect.width - horizontalInset * 2)
        let availableHeight = max(0, hintRect.height - verticalInset * 2)
        let measurementBounds = CGRect(
            x: 0,
            y: 0,
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let measuredHeight = label.cell?.cellSize(forBounds: measurementBounds).height
            ?? label.intrinsicContentSize.height
        let labelHeight = min(ceil(measuredHeight), availableHeight)
        return CGRect(
            x: hintRect.minX + horizontalInset,
            y: hintRect.midY - labelHeight / 2,
            width: availableWidth,
            height: labelHeight
        )
    }

    /// True while the directional drop-hint cards are visible (a valid drag is
    /// hovering the page area). Tracked separately from the per-cursor landing
    /// zone so the hints stay visible while the cursor is in the dead middle
    /// band.
    private var hintsVisible = false

    /// Mode the currently-visible hint cards were laid out for. Set before
    /// `showHighlights()` on each drag update so the card geometry and labels
    /// match the create/replace decision. Read by `updateDropHintFrames`.
    private var activeMode: Mode = .create

    /// Which hint card, if any, the cursor is currently resolving to as the
    /// drop target — nil while hovering the dead middle band in create mode.
    /// Drives the darkening mask that marks the card that would receive the
    /// drop right now.
    private var activeDropZone: DropZone?

    /// Latest drag location in this view's coordinate space. Create-mode cards
    /// use it for base-size attraction and damped movement after expansion.
    /// Cleared whenever no directional zone is active.
    private var activeDragPoint: CGPoint?

    /// The nearby card starts by moving toward the pointer at its base size.
    /// It grows only after that moving card has reached the pointer.
    private var isActiveDropHintExpanded = false

    /// Model target for the base-sized approach phase. It is derived from the
    /// current presentation frame rather than the immutable Figma frame, so a
    /// pointer moving toward the card cannot make the card reverse direction.
    private var approachingDropHintCenter: CGPoint?

    /// Rechecks the presentation frame after an approach animation finishes.
    /// Dragging callbacks stop when the pointer is still, so this completion is
    /// what lets the card finish meeting a stationary pointer and then grow.
    private var approachCompletionGeneration = 0
    private var isApproachCompletionScheduled = false

    /// Once a card expands, follow movement is measured from the point where
    /// the pointer first entered it. Keeping both anchors prevents expansion
    /// from snapping the card back toward its original Figma position.
    private var expandedDropHintDragAnchor: CGPoint?
    private var expandedDropHintCenterAnchor: CGPoint?

    private var themeObservation: AnyObject?

    override init(frame frameRect: NSRect) {
        var builtCards: [DropZone: HintCard] = [:]
        for zone in Self.allZones {
            builtCards[zone] = HintCard(
                surface: Self.makeSurfaceView(),
                glass: Self.makeGlassView(),
                highlight: Self.makeHighlightGradient(),
                whiteOverlay: Self.makeWhiteOverlayLayer(),
                activeMask: Self.makeActiveMaskLayer(),
                border: Self.makeBorderLayer(),
                label: Self.makeDropLabel()
            )
        }
        cards = builtCards

        super.init(frame: frameRect)
        wantsLayer = true
        // Order: transformed surface (glass → white tint → active scrim →
        // dashed border) → label. Keeping the material and every shape under
        // one parent transform prevents their animations from drifting apart.
        for zone in Self.allZones {
            guard let card = cards[zone] else { continue }
            addSubview(card.surface)
            card.surface.addSubview(card.glass)
            card.glass.layer?.addSublayer(card.highlight)
            card.surface.layer?.addSublayer(card.whiteOverlay)
            card.surface.layer?.addSublayer(card.activeMask)
            card.surface.layer?.addSublayer(card.border)
            addSubview(card.label)
            card.label.layer?.zPosition = 10_000
            card.label.stringValue = zone.labelText
        }
        registerForDraggedTypes([.normalTab, .pinnedTab, .phiBookmark])
        themeObservation = subscribe { [weak self] _, _ in
            self?.applyThemeColors()
        }
        applyThemeColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hintsVisible {
            updateDropHintFrames(transition: nil)
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender).operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender).operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideHighlights()
    }

    // MARK: - External drag drivers (TabStrip, comfortable layout)
    //
    // The horizontal-tab TabStrip drives drags with raw mouse events instead
    // of an NSDraggingSession, so its drag doesn't flow through the
    // NSDraggingDestination methods above. These hooks let the strip query
    // the split zone for a screen point and show/hide the same highlight UI
    // while the user is dragging a tab.

    /// Returns the split zone the given screen point falls into, or `nil` if
    /// the point is outside the drop area or no drop is allowed right now.
    /// Multi-tab drags are intentionally not split candidates.
    /// In create mode (focused tab not a split), the four edge thirds land;
    /// in replace mode the whole page maps onto the two existing panes.
    ///
    /// Note: in create mode, dragging the focused tab onto itself is allowed —
    /// the drop creates a fresh new-tab-page as the partner pane.
    func splitZoneForScreenPoint(_ screenPoint: CGPoint,
                                 draggedTabId: Int,
                                 draggedTabCount: Int = 1) -> DropZone? {
        guard draggedTabCount == 1,
              let mode = resolveMode(draggedTabId: draggedTabId),
              let pointInSelf = pointInSelfForScreenPoint(screenPoint) else { return nil }
        let area = pageAreaProvider?() ?? bounds
        return zone(forPoint: pointInSelf, mode: mode, area: area)
    }

    /// True when a single-tab drag from the same window is hovering anywhere over
    /// the page area and would be a valid split candidate. Used by the
    /// horizontal TabStrip's manual drag flow to keep the hint cards
    /// visible while the cursor is in the dead middle band — the drop
    /// landing decision still uses `splitZoneForScreenPoint`.
    func isSplitDragContextValid(at screenPoint: CGPoint,
                                 draggedTabId: Int,
                                 draggedTabCount: Int = 1) -> Bool {
        guard draggedTabCount == 1,
              resolveMode(draggedTabId: draggedTabId) != nil,
              let pointInSelf = pointInSelfForScreenPoint(screenPoint) else { return false }
        let area = pageAreaProvider?() ?? bounds
        return area.contains(pointInSelf)
    }

    private func pointInSelfForScreenPoint(_ screenPoint: CGPoint) -> CGPoint? {
        guard let window else { return nil }
        let pointInWindow = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        return convert(pointInWindow, from: nil)
    }

    /// Shows split-drop hint cards laid out for the drag's mode. Hides
    /// any existing hint if the drag isn't a valid split candidate. `at`
    /// re-resolves the zone under the cursor on every call so the active
    /// card's mask tracks the mouse as it moves between hint cards.
    func showSplitDropHints(draggedTabId: Int, draggedTabCount: Int = 1, at screenPoint: CGPoint? = nil) {
        guard draggedTabCount == 1,
              let mode = resolveMode(draggedTabId: draggedTabId) else {
            hideHighlights()
            return
        }
        activeMode = mode
        applyHintLabels(for: mode)
        showHighlights()
        if let screenPoint,
           let pointInSelf = pointInSelfForScreenPoint(screenPoint) {
            let area = pageAreaProvider?() ?? bounds
            let zone = zone(forPoint: pointInSelf, mode: mode, area: area)
            setActiveDropZone(zone, dragPoint: zone == nil ? nil : pointInSelf)
        } else {
            setActiveDropZone(nil)
        }
    }

    /// Hides all split-drop hint cards.
    func hideSplitDropHints() {
        hideHighlights()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = evaluate(sender)
        defer { hideHighlights() }
        guard result.operation != [], let zone = result.zone,
              let state = browserState,
              let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first,
              let source = parseDragSource(pasteboardItem) else { return false }
        commitSplitDrop(state: state, source: source, zone: zone)
        return true
    }

    /// Commits a split drop, choosing create vs replace from the focused tab.
    /// Shared by the NSDraggingDestination path and the TabStrip manual drag
    /// so both entry points behave identically.
    func commitSplitDrop(state: BrowserState, source: DragSource, zone: DropZone) {
        guard let mode = resolveMode(for: source, state: state) else { return }
        switch mode {
        case .create:
            guard let focusedTabId = state.focusingTab?.guid else { return }
            performSplitDrop(state: state,
                             source: source,
                             focusedTabId: focusedTabId,
                             zone: zone)
        case .replace(let splitId):
            performPaneReplace(state: state, source: source, splitId: splitId, zone: zone)
        }
    }

    /// Routes a split *create* drop based on the drag's source kind. Three
    /// paths converge here: a normal tab in the strip, a pinned tab in the
    /// favorites grid, or a (non-split) bookmark. The normal-tab and bookmark
    /// paths produce a split whose two panes are entries in the **normal
    /// opened tab list**; the pinned path keeps the dragged tab pinned and
    /// pins the focused tab next to it so the result is a pinned split.
    private func performSplitDrop(state: BrowserState,
                                  source: DragSource,
                                  focusedTabId: Int,
                                  zone: DropZone) {
        switch source {
        case .normalTab(let tabId):
            // Normalize the focused tab (the split partner) into the opened
            // tab list, otherwise the resulting split would inherit its
            // pinned-ness or bookmark binding — contrary to user intent.
            state.makeTabNormalOpened(tabId: focusedTabId)
            performSplitDropFromNormalTab(state: state,
                                          draggedTabId: tabId,
                                          focusedTabId: focusedTabId,
                                          zone: zone)
        case .pinnedTab(let dbGuid):
            // Pinned source preserves pinned status: the live-pinned subpath
            // pins the focused tab itself rather than unpinning the dragged
            // pane. Normalization is handled inside the helper for the
            // closed-pinned fallback only.
            performSplitDropFromPinned(state: state,
                                       pinnedDBGuid: dbGuid,
                                       focusedTabId: focusedTabId,
                                       zone: zone)
        case .bookmark(let bookmarkGuid):
            // Focused-tab normalization is deferred into the helper so it
            // only runs after the bookmark record+URL guard succeeds —
            // otherwise a bookmark deleted mid-drag or with an empty URL
            // would silently unpin/unbind the focused tab for nothing.
            performSplitDropFromBookmark(state: state,
                                         bookmarkGuid: bookmarkGuid,
                                         focusedTabId: focusedTabId,
                                         zone: zone)
        }
    }

    private func performSplitDropFromNormalTab(state: BrowserState,
                                               draggedTabId: Int,
                                               focusedTabId: Int,
                                               zone: DropZone) {
        if draggedTabId == focusedTabId {
            // Dragged = focused → open a new tab as the partner. The new
            // tab takes the slot opposite the one the user dropped on,
            // since the "dragged" tab visually lands in the dropped slot.
            let newTabSlot: SplitSlot = zone.isPrimarySlot ? .right : .left
            state.openNewTabAsSplit(partnerTabId: focusedTabId,
                                    newTabSlot: newTabSlot,
                                    layout: zone.layout)
            return
        }
        if zone.isPrimarySlot {
            state.createSplit(leftTabId: draggedTabId,
                              rightTabId: focusedTabId,
                              layout: zone.layout)
        } else {
            state.createSplit(leftTabId: focusedTabId,
                              rightTabId: draggedTabId,
                              layout: zone.layout)
        }
    }

    private func performSplitDropFromPinned(state: BrowserState,
                                            pinnedDBGuid: String,
                                            focusedTabId: Int,
                                            zone: DropZone) {
        if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == pinnedDBGuid }),
           liveTab.guid != focusedTabId {
            // Live pinned tab distinct from focused. Splits never live in
            // the pinned strip: demote the dragged pinned tab into the
            // normal list (leaving an unopened pinned placeholder at the
            // original slot), normalize the focused partner, and form a
            // normal split. Mirrors the right-click "Open as Split" path
            // so every entry point behaves identically.
            state.demotePinnedTabLeavingPlaceholder(forTabId: liveTab.guid)
            state.makeTabNormalOpened(tabId: focusedTabId)
            if zone.isPrimarySlot {
                state.createSplit(leftTabId: liveTab.guid,
                                  rightTabId: focusedTabId,
                                  layout: zone.layout)
            } else {
                state.createSplit(leftTabId: focusedTabId,
                                  rightTabId: liveTab.guid,
                                  layout: zone.layout)
            }
            return
        }
        // Closed pinned tab (no live representation) or pinned tab whose
        // live representation IS the focused pane: open a fresh tab on the
        // pinned URL as the new pane. The pinned record itself is left
        // intact so the slot still exists for next time. The new partner
        // pane is a normal tab, so normalize the focused tab — but only
        // after the URL guard succeeds, otherwise a pinned record with no
        // saved URL would silently unpin/unbind the focused tab for nothing.
        guard let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedDBGuid }),
              let url = pinned.url, !url.isEmpty else { return }
        state.makeTabNormalOpened(tabId: focusedTabId)
        let newTabSlot: SplitSlot = zone.isPrimarySlot ? .left : .right
        state.openNewTabAsSplit(partnerTabId: focusedTabId,
                                newTabSlot: newTabSlot,
                                partnerNavigateURL: URLProcessor.processUserInput(url),
                                layout: zone.layout)
    }

    private func performSplitDropFromBookmark(state: BrowserState,
                                              bookmarkGuid: String,
                                              focusedTabId: Int,
                                              zone: DropZone) {
        // Single shared implementation on BrowserState — same path the
        // bookmark "Open as Split" menu and any future entry point use.
        let newTabSlot: SplitSlot = zone.isPrimarySlot ? .left : .right
        state.formSplitFromBookmark(bookmarkGuid: bookmarkGuid,
                                    partnerTabId: focusedTabId,
                                    newTabSlot: newTabSlot,
                                    layout: zone.layout)
    }

    // MARK: - Replace a pane (focused tab is a split)

    /// Replaces one pane of the focused split with the dragged item. The
    /// hovered half maps to a slot (left → 0 = primary, right → 1 =
    /// secondary). The evicted pane moves right next to the split, joining
    /// its tab group if any (`swap: true`). Normal tabs swap synchronously;
    /// bookmarks and closed-pinned entries open a fresh tab first and swap
    /// once Chromium echoes it back.
    private func performPaneReplace(state: BrowserState,
                                    source: DragSource,
                                    splitId: String,
                                    zone: DropZone) {
        let slotIndex = zone.isPrimarySlot ? 0 : 1
        // Keep the evicted pane as a standalone tab, unless it's an empty
        // new-tab page — then close it (`swap: false`) instead of littering
        // the strip.
        let keepEvicted = state.splitPaneReplacementKeepsEvicted(splitId: splitId, slotIndex: slotIndex)
        switch source {
        case .normalTab(let tabId):
            state.swapTabInSplit(splitId, slotIndex: slotIndex, withTabId: tabId, swap: keepEvicted)
        case .pinnedTab(let dbGuid):
            // Live pinned tab distinct from the split's panes: demote it into
            // the normal list (leaving a pinned placeholder at its slot), then
            // swap it into the pane — splits never live in the pinned strip.
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               state.splitGroup(forId: splitId)?.contains(tabId: liveTab.guid) != true {
                state.demotePinnedTabLeavingPlaceholder(forTabId: liveTab.guid)
                state.swapTabInSplit(splitId, slotIndex: slotIndex, withTabId: liveTab.guid, swap: keepEvicted)
                return
            }
            // Closed pinned (no live representation): open a fresh tab on the
            // pinned URL and swap it in once it arrives. The pinned record is
            // left intact so the slot still exists.
            guard let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
                  let url = pinned.url, !url.isEmpty else { return }
            state.openTabAsPaneReplacement(splitId: splitId,
                                           slotIndex: slotIndex,
                                           url: URLProcessor.processUserInput(url))
        case .bookmark(let bookmarkGuid):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid),
                  !bookmark.isFolder, let url = bookmark.url, !url.isEmpty else { return }
            // Bookmark with an attached live tab (not in any split): detach
            // it into the normal list, then swap it into the pane directly —
            // the user keeps the open page instead of getting a fresh
            // duplicate. Mirrors `formSplitFromBookmark`'s attached-and-
            // distinct path; `makeTabNormalOpened` clears the binding so the
            // bookmark cell stops rendering as opened.
            if let attachedLiveTab = state.tabs.first(where: { $0.guidInLocalDB == bookmarkGuid }),
               state.splitGroup(forTabId: attachedLiveTab.guid) == nil {
                state.makeTabNormalOpened(tabId: attachedLiveTab.guid)
                state.swapTabInSplit(splitId, slotIndex: slotIndex, withTabId: attachedLiveTab.guid, swap: keepEvicted)
                return
            }
            // No live representation (or it's a pane of another split, which
            // matches create mode's fall-through): open a fresh tab on the
            // bookmark URL and swap it in once Chromium echoes it back.
            state.openTabAsPaneReplacement(splitId: splitId,
                                           slotIndex: slotIndex,
                                           url: URLProcessor.processUserInput(url))
        }
    }

    // MARK: - Mode + zone resolution

    /// Decides what a drop will do given the drag's source. Returns nil when
    /// no drop is allowed. `create` when the focused tab is not a split;
    /// `replace` when it is — but only if the split isn't pinned and the
    /// dragged item isn't already a pane of that split.
    private func resolveMode(for source: DragSource, state: BrowserState) -> Mode? {
        guard let focusedTab = state.focusingTab else { return nil }
        guard let group = state.splitGroup(forTabId: focusedTab.guid) else {
            return .create
        }
        // Pinned splits render as one combined cell in the pinned grid and
        // persist as a DB-guid pair (`persistPinnedSplitPair`). Swapping a
        // pane would strand that pair — the evicted tab stays flagged pinned
        // while the incoming one isn't. No drop allowed.
        guard !group.isPinned else { return nil }
        switch source {
        case .normalTab(let tabId):
            if group.contains(tabId: tabId) { return nil }
        case .pinnedTab(let dbGuid):
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               group.contains(tabId: liveTab.guid) { return nil }
        case .bookmark(let bookmarkGuid):
            // A bookmark whose attached live tab is already a pane of this
            // split would replace a pane with itself (or its sibling) —
            // same rule as the pinned case above.
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == bookmarkGuid }),
               group.contains(tabId: liveTab.guid) { return nil }
        }
        return .replace(splitId: group.id)
    }

    /// Screen-point variant used by the TabStrip manual-drag flow, which only
    /// drags normal tabs. Rejects a dragged tab that is itself a split.
    private func resolveMode(draggedTabId: Int) -> Mode? {
        guard let state = browserState,
              state.splitGroup(forTabId: draggedTabId) == nil else { return nil }
        return resolveMode(for: .normalTab(tabId: draggedTabId), state: state)
    }

    /// Maps a point to a drop zone for the given mode. Create mode initially
    /// activates from the four edge thirds. Once active, that direction remains
    /// selected throughout its configured movement range so the card can keep
    /// following the pointer without dropping back to its origin.
    /// Replace mode mirrors the split's panes so every point lands on one.
    private func zone(forPoint pointInSelf: CGPoint, mode: Mode, area: CGRect) -> DropZone? {
        guard area.contains(pointInSelf) else { return nil }
        switch mode {
        case .create:
            return Self.createDropZone(
                for: pointInSelf,
                in: area,
                retaining: activeDropZone
            )
        case .replace(let splitId):
            return replaceZone(forPoint: pointInSelf, splitId: splitId, area: area)
        }
    }

    /// Resolves create-mode edge zones. Left/right retain priority for initial
    /// activation in overlapping corners. Once active, a small exit tolerance
    /// takes precedence so pointer tremble cannot alternate two corner cards.
    static func createDropZone(for point: CGPoint,
                               in area: CGRect,
                               retaining activeZone: DropZone? = nil) -> DropZone? {
        guard area.contains(point) else { return nil }
        let rects = createDropZoneRects(in: area)
        if let activeZone,
           isPoint(point, inRetainedRangeFor: activeZone, of: area) {
            return activeZone
        }
        return allZones.first { rects[$0]?.contains(point) == true }
    }

    private static func createDropZoneRects(in area: CGRect) -> [DropZone: CGRect] {
        let width = area.width * edgeDropZoneFraction
        let height = area.height * edgeDropZoneFraction
        return [
            .left: CGRect(x: area.minX, y: area.minY,
                          width: width, height: area.height),
            .right: CGRect(x: area.maxX - width, y: area.minY,
                           width: width, height: area.height),
            .top: CGRect(x: area.minX, y: area.maxY - height,
                         width: area.width, height: height),
            .bottom: CGRect(x: area.minX, y: area.minY,
                            width: area.width, height: height),
        ]
    }

    /// Figma-proportional visual rectangles for create mode. A single contain
    /// scale preserves every card's aspect ratio and the spacing between the
    /// four directions, even when the page area is unusually wide or tall.
    static func createDropHintRects(in area: CGRect) -> [DropZone: CGRect] {
        guard area.width > 0, area.height > 0 else {
            return Dictionary(uniqueKeysWithValues: allZones.map { ($0, .zero) })
        }
        let scale = min(
            area.width / dropHintReferenceSize.width,
            area.height / dropHintReferenceSize.height
        )
        let sideSize = CGSize(
            width: sideDropHintReferenceSize.width * scale,
            height: sideDropHintReferenceSize.height * scale
        )
        let horizontalSize = CGSize(
            width: horizontalDropHintReferenceSize.width * scale,
            height: horizontalDropHintReferenceSize.height * scale
        )
        let sideInset = sideDropHintReferenceInset * scale
        let horizontalInset = horizontalDropHintReferenceInset * scale
        return [
            .left: CGRect(
                x: area.minX + sideInset,
                y: area.midY - sideSize.height / 2,
                width: sideSize.width,
                height: sideSize.height
            ),
            .right: CGRect(
                x: area.maxX - sideInset - sideSize.width,
                y: area.midY - sideSize.height / 2,
                width: sideSize.width,
                height: sideSize.height
            ),
            .top: CGRect(
                x: area.midX - horizontalSize.width / 2,
                y: area.maxY - horizontalInset - horizontalSize.height,
                width: horizontalSize.width,
                height: horizontalSize.height
            ),
            .bottom: CGRect(
                x: area.midX - horizontalSize.width / 2,
                y: area.minY + horizontalInset,
                width: horizontalSize.width,
                height: horizontalSize.height
            ),
        ]
    }

    /// Presented create-mode rectangle for one card. Before entry, the caller
    /// advances `approachingCenter` from the current presentation frame. After
    /// entry, the card grows around the captured center and follows from that
    /// point. The configured directional movement area bounds both phases.
    static func createDropHintRect(for zone: DropZone,
                                   in area: CGRect,
                                   isActive: Bool,
                                   isExpanded: Bool = true,
                                   dragPoint: CGPoint?,
                                   approachingCenter: CGPoint? = nil,
                                   followDragAnchor: CGPoint? = nil,
                                   followCenterAnchor: CGPoint? = nil) -> CGRect {
        guard let baseRect = createDropHintRects(in: area)[zone] else { return .zero }
        guard isActive else { return baseRect }
        let baseCenter = CGPoint(x: baseRect.midX, y: baseRect.midY)
        let isSideCard = zone == .left || zone == .right
        var center = baseCenter
        var size = baseRect.size

        if isExpanded {
            size = CGSize(
                width: baseRect.width * activeDropHintScale,
                height: baseRect.height * activeDropHintScale
            )
            let dragAnchor = followDragAnchor ?? baseCenter
            center = followCenterAnchor ?? baseCenter
            if let dragPoint {
                let horizontalGain = isSideCard
                    ? followingPrimaryAxisGain
                    : followingSecondaryAxisGain
                let verticalGain = isSideCard
                    ? followingSecondaryAxisGain
                    : followingPrimaryAxisGain
                center.x += (dragPoint.x - dragAnchor.x) * horizontalGain
                center.y += (dragPoint.y - dragAnchor.y) * verticalGain
            }
        } else if let approachingCenter {
            center = approachingCenter
        }

        let rect = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clamp(
            rect,
            to: directionalMovementArea(for: zone, in: area)
        )
    }

    /// Builds a base-sized target that reaches the pointer in one animation, or
    /// reaches the configured movement boundary when the pointer is farther
    /// away. An existing target can only advance in its established direction,
    /// so moving the pointer toward the card cannot send the card back toward
    /// its Figma origin.
    static func nextApproachingDropHintCenter(for zone: DropZone,
                                              in area: CGRect,
                                              presentedRect: CGRect,
                                              currentTargetCenter: CGPoint? = nil,
                                              dragPoint: CGPoint) -> CGPoint {
        guard let baseRect = createDropHintRects(in: area)[zone] else { return .zero }
        let currentRect = presentedRect.isEmpty ? baseRect : presentedRect
        let currentCenter = CGPoint(x: currentRect.midX, y: currentRect.midY)
        let isSideCard = zone == .left || zone == .right
        let horizontalGain = isSideCard
            ? approachingPrimaryAxisGain
            : approachingSecondaryAxisGain
        let verticalGain = isSideCard
            ? approachingSecondaryAxisGain
            : approachingPrimaryAxisGain
        let horizontalDelta = approachCaptureDelta(
            point: dragPoint.x,
            minimum: currentRect.minX,
            maximum: currentRect.maxX
        )
        let verticalDelta = approachCaptureDelta(
            point: dragPoint.y,
            minimum: currentRect.minY,
            maximum: currentRect.maxY
        )
        let candidateCenter = CGPoint(
            x: currentCenter.x + horizontalDelta * horizontalGain,
            y: currentCenter.y + verticalDelta * verticalGain
        )

        // Approach at the base size so the card can cover the narrow margin
        // between its Figma origin and the page edge. Expansion is clamped
        // separately around `safeCenter`, keeping the pointer-facing edge fixed
        // while the larger card grows inward.
        var nextCenter = clamp(
            center: candidateCenter,
            fitting: baseRect.size,
            to: directionalMovementArea(for: zone, in: area)
        )

        let basePrimary = isSideCard ? baseRect.midX : baseRect.midY
        var nextPrimary = isSideCard ? nextCenter.x : nextCenter.y

        if let currentTargetCenter {
            let targetPrimary = isSideCard ? currentTargetCenter.x : currentTargetCenter.y
            let targetDirection = targetPrimary - basePrimary
            if targetDirection > 0 {
                nextPrimary = max(targetPrimary, nextPrimary)
            } else if targetDirection < 0 {
                nextPrimary = min(targetPrimary, nextPrimary)
            }
        }

        if isSideCard {
            nextCenter.x = nextPrimary
        } else {
            nextCenter.y = nextPrimary
        }
        return nextCenter
    }

    private static func approachCaptureDelta(point: CGFloat,
                                             minimum: CGFloat,
                                             maximum: CGFloat) -> CGFloat {
        if point < minimum {
            return point - minimum - dropHintApproachCaptureDepth
        }
        if point > maximum {
            return point - maximum + dropHintApproachCaptureDepth
        }
        return 0
    }

    static func shouldExpandCreateDropHint(presentedRect: CGRect,
                                           wasExpandedInCurrentZone: Bool,
                                           dragPoint: CGPoint) -> Bool {
        if wasExpandedInCurrentZone {
            return true
        }
        return presentedRect.insetBy(
            dx: -dropHintContainmentTolerance,
            dy: -dropHintContainmentTolerance
        ).contains(dragPoint)
    }

    private static func expansionSafeDropHintCenter(for zone: DropZone,
                                                    in area: CGRect,
                                                    desiredCenter: CGPoint) -> CGPoint {
        guard let baseRect = createDropHintRects(in: area)[zone] else {
            return desiredCenter
        }
        let expandedSize = CGSize(
            width: baseRect.width * activeDropHintScale,
            height: baseRect.height * activeDropHintScale
        )
        return clamp(
            center: desiredCenter,
            fitting: expandedSize,
            to: directionalMovementArea(for: zone, in: area)
        )
    }

    private static func directionalMovementArea(for zone: DropZone,
                                                in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0,
              let baseRect = createDropHintRects(in: area)[zone] else {
            return area
        }
        let expandedSize = CGSize(
            width: baseRect.width * activeDropHintScale,
            height: baseRect.height * activeDropHintScale
        )
        let minimumFraction = zone == .left || zone == .right
            ? expandedSize.width / area.width
            : expandedSize.height / area.height
        let configuredFraction = min(
            max(dropHintMovementRangeFraction, minimumFraction),
            0.5
        )
        let fraction = minimumFraction
            + (configuredFraction - minimumFraction) * dropHintMovementTravelScale
        let horizontalRange = area.width * fraction
        let verticalRange = area.height * fraction
        switch zone {
        case .left:
            return CGRect(
                x: area.minX,
                y: area.minY,
                width: horizontalRange,
                height: area.height
            )
        case .right:
            return CGRect(
                x: area.maxX - horizontalRange,
                y: area.minY,
                width: horizontalRange,
                height: area.height
            )
        case .top:
            return CGRect(
                x: area.minX,
                y: area.maxY - verticalRange,
                width: area.width,
                height: verticalRange
            )
        case .bottom:
            return CGRect(
                x: area.minX,
                y: area.minY,
                width: area.width,
                height: verticalRange
            )
        }
    }

    private static func isPoint(_ point: CGPoint,
                                inRetainedRangeFor zone: DropZone,
                                of area: CGRect) -> Bool {
        let visualFraction = min(max(dropHintMovementRangeFraction, 0), 0.5)
        let retentionFraction = max(edgeDropZoneFraction, visualFraction)
        let horizontalRange = area.width * retentionFraction
        let verticalRange = area.height * retentionFraction
        switch zone {
        case .left:
            return point.x <= area.minX + horizontalRange + dropHintZoneExitTolerance
        case .right:
            return point.x >= area.maxX - horizontalRange - dropHintZoneExitTolerance
        case .top:
            return point.y >= area.maxY - verticalRange - dropHintZoneExitTolerance
        case .bottom:
            return point.y <= area.minY + verticalRange + dropHintZoneExitTolerance
        }
    }

    private static func clamp(center: CGPoint,
                              fitting size: CGSize,
                              to area: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(center.x, area.minX + size.width / 2), area.maxX - size.width / 2),
            y: min(max(center.y, area.minY + size.height / 2), area.maxY - size.height / 2)
        )
    }

    private static func clamp(_ rect: CGRect, to area: CGRect) -> CGRect {
        guard !rect.isEmpty, !area.isEmpty else { return rect }
        var origin = rect.origin
        origin.x = min(max(origin.x, area.minX), area.maxX - rect.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - rect.height)
        return CGRect(origin: origin, size: rect.size)
    }

    /// Visual rectangles for the given mode. Create mode uses the independent
    /// Figma geometry above; replace mode mirrors the split's actual panes.
    private func hintRects(mode: Mode, area: CGRect) -> [DropZone: CGRect] {
        switch mode {
        case .create:
            return Self.createDropHintRects(in: area)
        case .replace(let splitId):
            let rects = replacePaneRects(splitId: splitId, area: area)
            return [.left: rects.left, .right: rects.right]
        }
    }

    /// Pane rectangles mirroring `SplitPaneHostView.layout()` so the replace
    /// hint cards line up with the real panes. `.left` is always the primary
    /// pane (slot 0) — left for a vertical split, top for a horizontal one.
    private func replacePaneRects(splitId: String, area: CGRect) -> (left: CGRect, right: CGRect) {
        let dividerThickness = SplitPaneHostView.dividerThickness
        let paneInset = SplitPaneHostView.paneInset
        let group = browserState?.splitGroup(forId: splitId)
        let ratio = CGFloat(min(max(group?.ratio ?? 0.5, 0), 1))
        let total = area.insetBy(dx: paneInset, dy: paneInset)
        switch group?.layout ?? .vertical {
        case .vertical:
            let primaryWidth = max(0, (total.width - dividerThickness) * ratio)
            let secondaryWidth = max(0, total.width - dividerThickness - primaryWidth)
            return (
                CGRect(x: total.minX, y: total.minY, width: primaryWidth, height: total.height),
                CGRect(x: total.minX + primaryWidth + dividerThickness, y: total.minY, width: secondaryWidth, height: total.height)
            )
        case .horizontal:
            let primaryHeight = max(0, (total.height - dividerThickness) * ratio)
            let secondaryHeight = max(0, total.height - dividerThickness - primaryHeight)
            // y=0 is the bottom in AppKit; primary (slot 0) sits on top.
            return (
                CGRect(x: total.minX, y: total.minY + secondaryHeight + dividerThickness, width: total.width, height: primaryHeight),
                CGRect(x: total.minX, y: total.minY, width: total.width, height: secondaryHeight)
            )
        }
    }

    /// Replace-mode hit test: picks the pane the point sits over, splitting at
    /// the divider midline so the gap resolves to the nearer pane.
    private func replaceZone(forPoint pointInSelf: CGPoint, splitId: String, area: CGRect) -> DropZone {
        let rects = replacePaneRects(splitId: splitId, area: area)
        if browserState?.splitGroup(forId: splitId)?.layout == .horizontal {
            let mid = (rects.right.maxY + rects.left.minY) / 2
            return pointInSelf.y >= mid ? .left : .right
        }
        let mid = (rects.left.maxX + rects.right.minX) / 2
        return pointInSelf.x <= mid ? .left : .right
    }

    // MARK: - Drop validation

    private struct Evaluation {
        let operation: NSDragOperation
        let zone: DropZone?
    }

    private func evaluate(_ sender: NSDraggingInfo) -> Evaluation {
        guard let state = browserState,
              let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first,
              isSameWindowDrag(pasteboardItem, sender: sender, state: state),
              sender.draggingPasteboard.phiNormalTabIds().count <= 1,
              let source = parseDragSource(pasteboardItem),
              !isSourceASplit(source, state: state),
              let mode = resolveMode(for: source, state: state) else {
            hideHighlights()
            return Evaluation(operation: [], zone: nil)
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let area = pageAreaProvider?() ?? bounds
        guard area.contains(pointInSelf) else {
            hideHighlights()
            return Evaluation(operation: [], zone: nil)
        }
        // Drag is contextually valid and the cursor is over the page area:
        // show the directional hint cards so the user can see where they land.
        activeMode = mode
        applyHintLabels(for: mode)
        showHighlights()
        let resolvedZone = zone(forPoint: pointInSelf, mode: mode, area: area)
        setActiveDropZone(resolvedZone, dragPoint: resolvedZone == nil ? nil : pointInSelf)
        guard let zone = resolvedZone else {
            // Create mode, cursor in the dead middle band — hints stay visible
            // but no drop will land here. (Replace mode always returns a zone.)
            return Evaluation(operation: [], zone: nil)
        }
        return Evaluation(operation: .move, zone: zone)
    }

    /// Kinds of drags the page-workspace split drop accepts. The drag
    /// originates from one of three sidebar sections; each path produces a
    /// split whose two panes are normal opened tabs.
    enum DragSource {
        case normalTab(tabId: Int)
        case pinnedTab(dbGuid: String)
        case bookmark(guid: String)
    }

    /// Classifies the pasteboard item by drag source. Pinned drags carry
    /// both `.pinnedTab` and `.normalTab`; check `.pinnedTab` first so the
    /// pinned-aware path runs.
    private func parseDragSource(_ pasteboardItem: NSPasteboardItem) -> DragSource? {
        if let dbGuid = pasteboardItem.string(forType: .pinnedTab), !dbGuid.isEmpty {
            return .pinnedTab(dbGuid: dbGuid)
        }
        if let bookmarkGuid = pasteboardItem.string(forType: .phiBookmark), !bookmarkGuid.isEmpty {
            return .bookmark(guid: bookmarkGuid)
        }
        if let tabIdString = pasteboardItem.string(forType: .normalTab),
           let tabId = Int(tabIdString) {
            return .normalTab(tabId: tabId)
        }
        return nil
    }

    /// True when the drag source itself represents a split — those drops are
    /// rejected outright so the page workspace doesn't try to nest a split
    /// inside a split. Detects live splits via `splitGroup`, persisted pinned
    /// splits via `Tab.splitPartnerGuid` (covers the closed-pinned-split case
    /// where the pinned leftTab carries `guid == -1` and the live lookup
    /// misses), and split-view bookmarks via `secondaryUrl`. Folder bookmarks
    /// are also rejected — they can't be a split pane.
    private func isSourceASplit(_ source: DragSource, state: BrowserState) -> Bool {
        switch source {
        case .normalTab(let tabId):
            return state.splitGroup(forTabId: tabId) != nil
        case .pinnedTab(let dbGuid):
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               state.splitGroup(forTabId: liveTab.guid) != nil {
                return true
            }
            if let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
               let partner = pinned.splitPartnerGuid, !partner.isEmpty {
                return true
            }
            return false
        case .bookmark(let bookmarkGuid):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
                return true
            }
            if bookmark.isFolder { return true }
            if let secondary = bookmark.secondaryUrl, !secondary.isEmpty { return true }
            return false
        }
    }

    private func isSameWindowDrag(_ pasteboardItem: NSPasteboardItem,
                                  sender: NSDraggingInfo,
                                  state: BrowserState) -> Bool {
        guard let sourceIdString = pasteboardItem.string(forType: .sourceWindowId),
              let sourceId = Int(sourceIdString),
              sourceId == state.windowId else { return false }
        // Belt-and-braces: a pasteboard-only check trusts the source view to
        // have stamped the right windowId. Cross-check that `draggingSource`
        // is owned by this window so a forged pasteboard from a sibling
        // window can't masquerade as same-window. Non-NSView sources
        // (external drags) wouldn't have set `sourceWindowId` anyway and are
        // already rejected by the check above.
        if let sourceView = sender.draggingSource as? NSView,
           sourceView.window !== self.window {
            return false
        }
        return true
    }

    // MARK: - Visual feedback

    private var visibleZones: [DropZone] {
        switch activeMode {
        case .create: return Self.allZones
        case .replace: return [.left, .right]
        }
    }

    private func applyThemeColors() {
        // Glass material remains transparent; the overlay supplies a white
        // tint in light mode and a black tint in dark mode.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let overlay = isDark ? NSColor.black : NSColor.white
        let stroke = NSColor.tertiaryLabelColor
        let text = ThemedColor.textPrimary.resolve(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in cards.values {
            card.whiteOverlay.fillColor = overlay
                .withAlphaComponent(Self.dropHintWhiteOverlayOpacity)
                .cgColor
            card.border.strokeColor = stroke.cgColor
        }
        CATransaction.commit()
        for card in cards.values {
            card.label.textColor = text
        }
    }

    private func showHighlights() {
        if !hintsVisible {
            hintsVisible = true
            updateDropHintFrames(transition: nil)
        }
        // Suppress implicit fade so the cards snap on rather than fade in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let visible = Set(visibleZones)
        for (zone, card) in cards {
            card.whiteOverlay.isHidden = !visible.contains(zone)
            card.border.isHidden = !visible.contains(zone)
        }
        CATransaction.commit()
        for (zone, card) in cards {
            let isVisible = visible.contains(zone)
            card.surface.isHidden = !isVisible
            card.glass.isHidden = !isVisible
            card.label.isHidden = !isVisible
        }
    }

    private func hideHighlights() {
        hintsVisible = false
        setActiveDropZone(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in cards.values {
            card.whiteOverlay.isHidden = true
            card.border.isHidden = true
        }
        CATransaction.commit()
        for card in cards.values {
            card.surface.isHidden = true
            card.glass.isHidden = true
            card.label.isHidden = true
        }
    }

    /// Updates the active-target mask and pointer-driven create-card geometry.
    /// Geometry refreshes on every drag update so the active card can follow
    /// the pointer even while it remains inside the same directional zone.
    private func setActiveDropZone(_ zone: DropZone?, dragPoint: CGPoint? = nil) {
        let previousZone = activeDropZone
        let wasExpanded = isActiveDropHintExpanded
        let zoneChanged = zone != previousZone
        if zoneChanged {
            cancelApproachCompletion()
            approachingDropHintCenter = nil
            expandedDropHintDragAnchor = nil
            expandedDropHintCenterAnchor = nil
        }
        activeDropZone = zone
        activeDragPoint = zone == nil ? nil : dragPoint
        if activeMode == .create, let zone, let dragPoint {
            let area = pageAreaProvider?() ?? bounds
            let wasExpandedInThisZone = previousZone == zone && wasExpanded
            let approachTarget = Self.createDropHintRect(
                for: zone,
                in: area,
                isActive: true,
                isExpanded: false,
                dragPoint: nil,
                approachingCenter: approachingDropHintCenter
            )
            let presentedRect = presentedDropHintRect(
                for: zone,
                fallback: approachTarget
            )
            let reachedPointer = Self.shouldExpandCreateDropHint(
                presentedRect: presentedRect,
                wasExpandedInCurrentZone: wasExpandedInThisZone,
                dragPoint: dragPoint
            )
            let safeCenter = Self.expansionSafeDropHintCenter(
                for: zone,
                in: area,
                desiredCenter: CGPoint(x: presentedRect.midX, y: presentedRect.midY)
            )
            isActiveDropHintExpanded = wasExpandedInThisZone || reachedPointer
            if isActiveDropHintExpanded && !wasExpandedInThisZone {
                cancelApproachCompletion()
                approachingDropHintCenter = nil
                expandedDropHintDragAnchor = dragPoint
                // Side cards begin close enough to the page edge that a 1.3x
                // scale needs a small center adjustment. Animate that offset
                // together with the growth instead of moving the base card
                // away from a pointer that has already entered it.
                expandedDropHintCenterAnchor = safeCenter
            } else if !isActiveDropHintExpanded {
                approachingDropHintCenter = Self.nextApproachingDropHintCenter(
                    for: zone,
                    in: area,
                    presentedRect: presentedRect,
                    currentTargetCenter: approachingDropHintCenter,
                    dragPoint: dragPoint
                )
                expandedDropHintDragAnchor = nil
                expandedDropHintCenterAnchor = nil
            }
        } else {
            isActiveDropHintExpanded = false
            approachingDropHintCenter = nil
            expandedDropHintDragAnchor = nil
            expandedDropHintCenterAnchor = nil
        }
        let expansionChanged = wasExpanded != isActiveDropHintExpanded
        if hintsVisible {
            let transition: HintFrameTransition?
            if activeMode != .create || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                transition = nil
            } else if previousZone == nil, zone != nil {
                transition = .attract
            } else if zoneChanged || (expansionChanged && !isActiveDropHintExpanded) {
                transition = .settle
            } else if expansionChanged {
                transition = .attract
            } else if zone != nil, !isActiveDropHintExpanded {
                transition = .attract
            } else {
                transition = .follow
            }
            updateDropHintFrames(transition: transition)
        }
        if activeMode == .create,
           let zone,
           let dragPoint,
           !isActiveDropHintExpanded,
           let approachingDropHintCenter {
            let targetRect = Self.createDropHintRect(
                for: zone,
                in: pageAreaProvider?() ?? bounds,
                isActive: true,
                isExpanded: false,
                dragPoint: nil,
                approachingCenter: approachingDropHintCenter
            )
            updateApproachCompletion(
                for: zone,
                targetRect: targetRect,
                dragPoint: dragPoint
            )
        } else {
            cancelApproachCompletion()
        }
        guard zoneChanged else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for candidate in Self.allZones {
            guard let card = cards[candidate] else { continue }
            let isActive = candidate == zone
            card.activeMask.isHidden = !isActive
            card.surface.layer?.zPosition = isActive ? 10_001 : 9_999
            card.label.layer?.zPosition = isActive ? 10_002 : 10_000
        }
        CATransaction.commit()
    }

    /// Returns the card's actual on-screen frame while an explicit transform
    /// animation is running. Entry must be based on this presentation frame,
    /// not the future model target, or the card expands before the pointer has
    /// visibly reached it.
    private func presentedDropHintRect(for zone: DropZone,
                                       fallback: CGRect) -> CGRect {
        guard let presentedLayer = cards[zone]?.surface.layer?.presentation() else {
            return fallback
        }
        let frame = presentedLayer.frame
        guard frame.width > 0, frame.height > 0 else { return fallback }
        return frame
    }

    private func updateApproachCompletion(for zone: DropZone,
                                          targetRect: CGRect,
                                          dragPoint: CGPoint) {
        let targetReachesPointer = targetRect.insetBy(
            dx: -Self.dropHintContainmentTolerance,
            dy: -Self.dropHintContainmentTolerance
        ).contains(dragPoint)
        guard targetReachesPointer else {
            cancelApproachCompletion()
            return
        }
        guard !isApproachCompletionScheduled else { return }

        isApproachCompletionScheduled = true
        approachCompletionGeneration += 1
        let generation = approachCompletionGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.dropHintAttractAnimationDuration + 0.01
        ) { [weak self] in
            guard let self,
                  self.approachCompletionGeneration == generation else { return }
            self.isApproachCompletionScheduled = false
            guard self.hintsVisible,
                  self.activeMode == .create,
                  self.activeDropZone == zone,
                  !self.isActiveDropHintExpanded,
                  let currentPoint = self.activeDragPoint else { return }
            self.setActiveDropZone(zone, dragPoint: currentPoint)
        }
    }

    private func cancelApproachCompletion() {
        guard isApproachCompletionScheduled else { return }
        approachCompletionGeneration += 1
        isApproachCompletionScheduled = false
    }

    private func applyHintLabels(for mode: Mode) {
        for zone in visibleZones {
            cards[zone]?.label.stringValue = labelText(for: zone, mode: mode)
        }
    }

    private func labelText(for zone: DropZone, mode: Mode) -> String {
        switch mode {
        case .create:
            return zone.labelText
        case .replace(let splitId):
            // `.left` is always the primary pane (slot 0) — left for a
            // vertical split, top for a horizontal one — so the wording has
            // to follow the layout.
            let layout = browserState?.splitGroup(forId: splitId)?.layout ?? .vertical
            switch (layout, zone) {
            case (.vertical, .left):    return NSLocalizedString("browser.splitDropHint.leftHalf", value: "Replace Left", comment: "Drop-zone hint shown when dragging a tab over the left/primary pane of a vertical split to replace it")
            case (.vertical, .right):   return NSLocalizedString("browser.splitDropHint.rightHalf", value: "Replace Right", comment: "Drop-zone hint shown when dragging a tab over the right/secondary pane of a vertical split to replace it")
            case (.horizontal, .left):  return NSLocalizedString("browser.splitDropHint.top", value: "Replace Top", comment: "Drop-zone hint shown when dragging a tab over the top/primary pane of a horizontal split to replace it")
            case (.horizontal, .right): return NSLocalizedString("browser.splitDropHint.bottom", value: "Replace Bottom", comment: "Drop-zone hint shown when dragging a tab over the bottom/secondary pane of a horizontal split to replace it")
            default:                    return zone.labelText
            }
        }
    }

    private func updateDropHintFrames(transition: HintFrameTransition? = nil) {
        let area = pageAreaProvider?() ?? bounds
        // Create mode uses independent Figma-proportional cards; replace mode
        // sizes each card to the actual split pane it sits over.
        let rects = hintRects(mode: activeMode, area: area)
        for zone in visibleZones {
            guard let card = cards[zone], let baseRect = rects[zone] else { continue }
            var hintRect = baseRect
            if activeMode == .create {
                hintRect = Self.createDropHintRect(
                    for: zone,
                    in: area,
                    isActive: zone == activeDropZone,
                    isExpanded: zone == activeDropZone && isActiveDropHintExpanded,
                    dragPoint: zone == activeDropZone ? activeDragPoint : nil,
                    approachingCenter: zone == activeDropZone
                        ? approachingDropHintCenter
                        : nil,
                    followDragAnchor: zone == activeDropZone
                        ? expandedDropHintDragAnchor
                        : nil,
                    followCenterAnchor: zone == activeDropZone
                        ? expandedDropHintCenterAnchor
                        : nil
                )
            }
            updateDropHintFrame(
                card: card,
                baseRect: baseRect,
                hintRect: hintRect,
                transition: transition
            )
        }
    }

    /// Corner radius the hint card should draw for the given mode. Create-mode
    /// cards float inside the page with their own rounded look; replace-mode
    /// cards cover a pane edge-to-edge, so they must trace the pane's own
    /// radius (`SplitPaneHostView`'s pane container) instead of bulging past
    /// its rounded corners.
    private func hintCornerRadius(for mode: Mode) -> CGFloat {
        switch mode {
        case .create:
            return Self.dropHintCornerRadius
        case .replace:
            return LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        }
    }

    /// Applies the corner radius to both the backing layer and, on macOS 26+,
    /// the `NSGlassEffectView`'s own `cornerRadius` (which clips the Liquid
    /// Glass material independently of the layer).
    private func applyHintCornerRadius(_ radius: CGFloat, to glass: NSView) {
        if #available(macOS 26.0, *), let glassEffect = glass as? NSGlassEffectView {
            glassEffect.cornerRadius = radius
        }
        glass.layer?.cornerRadius = radius
    }

    private func updateDropHintFrame(card: HintCard,
                                     baseRect: NSRect,
                                     hintRect: NSRect,
                                     transition: HintFrameTransition?) {
        let baseCornerRadius = min(
            hintCornerRadius(for: activeMode),
            baseRect.width / 2,
            baseRect.height / 2
        )
        updateSurfaceBaseGeometry(
            card: card,
            baseRect: baseRect,
            cornerRadius: baseCornerRadius
        )
        updateSurfaceTransform(
            card: card,
            from: baseRect,
            to: hintRect,
            transition: transition
        )

        let labelFrame = Self.dropHintLabelFrame(for: card.label, in: hintRect)
        updateViewFrame(card.label, to: labelFrame, transition: transition)
    }

    /// Keeps the Liquid Glass view, fills, and border on one stable base shape.
    /// Interaction motion is applied as a shared transform below instead of
    /// morphing each fill path independently. `NSGlassEffectView` composites
    /// its material differently from a plain `CAShapeLayer`; mixing frame and
    /// path animations makes the white fill visibly grow inside the glass.
    private func updateSurfaceBaseGeometry(card: HintCard,
                                           baseRect: CGRect,
                                           cornerRadius: CGFloat) {
        let localBounds = CGRect(origin: .zero, size: baseRect.size)
        let basePath = CGPath(
            roundedRect: localBounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let baseGeometryChanged = card.surface.frame != baseRect
            || card.glass.frame != localBounds
            || card.whiteOverlay.bounds != localBounds
            || card.whiteOverlay.path != basePath
            || card.border.path != basePath
            || card.glass.layer?.cornerRadius != cornerRadius

        guard baseGeometryChanged else { return }

        card.surface.layer?.removeAnimation(forKey: "splitDropHint.transform")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.surface.layer?.transform = CATransform3DIdentity
        card.surface.frame = baseRect
        card.glass.frame = localBounds
        card.highlight.frame = localBounds
        for layer in [card.whiteOverlay, card.activeMask, card.border] {
            layer.bounds = localBounds
            layer.position = CGPoint(x: localBounds.midX, y: localBounds.midY)
            layer.path = basePath
            layer.removeAnimation(forKey: "splitDropHint.path")
        }
        CATransaction.commit()
        applyHintCornerRadius(cornerRadius, to: card.glass)
    }

    /// Moves and scales the complete surface with one compositor transform.
    /// The label keeps its own geometry animation so its font size stays fixed.
    private func updateSurfaceTransform(card: HintCard,
                                        from baseRect: CGRect,
                                        to hintRect: CGRect,
                                        transition: HintFrameTransition?) {
        guard baseRect.width > 0, baseRect.height > 0 else { return }
        guard let surfaceLayer = card.surface.layer else { return }
        let scaleX = hintRect.width / baseRect.width
        let scaleY = hintRect.height / baseRect.height
        let anchorPoint = surfaceLayer.anchorPoint
        let baseAnchor = CGPoint(
            x: baseRect.minX + baseRect.width * anchorPoint.x,
            y: baseRect.minY + baseRect.height * anchorPoint.y
        )
        let hintAnchor = CGPoint(
            x: hintRect.minX + hintRect.width * anchorPoint.x,
            y: hintRect.minY + hintRect.height * anchorPoint.y
        )
        var targetTransform = CATransform3DMakeScale(scaleX, scaleY, 1)
        targetTransform.m41 = hintAnchor.x - baseAnchor.x
        targetTransform.m42 = hintAnchor.y - baseAnchor.y

        updateLayerTransform(
            surfaceLayer,
            to: targetTransform,
            transition: transition
        )
    }

    private func updateLayerTransform(_ layer: CALayer,
                                      to targetTransform: CATransform3D,
                                      transition: HintFrameTransition?) {
        let transformChanged = !CATransform3DEqualToTransform(
            layer.transform,
            targetTransform
        )
        let fromTransform = layer.presentation()?.transform ?? layer.transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = targetTransform
        CATransaction.commit()

        // Preserve an in-flight transform when a layout pass recomputes the
        // same target without an explicit transition.
        guard transformChanged else { return }
        guard let transition else {
            layer.removeAnimation(forKey: "splitDropHint.transform")
            return
        }

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: fromTransform)
        animation.toValue = NSValue(caTransform3D: targetTransform)
        animation.duration = transition.duration
        animation.timingFunction = transition.timingFunction
        layer.add(animation, forKey: "splitDropHint.transform")
    }

    /// Retargets an in-flight animation from the layer's presentation state.
    /// Reusing stable animation keys replaces the previous target instead of
    /// queuing another animation for every drag event.
    private func updateViewFrame(_ view: NSView,
                                 to targetFrame: CGRect,
                                 transition: HintFrameTransition?) {
        guard let layer = view.layer else {
            view.frame = targetFrame
            return
        }
        let frameChanged = view.frame != targetFrame
        let presentation = layer.presentation() ?? layer
        let fromPosition = presentation.position
        let fromBounds = presentation.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = targetFrame
        CATransaction.commit()

        // Setting an NSView's frame schedules a parent layout pass. That pass
        // recomputes the same target without a transition; keep the explicit
        // animation alive when the model frame already matches that target.
        guard frameChanged else { return }
        guard let transition else {
            removeGeometryAnimations(from: layer)
            return
        }
        addGeometryAnimations(
            to: layer,
            fromPosition: fromPosition,
            fromBounds: fromBounds,
            transition: transition
        )
    }

    private func addGeometryAnimations(to layer: CALayer,
                                       fromPosition: CGPoint,
                                       fromBounds: CGRect,
                                       transition: HintFrameTransition) {
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: fromPosition)
        position.toValue = NSValue(point: layer.position)
        position.duration = transition.duration
        position.timingFunction = transition.timingFunction
        layer.add(position, forKey: "splitDropHint.position")

        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: fromBounds)
        bounds.toValue = NSValue(rect: layer.bounds)
        bounds.duration = transition.duration
        bounds.timingFunction = transition.timingFunction
        layer.add(bounds, forKey: "splitDropHint.bounds")
    }

    private func removeGeometryAnimations(from layer: CALayer) {
        layer.removeAnimation(forKey: "splitDropHint.position")
        layer.removeAnimation(forKey: "splitDropHint.bounds")
    }

}
