// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

// MARK: - Payload

/// What a Customize Toolbar drag carries: one toolbar item, the default set
/// (which restores the standard arrangement), or the address bar. Toolbar
/// items and the palette write the same payload, so a drop is judged by what
/// it carries, not where it started (`ToolbarCustomizationController.canDrop`).
/// The address bar is not an item: it has no zone and only lives between
/// Left and Right.
enum ToolbarDragPayload: Equatable {
    case item(ToolbarItemID)
    case defaultSet
    case addressBar

    static let pasteboardType = NSPasteboard.PasteboardType("com.phibrowser.toolbar-item")

    private static let itemPrefix = "item:"
    private static let defaultSetString = "defaultSet"
    private static let addressBarString = "addressBar"

    var string: String {
        switch self {
        case .item(let item): return Self.itemPrefix + item.rawValue
        case .defaultSet: return Self.defaultSetString
        case .addressBar: return Self.addressBarString
        }
    }

    init?(string: String) {
        if string == Self.defaultSetString {
            self = .defaultSet
        } else if string == Self.addressBarString {
            self = .addressBar
        } else if string.hasPrefix(Self.itemPrefix),
                  let item = ToolbarItemID(rawValue: String(string.dropFirst(Self.itemPrefix.count))) {
            self = .item(item)
        } else {
            return nil
        }
    }

    init?(pasteboard: NSPasteboard) {
        guard let string = pasteboard.string(forType: Self.pasteboardType) else { return nil }
        self.init(string: string)
    }

    var item: ToolbarItemID? {
        if case .item(let item) = self { return item }
        return nil
    }
}

// MARK: - Drop index

enum ToolbarDropIndex {
    /// The insertion index among items whose centers are `itemMidXs`, left to right.
    static func index(forX x: CGFloat, itemMidXs: [CGFloat]) -> Int {
        itemMidXs.filter { $0 < x }.count
    }

    /// Turns an index among the zone's drawn items into one among its arranged
    /// items (some of which may not be drawn): the drop lands right before the
    /// drawn item it was dropped before, or right after the last drawn one.
    static func arrangementIndex(drawnIndex: Int, drawn: [ToolbarItemID], arranged: [ToolbarItemID]) -> Int {
        if drawn.indices.contains(drawnIndex), let index = arranged.firstIndex(of: drawn[drawnIndex]) {
            return index
        }
        if drawn.indices.contains(drawnIndex - 1), let index = arranged.firstIndex(of: drawn[drawnIndex - 1]) {
            return index + 1
        }
        return arranged.count
    }
}

// MARK: - Controller

/// Applies Customize Toolbar's changes to the stored arrangement, and keeps
/// extensions pinned exactly while they are placed. Owned by `WebContentHeader`;
/// every change is a load, modify and save, so all windows follow it.
final class ToolbarCustomizationController {
    /// Chromium's pin state, injectable for tests.
    struct ExtensionPinning {
        var isPinned: (String) -> Bool
        var pin: (String) -> Void
        var unpin: (String) -> Void
        var isForcePinned: (String) -> Bool
    }

    /// Extensions placed while unpinned whose pin Chromium has not reported
    /// yet. The header keeps them drawn meanwhile.
    private(set) var pendingPinIDs: Set<String> = []
    /// Extensions dragged out of the toolbar whose unpin Chromium has not
    /// reported yet. The header treats them as unpinned meanwhile, so its
    /// still-pinned list cannot put them back into storage.
    private(set) var pendingUnpinIDs: Set<String> = []
    /// Extensions dragged out while their pin was still in flight: they are
    /// unpinned as soon as Chromium reports the pin.
    private var unpinsAfterPin: Set<String> = []
    /// Extensions placed again while their unpin was still in flight: they
    /// are pinned again as soon as Chromium reports the unpin.
    private var pinsAfterUnpin: Set<String> = []
    /// Called after every change, so the header redraws without waiting for
    /// the defaults notification.
    var onChange: (() -> Void)?
    /// Whether the toolbar is still being customized. A drag that outlives
    /// the session (Done, Escape or a tab switch mid-drag) removes nothing.
    var isCustomizing: () -> Bool = { true }
    /// The toolbar item or the address bar being dragged from the toolbar
    /// while customizing. The header lays the toolbar out without it until
    /// the drag ends (`WebContentHeaderState.draggedPayload`); storage only
    /// changes once it lands on a zone or leaves the toolbar. A cancelled
    /// drag puts it back where it was.
    private(set) var draggedPayload: ToolbarDragPayload?

    private let defaults: UserDefaults
    private let extensions: ExtensionPinning

    init(defaults: UserDefaults = .standard, extensions: ExtensionPinning) {
        self.defaults = defaults
        self.extensions = extensions
    }

    /// Chat stays out of the address zones, and the address zones are only
    /// drawn for a shown address bar, in either style. The default set and
    /// the address bar land on any zone as anywhere else over the toolbar.
    func canDrop(_ payload: ToolbarDragPayload, in zone: ToolbarZone) -> Bool {
        let arrangement = load()
        guard let item = payload.item else {
            return Self.isAcceptedOverToolbar(payload, showsAddressBar: arrangement.showsAddressBar, isDraggedFromToolbar: draggedPayload == payload)
        }
        guard item.allowedZones.contains(zone) else { return false }
        return !zone.isAddress || arrangement.drawsAddressZones
    }

    /// The default set lands anywhere over the toolbar, the address bar
    /// included. So does the address bar while it is removed; it always goes
    /// back between Left and Right. So does the bar being dragged from the
    /// toolbar (`isDraggedFromToolbar`): let go over it, it is back at once,
    /// with nothing to save, rather than after AppKit's slide back of a
    /// refused drop. An item lands only on a zone that takes it.
    static func isAcceptedOverToolbar(_ payload: ToolbarDragPayload, showsAddressBar: Bool, isDraggedFromToolbar: Bool = false) -> Bool {
        switch payload {
        case .defaultSet: return true
        case .addressBar: return !showsAddressBar || isDraggedFromToolbar
        case .item: return false
        }
    }

    /// A drop over the toolbar outside every zone: restores the default set
    /// or adds the address bar back (the one dragged from it included, which
    /// changes nothing stored), refuses an item.
    @discardableResult
    func dropOverToolbar(_ payload: ToolbarDragPayload) -> Bool {
        guard isCustomizing(),
              Self.isAcceptedOverToolbar(payload, showsAddressBar: load().showsAddressBar, isDraggedFromToolbar: draggedPayload == payload) else { return false }
        return drop(payload, in: .left, at: 0)
    }

    /// The arrangement index for a drop before the zone's `drawnIndex`th drawn
    /// item, both counted without the dragged item.
    func arrangementIndex(for payload: ToolbarDragPayload, in zone: ToolbarZone, drawnIndex: Int, drawn: [ToolbarItemID]) -> Int {
        let dragged = payload.item
        return ToolbarDropIndex.arrangementIndex(
            drawnIndex: drawnIndex,
            drawn: drawn.filter { $0 != dragged },
            arranged: load().placements(in: zone).map(\.item).filter { $0 != dragged }
        )
    }

    /// Places an item at `index` of `zone`, counted without the item itself,
    /// and marks it as placed by the user; restores the default set, which
    /// clears every mark; or adds the address bar back (whatever the zone).
    /// Placing an unpinned extension pins it.
    @discardableResult
    func drop(_ payload: ToolbarDragPayload, in zone: ToolbarZone, at index: Int) -> Bool {
        guard canDrop(payload, in: zone) else { return false }
        switch payload {
        case .defaultSet:
            save(.standard)
        case .addressBar:
            var arrangement = load()
            arrangement.showsAddressBar = true
            settleDrag(of: payload)
            save(arrangement)
        case .item(let item):
            var arrangement = load()
            // Dropped from the sheet or moved within or between zones: placed by the user.
            guard arrangement.place(item, in: zone, at: index, byUser: true) else { return false }
            settleDrag(of: payload)
            var pinID: String?
            if case .extensionAction(let id) = item, unpinsAfterPin.contains(id) {
                // Placed again before its pin landed: that pin still counts.
                unpinsAfterPin.remove(id)
                pendingUnpinIDs.remove(id)
                pendingPinIDs.insert(id)
            } else if case .extensionAction(let id) = item, pendingUnpinIDs.contains(id), extensions.isPinned(id) {
                // Placed again before its unpin landed: Chromium still has it
                // pinned, so it is pinned again once the unpin lands.
                pendingUnpinIDs.remove(id)
                pendingPinIDs.insert(id)
                pinsAfterUnpin.insert(id)
            } else if case .extensionAction(let id) = item, !extensions.isPinned(id) || pendingUnpinIDs.contains(id) {
                pendingUnpinIDs.remove(id)
                pendingPinIDs.insert(id)
                pinID = id
            }
            save(arrangement)
            if let pinID { extensions.pin(pinID) }
        }
        return true
    }

    /// An item dragged out of the toolbar leaves it; an extension is unpinned
    /// too. A force-pinned extension cannot leave, and nothing leaves once
    /// customizing has ended. Returns false when refused.
    @discardableResult
    func dragEndedOutside(_ item: ToolbarItemID) -> Bool {
        guard isCustomizing() else { return false }
        var arrangement = load()
        guard case .extensionAction(let id) = item else {
            arrangement.remove(item)
            settleDrag(of: .item(item))
            save(arrangement)
            return true
        }
        guard !extensions.isForcePinned(id) else { return false }
        settleDrag(of: .item(item))
        // Counted as unpinned before the save, whose redraw would otherwise
        // store it again from the still-pinned list.
        pendingUnpinIDs.insert(id)
        let hadPendingPin = pendingPinIDs.remove(id) != nil
        // Placed again and dragged out before its first unpin landed: that
        // unpin still counts.
        let unpinInFlight = pinsAfterUnpin.remove(id) != nil
        // Storage never drops an extension on its own (see `addingNewPins`).
        arrangement.remove(item)
        save(arrangement)
        if unpinInFlight {
            // Nothing to send: its first unpin is still on its way.
        } else if hadPendingPin {
            unpinsAfterPin.insert(id)
        } else if extensions.isPinned(id) {
            extensions.unpin(id)
        }
        return true
    }

    /// The address bar dragged out of the toolbar: it leaves, and its
    /// address-zone buttons stay stored for when it comes back. Nothing
    /// leaves once customizing has ended. Returns false when refused.
    @discardableResult
    func addressBarDraggedOut() -> Bool {
        guard isCustomizing() else { return false }
        var arrangement = load()
        arrangement.showsAddressBar = false
        settleDrag(of: .addressBar)
        save(arrangement)
        return true
    }

    /// A toolbar item or the address bar started a drag from the toolbar:
    /// the header lays the toolbar out without it meanwhile. The default
    /// set never sits in the toolbar, and nothing hides once customizing
    /// has ended.
    func dragBegan(_ payload: ToolbarDragPayload) {
        guard isCustomizing(), payload != .defaultSet, draggedPayload != payload else { return }
        draggedPayload = payload
        onChange?()
    }

    /// The drag from the toolbar ended. If it neither landed nor left (let
    /// go over the toolbar off every zone, back where it started, or
    /// cancelled), the item or the address bar shows where it was, as
    /// stored. Called once per drag, after any drop or removal.
    func dragEnded() {
        guard draggedPayload != nil else { return }
        draggedPayload = nil
        onChange?()
    }

    /// The dragged item or address bar landed or left: the save that
    /// follows redraws it from storage, in its new place or not at all.
    private func settleDrag(of payload: ToolbarDragPayload) {
        if draggedPayload == payload { draggedPayload = nil }
    }

    func setVisibility(_ visibility: ToolbarItemVisibility, for item: ToolbarItemID) {
        var arrangement = load()
        arrangement.setVisibility(visibility, for: item)
        save(arrangement)
    }

    /// The sheet's Standard / Minimal switch; the arrangement is kept.
    func setAddressBarStyle(_ style: AddressBarStyle) {
        var arrangement = load()
        arrangement.addressBarStyle = style
        save(arrangement)
    }

    /// A direct drag-reorder of adjacent extensions in the header, outside
    /// Customize Toolbar: they keep their slots in the new order.
    func reorderExtensions(_ ids: [String]) {
        var arrangement = load()
        arrangement.reorder(ids.map(ToolbarItemID.extensionAction))
        save(arrangement)
    }

    /// Chromium's pinned list changed: settles the pins and unpins in flight.
    func pinnedExtensionsDidChange(_ pinnedIDs: [String]) {
        let pinned = Set(pinnedIDs)
        // A pin settles once Chromium lists it, except a re-pin, which
        // waits for the unpin before it to land first.
        pendingPinIDs = pendingPinIDs.filter { !pinned.contains($0) || pinsAfterUnpin.contains($0) }
        for id in pinsAfterUnpin where !pinned.contains(id) {
            pinsAfterUnpin.remove(id)
            extensions.pin(id)
        }
        for id in unpinsAfterPin where pinned.contains(id) {
            unpinsAfterPin.remove(id)
            extensions.unpin(id)
        }
        pendingUnpinIDs = pendingUnpinIDs.filter { pinned.contains($0) || unpinsAfterPin.contains($0) }
    }

    /// What the header draws and stores for Chromium's pinned list, with the
    /// pins and unpins still in flight applied.
    func resolve(stored: ToolbarArrangement, pinnedIDs: [String]) -> (drawn: ToolbarArrangement, toStore: ToolbarArrangement) {
        let pinned = pinnedIDs.filter { !pendingUnpinIDs.contains($0) }
        return (
            stored.reconciled(pinnedExtensionIDs: pinned, pendingPinIDs: pendingPinIDs),
            stored.addingNewPins(pinned)
        )
    }

    /// What the header draws for Chromium's pinned list. Reads the stored
    /// arrangement as it is now, never a snapshot taken earlier, so a save
    /// cannot undo a change made in between, and stores newly pinned
    /// extensions (see `ToolbarArrangement.addingNewPins`). A stored
    /// arrangement this build cannot read is left alone.
    func drawnArrangement(pinnedIDs: [String]) -> ToolbarArrangement {
        let stored = load()
        let (drawn, toStore) = resolve(stored: stored, pinnedIDs: pinnedIDs)
        if toStore != stored, !PhiPreferences.GeneralSettings.hasUnreadableToolbarArrangement(in: defaults) {
            PhiPreferences.GeneralSettings.saveToolbarArrangement(toStore, to: defaults)
        }
        return drawn
    }

    /// Always / On Hover for an item in an address zone while those are
    /// drawn; nil anywhere else.
    func visibilityMenu(for item: ToolbarItemID) -> NSMenu? {
        guard let current = visibility(of: item) else { return nil }
        return ToolbarCustomizationMenu.visibilityMenu(current: current) { [weak self] visibility in
            self?.setVisibility(visibility, for: item)
        }
    }

    /// The stored Always / On Hover setting of an item in an address zone
    /// while those are drawn; nil anywhere else.
    func visibility(of item: ToolbarItemID) -> ToolbarItemVisibility? {
        let arrangement = load()
        guard arrangement.drawsAddressZones, let zone = arrangement.zone(of: item), zone.isAddress else { return nil }
        return arrangement.placements(in: zone).first { $0.item == item }?.visibility
    }

    /// The visibility badge's click: Always becomes On Hover and On Hover
    /// becomes Always, saved as the right-click menu saves it.
    func toggleVisibility(of item: ToolbarItemID) {
        guard let current = visibility(of: item) else { return }
        setVisibility(ToolbarVisibilityBadge.toggled(current), for: item)
    }

    private func load() -> ToolbarArrangement {
        PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults)
    }

    private func save(_ arrangement: ToolbarArrangement) {
        if arrangement != load() {
            PhiPreferences.GeneralSettings.saveToolbarArrangement(arrangement, to: defaults)
        }
        onChange?()
    }
}

// MARK: - Drag source

/// Makes a toolbar item, or an entry of the Customize Toolbar sheet,
/// draggable while customizing. It takes every click on the item, so
/// buttons do nothing. A drag that ends with no drop outside the toolbar it
/// started in calls `onDraggedOut`; a sheet entry has none, so it never
/// removes anything.
///
/// While the pointer is over it, the cursor is an open hand (a closed one
/// while pressed or dragging) and `onHoverChange` lets the item draw its
/// hover fill.
final class ToolbarItemDragSourceView: NSView {
    var payload: ToolbarDragPayload?
    /// The zone the item sits in; nil for an item outside the toolbar.
    var zone: ToolbarZone?
    var onDraggedOut: (() -> Void)?
    /// The right-click menu; without one the click goes on to the toolbar.
    var contextMenu: (() -> NSMenu?)?
    /// Called as the pointer enters and leaves the item.
    var onHoverChange: ((Bool) -> Void)?
    /// The part of the drawn item the drag image shows.
    var dragImageShape: DragImageShape = .region
    /// Drawn under a `.capsule` drag image whether or not the pointer is
    /// over the item: its hover fill, resolved for the toolbar's appearance.
    /// The live fill is left out of the render, so a drag that starts before
    /// the fill shows (a fast flick) or as it fades looks the same.
    var dragImageFill: NSColor?
    /// An image dragged in place of the item, under the pointer where the
    /// press started (`dragImageFrame(size:pressedAt:in:)`): the address
    /// bar's token. Nil from it falls back to the item as drawn.
    var makeDragImage: ((DragImageContext) -> NSImage?)?
    /// A drag from the toolbar started (`ToolbarCustomizationController.dragBegan`):
    /// the toolbar lays out without the item, which removes this view.
    var onDragBegan: (() -> Void)?
    /// The drag ended, after any drop or `onDraggedOut`. Called exactly once
    /// per drag, from the view that started it, even once it has left the
    /// toolbar.
    var onDragEnded: (() -> Void)?

    /// What `makeDragImage` draws with: the window's backing scale and,
    /// for the address bar, its sections as drawn right now
    /// (`addressSectionRects`), each from the bar's end to its innermost
    /// button, on the bar's own fill.
    struct DragImageContext {
        var scale: CGFloat
        var leadingSection: NSImage?
        var trailingSection: NSImage?
    }

    /// What the drag image is cut to.
    enum DragImageShape: Equatable {
        /// Everything drawn under the source: the default, and what the
        /// address token's section captures use. Toolbar items and sheet
        /// tiles use `.capsule`.
        case region
        /// A capsule as wide as the source and at most `maxHeight` tall,
        /// centered: a toolbar item's hover fill.
        case capsule(maxHeight: CGFloat)
    }

    /// The pinned-extension reorder surface's click-vs-drag threshold.
    private static let dragThreshold: CGFloat = 5

    private var mouseDownLocation: NSPoint?
    private var hasDragged = false
    /// The toolbar's frame on screen while a drag from it is in flight.
    private var removalBoundary: NSRect?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    /// Set while AppKit dispatches a left press that hit-tested here, from
    /// the hit test until `mouseDown`.
    private var isDispatchingPress = false
    /// This view, held from the start of a drag to its end. The toolbar
    /// stops drawing the dragged item, so SwiftUI lets go of this view while
    /// AppKit still messages it as the drag's source until
    /// `draggingSession(_:endedAt:operation:)`.
    private var retainedForDrag: ToolbarItemDragSourceView?

    /// Keeps a press on the item from moving the window, so the item drags.
    /// The toolbar sits in the window's titlebar band, where the window
    /// server moves the window on its own unless AppKit leaves the view out
    /// of the drag region, and AppKit does that only for a view that answers
    /// false here and also accepts first responder (TabItemView precedent).
    /// Without the second, only SwiftUI-drawn pixels under the item blocked
    /// the move, so Lottie icons and every icon's margins moved the window.
    override var mouseDownCanMoveWindow: Bool { false }
    /// True whenever AppKit computes the drag region, which it does ahead of
    /// any press. False only while a press on the item is being dispatched,
    /// where the window would otherwise make the item first responder and
    /// take keyboard focus from the page or the address field. Answering
    /// false from the current event alone would also catch a drag region
    /// recomputed after a press, which then lets the next press move the window.
    override var acceptsFirstResponder: Bool { !isDispatchingPress }
    /// Tab never stops here.
    override var canBecomeKeyView: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard payload != nil, super.hitTest(point) != nil else { return nil }
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === window {
            isDispatchingPress = true
            // `mouseDown` clears it; this covers a press that ends up elsewhere.
            DispatchQueue.main.async { [weak self] in self?.isDispatchingPress = false }
        }
        return self
    }

    // MARK: Hover and cursor

    // AppKit calls `updateTrackingAreas` only when it invalidates a window's
    // tracking areas (a resize, a scroll), not when SwiftUI adds this view as
    // an overlay, so the toolbar's sources had none and never saw the
    // pointer. The area is installed on entering a window and on every size
    // change too. It covers the bounds: a SwiftUI-hosted view's visible rect
    // can span its whole window, so `.inVisibleRect` would hover every item.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installTrackingArea()
    }

    private func installTrackingArea() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard window != nil else { return }
        // The sheet's panel is not key, so the area stays active in any window.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard payload != nil else { return super.cursorUpdate(with: event) }
        setCursorUnlessUnderBadge(at: window?.mouseLocationOutsideOfEventStream)
    }

    override func mouseEntered(with event: NSEvent) {
        guard payload != nil else { return }
        setHovered(true)
        // A non-key window (the sheet's panel) gets no cursor updates.
        setCursorUnlessUnderBadge(at: event.locationInWindow)
    }

    /// The hand, unless the pointer is on a visibility badge drawn over
    /// this source (its own button's, or a neighbour's): that keeps the
    /// badge's pointing hand. Coming back from the part of a badge that
    /// sticks out past its button enters the button under the badge, and the
    /// badge itself sees no event then.
    private func setCursorUnlessUnderBadge(at point: NSPoint?) {
        if let point, Self.isOverVisibilityBadge(point, in: window) { return }
        Self.cursor(isPressed: mouseDownLocation != nil).set()
    }

    /// Whether the topmost view at `point` (window coordinates) is a
    /// visibility badge.
    static func isOverVisibilityBadge(_ point: NSPoint, in window: NSWindow?) -> Bool {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return false }
        return root.hitTest(point) is ToolbarVisibilityBadgeView
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        guard mouseDownLocation == nil, !Self.isOverDragSource(event.locationInWindow, in: window) else { return }
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTrackingArea()
        guard window == nil else { return }
        // Removed under the pointer (customizing ended, the item moved):
        // no exit event comes, so the hand would stay. A drag in flight
        // (whose item the toolbar stops drawing) keeps its closed hand.
        if isHovered && retainedForDrag == nil { NSCursor.arrow.set() }
        setHovered(false)
    }

    /// Whether `point` (window coordinates) is over a drag source with
    /// something to drag: an adjacent item, or the address bar around one
    /// of its buttons. Leaving one source for another keeps the hand. A
    /// button's visibility badge counts too: it sets its own cursor, which
    /// leaving the button for it must not replace with the arrow.
    static func isOverDragSource(_ point: NSPoint, in window: NSWindow?) -> Bool {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return false }
        let hit = root.hitTest(point)
        return hit is ToolbarItemDragSourceView || hit is ToolbarVisibilityBadgeView
    }

    /// The open hand over a draggable item, the closed one while it is held.
    static func cursor(isPressed: Bool) -> NSCursor {
        isPressed ? .closedHand : .openHand
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        onHoverChange?(hovered)
    }

    /// After a press or a drag: the open hand and the hover fill if the
    /// pointer is still over the item, the arrow and no fill otherwise.
    private func settlePointer() {
        let location = window?.mouseLocationOutsideOfEventStream
        let isInside = location.map { bounds.contains(convert($0, from: nil)) } ?? false
        setHovered(isInside && payload != nil)
        if isInside && payload != nil {
            if let location, Self.isOverVisibilityBadge(location, in: window) {
                NSCursor.pointingHand.set()
            } else {
                Self.cursor(isPressed: false).set()
            }
        } else if !(location.map { Self.isOverDragSource($0, in: window) } ?? false) {
            NSCursor.arrow.set()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        isDispatchingPress = false
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        mouseDownLocation = event.locationInWindow
        hasDragged = false
        Self.cursor(isPressed: true).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !hasDragged, let payload else { return }
        let location = event.locationInWindow
        guard abs(location.x - start.x) > Self.dragThreshold || abs(location.y - start.y) > Self.dragThreshold else { return }
        hasDragged = true
        beginDrag(payload, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        hasDragged = false
        settlePointer()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    private func beginDrag(_ payload: ToolbarDragPayload, with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload.string, forType: ToolbarDragPayload.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let pressPoint = convert(mouseDownLocation ?? event.locationInWindow, from: nil)
        let image = dragImage(pressedAt: pressPoint)
        draggingItem.setDraggingFrame(image.frame, contents: image.image)
        if onDraggedOut != nil, let header = enclosingHeader, let window = header.window {
            removalBoundary = window.convertToScreen(header.convert(header.bounds, to: nil))
        } else {
            removalBoundary = nil
        }
        retainedForDrag = self
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = Self.animatesBackOnCancel
        onDragBegan?()
    }

    /// Whether AppKit slides a refused or cancelled drag's image back to
    /// where it started: never. From the toolbar, the toolbar draws the item
    /// again as soon as the drag ends, which the slide back would hold up
    /// (`draggingSession(_:endedAt:operation:)` waits for it); from the
    /// sheet, the entry never left it. Either way the image just goes.
    static let animatesBackOnCancel = false

    /// `makeDragImage`'s image under the press, or the item as drawn.
    private func dragImage(pressedAt point: NSPoint) -> (image: NSImage, frame: NSRect) {
        if let makeDragImage {
            let sections: (leading: NSImage?, trailing: NSImage?) = payload == .addressBar ? addressSections() : (nil, nil)
            let context = DragImageContext(scale: window?.backingScaleFactor ?? 2, leadingSection: sections.leading, trailingSection: sections.trailing)
            if let image = makeDragImage(context), image.size.width > 0 {
                return (image, Self.dragImageFrame(size: image.size, pressedAt: point, in: bounds))
            }
        }
        return dragImage()
    }

    /// The address bar's sections as drawn now, for its token: this source
    /// spans the bar (Minimal: its unit), and the bar's buttons are the
    /// address-zone drag sources in the same toolbar.
    private func addressSections() -> (leading: NSImage?, trailing: NSImage?) {
        guard let header = enclosingHeader, let canvas = captureCanvas else { return (nil, nil) }
        let buttons = Self.subviews(of: header) { ($0 as? ToolbarItemDragSourceView)?.zone?.isAddress == true }
            .compactMap { $0 as? ToolbarItemDragSourceView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        func frames(_ zone: ToolbarZone) -> [NSRect] {
            buttons.filter { $0.zone == zone }.map { convert($0.bounds, from: $0) }
        }
        let rects = Self.addressSectionRects(in: bounds, leading: frames(.addressLeading), trailing: frames(.addressTrailing))
        func image(_ rect: NSRect?) -> NSImage? {
            guard let rect, let capture = Self.capture(convert(rect, to: canvas), of: canvas) else { return nil }
            return Self.image(of: capture, cutTo: .region, size: rect.size)
        }
        return (image(rects.leading), image(rects.trailing))
    }

    /// Each address section's part of the bar, in `barBounds`' coordinates:
    /// from the bar's end to the section's innermost button, the bar's full
    /// height, so its rounded end and fill come along. Nil for a section
    /// without buttons.
    static func addressSectionRects(in barBounds: NSRect, leading: [NSRect], trailing: [NSRect]) -> (leading: NSRect?, trailing: NSRect?) {
        let leadingRect = leading.map(\.maxX).max().map {
            NSRect(x: barBounds.minX, y: barBounds.minY, width: max(0, $0 - barBounds.minX), height: barBounds.height)
        }
        let trailingRect = trailing.map(\.minX).min().map {
            NSRect(x: $0, y: barBounds.minY, width: max(0, barBounds.maxX - $0), height: barBounds.height)
        }
        return (leadingRect, trailingRect)
    }

    /// Where an image of `size` is dragged from, in `bounds`' coordinates:
    /// under the press at `point`, as far from the image's leading edge as
    /// the press is from the source's, clamped so the pointer stays on the
    /// image clear of its rounded ends; vertically centered on the source,
    /// the press kept inside.
    static func dragImageFrame(size: NSSize, pressedAt point: NSPoint, in bounds: NSRect) -> NSRect {
        let inset = min(size.height, size.width) / 2
        let offsetX = min(max(point.x - bounds.minX, inset), size.width - inset)
        let centeredY = bounds.midY - size.height / 2
        let y = min(max(centeredY, point.y - size.height), point.y)
        return NSRect(x: point.x - offsetX, y: y, width: size.width, height: size.height)
    }

    private var enclosingHeader: WebContentHeader? {
        Self.enclosingHeader(of: self)
    }

    /// The toolbar a view sits in, if any.
    static func enclosingHeader(of view: NSView) -> WebContentHeader? {
        var ancestor = view.superview
        while let current = ancestor {
            if let header = current as? WebContentHeader { return header }
            ancestor = current.superview
        }
        return nil
    }

    // MARK: Drag image

    /// The part of `bounds` a drag image of `shape` covers, in the same coordinates.
    static func dragImageFrame(for shape: DragImageShape, in bounds: NSRect) -> NSRect {
        switch shape {
        case .region:
            return bounds
        case .capsule(let maxHeight):
            let height = min(bounds.height, maxHeight)
            return NSRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }

    /// The item as drawn right now, at the window's backing scale, cut to
    /// `dragImageShape` on a clear background (on `dragImageFill` for a
    /// capsule), and where it lies in this view, which is where the drag
    /// starts from.
    func dragImage() -> (image: NSImage, frame: NSRect) {
        let frame = Self.dragImageFrame(for: dragImageShape, in: bounds)
        guard let canvas = captureCanvas,
              let capture = Self.capture(convert(frame, to: canvas), of: canvas) else {
            return (NSImage(size: frame.size), frame)
        }
        return (Self.image(of: capture, cutTo: dragImageShape, fill: dragImageFill, size: frame.size), frame)
    }

    /// What the drag image is rendered from. In the toolbar, its SwiftUI
    /// content alone: the header's own layer paints the toolbar's background,
    /// which a render of the header would put around every item. Elsewhere
    /// (the sheet), the window's content.
    private var captureCanvas: NSView? {
        guard let header = enclosingHeader else { return window?.contentView }
        var view: NSView = self
        while let superview = view.superview, superview !== header {
            view = superview
        }
        return view
    }

    /// Renders `rect` of `canvas`, leaving out what only customizing draws
    /// over the items (`isLeftOutOfDragImages`).
    private static func capture(_ rect: NSRect, of canvas: NSView) -> NSBitmapImageRep? {
        guard !rect.isEmpty, let bitmap = canvas.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        let leftOut = subviews(of: canvas, where: isLeftOutOfDragImages)
            .filter { !$0.isHidden }
        leftOut.forEach { $0.isHidden = true }
        defer { leftOut.forEach { $0.isHidden = false } }
        canvas.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }

    /// The zones' outlines and drop markers, the address bar's outline and
    /// the visibility badge, drawn over the items; and the live hover fills,
    /// which an item's image draws itself (`dragImageFill`). Each is an
    /// AppKit view for this reason.
    static func isLeftOutOfDragImages(_ view: NSView) -> Bool {
        view is ToolbarZoneDropView || view is ToolbarCustomizationHoverFillView
            || view is ToolbarAddressBarOutlineView || view is ToolbarVisibilityBadgeView
    }

    private static func subviews(of root: NSView, where matches: (NSView) -> Bool) -> [NSView] {
        var result: [NSView] = []
        var stack = [root]
        while let view = stack.popLast() {
            if matches(view) { result.append(view) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    /// `capture` drawn at `size` over `fill`, cut to `shape`; clear outside it.
    static func image(of capture: NSImageRep, cutTo shape: DragImageShape, fill: NSColor? = nil, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            if case .capsule = shape {
                let radius = rect.height / 2
                let capsule = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                capsule.addClip()
                if let fill {
                    fill.setFill()
                    capsule.fill()
                }
            }
            return capture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

extension ToolbarItemDragSourceView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        Self.cursor(isPressed: true).set()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = Self.animatesBackOnCancel
        Self.cursor(isPressed: true).set()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Released last: the toolbar may no longer hold this view.
        let retained = retainedForDrag
        retainedForDrag = nil
        defer { withExtendedLifetime(retained) {} }
        defer {
            removalBoundary = nil
            mouseDownLocation = nil
            settlePointer()
        }
        if operation == [],
           let removalBoundary, !removalBoundary.contains(screenPoint),
           NSApp.currentEvent?.type != .keyDown {
            onDraggedOut?()
        }
        // After the removal, so a removed item never shows again.
        onDragEnded?()
    }
}

struct ToolbarItemDragSource: NSViewRepresentable {
    let payload: ToolbarDragPayload
    var zone: ToolbarZone?
    var onDraggedOut: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var onHoverChange: ((Bool) -> Void)?
    var dragImageShape: ToolbarItemDragSourceView.DragImageShape = .region
    /// Draws `ToolbarCustomizationHoverFill` under the drag image, in the
    /// toolbar's color scheme.
    var dragImageHasHoverFill = false
    var makeDragImage: ((ToolbarItemDragSourceView.DragImageContext) -> NSImage?)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    func makeNSView(context: Context) -> ToolbarItemDragSourceView {
        ToolbarItemDragSourceView()
    }

    func updateNSView(_ nsView: ToolbarItemDragSourceView, context: Context) {
        nsView.payload = payload
        nsView.zone = zone
        nsView.onDraggedOut = onDraggedOut
        nsView.contextMenu = contextMenu
        nsView.onHoverChange = onHoverChange
        nsView.dragImageShape = dragImageShape
        nsView.dragImageFill = dragImageHasHoverFill
            ? ToolbarCustomizationHoverFill.color(for: context.environment.colorScheme)
            : nil
        nsView.makeDragImage = makeDragImage
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
    }
}

/// The fill behind a draggable item while the pointer is over it: the
/// address bar's own hover color, as a capsule no taller than a button,
/// so a square item gets their circle. A background; it never takes part in
/// layout or hit testing. AppKit draws it (`ToolbarCustomizationHoverFillView`),
/// so a drag image can leave the live fill out and draw its own.
struct ToolbarCustomizationHoverFill: NSViewRepresentable {
    let isHovered: Bool

    /// No taller than a button.
    static let maxHeight = HeaderExtensionLayout.buttonSize

    /// The fill's color for the toolbar's color scheme, which follows the
    /// page's appearance and can differ from the window's.
    static func color(for colorScheme: ColorScheme) -> NSColor {
        ToolbarCustomizationLayout.resolved(.sidebarTabHoveredColorEmphasized, for: colorScheme)
    }

    func makeNSView(context: Context) -> ToolbarCustomizationHoverFillView {
        ToolbarCustomizationHoverFillView()
    }

    func updateNSView(_ nsView: ToolbarCustomizationHoverFillView, context: Context) {
        nsView.color = Self.color(for: context.environment.colorScheme)
        nsView.isHovered = isHovered
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToolbarCustomizationHoverFillView, context: Context) -> CGSize? {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: min(proposal.height ?? Self.maxHeight, Self.maxHeight))
    }
}

/// Draws `ToolbarCustomizationHoverFill`: a capsule filling its bounds
/// while hovered, nothing otherwise.
final class ToolbarCustomizationHoverFillView: NSView {
    var color: NSColor = .clear {
        didSet { if color != oldValue { needsDisplay = true } }
    }
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered, !bounds.isEmpty else { return }
        let radius = bounds.height / 2
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// A toolbar item while customizing: its drag source on top and its hover
/// fill behind it.
private struct ToolbarCustomizationItemSource: ViewModifier {
    let item: ToolbarItemID
    let zone: ToolbarZone
    let customization: ToolbarCustomizationController
    /// Keeps the hover fill while the pointer is off the item but on
    /// something that belongs to it: its visibility badge.
    var keepsHover = false
    /// Reports the pointer over the item, for a bar that drops its own hover fill meanwhile.
    var onHoverChange: ((Bool) -> Void)?

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(ToolbarCustomizationHoverFill(isHovered: isHovered || keepsHover))
            .overlay(ToolbarItemDragSource(
                payload: .item(item),
                zone: zone,
                onDraggedOut: { [weak customization] in _ = customization?.dragEndedOutside(item) },
                contextMenu: { [weak customization] in customization?.visibilityMenu(for: item) },
                onHoverChange: {
                    isHovered = $0
                    onHoverChange?($0)
                },
                // The button on its hover fill, as `ToolbarCustomizationHoverFill`
                // draws it, whether or not the fill shows yet.
                dragImageShape: .capsule(maxHeight: ToolbarCustomizationHoverFill.maxHeight),
                dragImageHasHoverFill: true,
                // The toolbar lays out without it until the drag ends.
                onDragBegan: { [weak customization] in customization?.dragBegan(.item(item)) },
                onDragEnded: { [weak customization] in customization?.dragEnded() }
            ))
            .onDisappear {
                // A removed item never reports the pointer leaving.
                if isHovered {
                    isHovered = false
                    onHoverChange?(false)
                }
            }
    }
}

// MARK: - Visibility badge

/// The eye badge on an address-zone button while customizing, under the
/// pointer: it shows the button's Always / On Hover setting and switches it
/// with a click, which the right-click menu also offers. Left and Right
/// always show their buttons, so theirs get none.
enum ToolbarVisibilityBadge {
    static let size: CGFloat = 14
    static let symbolSize: CGFloat = 9
    /// How far the badge's center sits below the item's top edge, so it
    /// sticks out above the button by `size / 2 - topInset`.
    static let topInset: CGFloat = 3

    /// Only the address zones honor On Hover (`ToolbarArrangement.setVisibility`).
    static func isOffered(in zone: ToolbarZone) -> Bool {
        zone.isAddress
    }

    static func toggled(_ visibility: ToolbarItemVisibility) -> ToolbarItemVisibility {
        visibility == .always ? .onHover : .always
    }

    /// The current setting: an open eye for Always, a crossed one for On Hover.
    static func symbolName(for visibility: ToolbarItemVisibility) -> String {
        visibility == .always ? "eye" : "eye.slash"
    }

    /// What a click does, to the button named `itemName`.
    static func accessibilityLabel(for visibility: ToolbarItemVisibility, itemName: String) -> String {
        switch visibility {
        case .always:
            return String(format: NSLocalizedString("browser.toolbarCustomization.visibilityBadge.showOnHover", value: "Show %@ on Hover", comment: "Customize Toolbar - Accessibility label of the eye badge on a button in the address bar that is always shown; pressing it shows the button only while the pointer is over the address bar. %@ is the button's name, such as Copy URL"), itemName)
        case .onHover:
            return String(format: NSLocalizedString("browser.toolbarCustomization.visibilityBadge.showAlways", value: "Always Show %@", comment: "Customize Toolbar - Accessibility label of the eye badge on a button in the address bar that shows only on hover; pressing it shows the button at all times. %@ is the button's name, such as Copy URL"), itemName)
        }
    }

    /// The current setting and what a click does.
    static func tooltip(for visibility: ToolbarItemVisibility) -> String {
        switch visibility {
        case .always:
            return NSLocalizedString("browser.toolbarCustomization.visibilityBadge.tooltipAlways", value: "Always shown. Click to show only on hover.", comment: "Customize Toolbar - Tooltip of the eye badge on a button in the address bar that is always shown")
        case .onHover:
            return NSLocalizedString("browser.toolbarCustomization.visibilityBadge.tooltipOnHover", value: "Shown on hover. Click to always show.", comment: "Customize Toolbar - Tooltip of the eye badge on a button in the address bar that shows only while the pointer is over the address bar")
        }
    }

    /// The button whose badge shows: the one under the badge's pointer, else
    /// the first of `drawnItems` under the pointer. Moving from a button onto
    /// its badge keeps it, even where the badge sticks out past the button.
    /// None while an item or the address bar is dragged from the toolbar.
    static func item(drawnItems: [ToolbarItemID], hoveredItems: Set<ToolbarItemID>, badgeHoveredItem: ToolbarItemID?, isDragging: Bool) -> ToolbarItemID? {
        guard !isDragging else { return nil }
        if let badgeHoveredItem, drawnItems.contains(badgeHoveredItem) { return badgeHoveredItem }
        return drawnItems.first(where: hoveredItems.contains)
    }

    /// The badge's center for an item drawn in `itemBounds` (y grows down):
    /// its right edge on the button's, so it never reaches the next button
    /// (`WebContentAddressBarView.itemSpacing` away), and sticking out above
    /// the button's top edge.
    static func center(in itemBounds: CGRect) -> CGPoint {
        CGPoint(x: itemBounds.maxX - size / 2, y: itemBounds.minY + topInset)
    }
}

/// The badge an address-zone item publishes while it shows one, for the
/// address bar to draw over everything it holds (Standard's capsule clips
/// its content, and the badge sticks out past the button).
struct ToolbarVisibilityBadgeTarget {
    let item: ToolbarItemID
    let visibility: ToolbarItemVisibility
    let bounds: Anchor<CGRect>
}

struct ToolbarVisibilityBadgeKey: PreferenceKey {
    static var defaultValue: ToolbarVisibilityBadgeTarget? { nil }

    static func reduce(value: inout ToolbarVisibilityBadgeTarget?, nextValue: () -> ToolbarVisibilityBadgeTarget?) {
        value = value ?? nextValue()
    }
}

/// Draws the badge and takes its clicks: a circle in the address bar's
/// resting fill (under its hover color while the pointer is on the badge), a
/// point-wide border in the customize outlines' color, and the eye. AppKit
/// draws it so drag images can leave it out (`isLeftOutOfDragImages`).
///
/// Like the drag source under it, it sits in the titlebar band, so it
/// answers `mouseDownCanMoveWindow` false and accepts first responder except
/// while its own press is being dispatched: a press neither moves the window
/// nor takes keyboard focus. It is no drag source, so a press on it never
/// drags the button.
final class ToolbarVisibilityBadgeView: NSView {
    var visibility: ToolbarItemVisibility = .always {
        didSet {
            guard visibility != oldValue else { return }
            toolTip = ToolbarVisibilityBadge.tooltip(for: visibility)
            needsDisplay = true
        }
    }
    /// The colors, resolved for the toolbar's appearance.
    var fillColor: NSColor = .clear {
        didSet { if fillColor != oldValue { needsDisplay = true } }
    }
    var hoverColor: NSColor = .clear {
        didSet { if hoverColor != oldValue { needsDisplay = true } }
    }
    var borderColor: NSColor = .clear {
        didSet { if borderColor != oldValue { needsDisplay = true } }
    }
    var symbolColor: NSColor = .labelColor {
        didSet { if symbolColor != oldValue { needsDisplay = true } }
    }
    /// The name of the button it acts on, for its accessibility label.
    var itemName = ""
    /// A click on the badge; without one the badge takes no clicks.
    var onToggle: (() -> Void)?
    /// Called as the pointer enters and leaves the badge.
    var onHoverChange: ((Bool) -> Void)?
    /// The button's right-click menu.
    var contextMenu: (() -> NSMenu?)?

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    /// Set while AppKit dispatches a left press that hit-tested here, from
    /// the hit test until `mouseDown` (see `ToolbarItemDragSourceView`).
    private var isDispatchingPress = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = ToolbarVisibilityBadge.tooltip(for: visibility)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { !isDispatchingPress }
    override var canBecomeKeyView: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onToggle != nil, super.hitTest(point) != nil else { return nil }
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === window {
            isDispatchingPress = true
            // `mouseDown` clears it; this covers a press that ends up elsewhere.
            DispatchQueue.main.async { [weak self] in self?.isDispatchingPress = false }
        }
        return self
    }

    // MARK: Hover and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installTrackingArea()
    }

    /// Over its bounds, installed by the view itself, as the drag source's.
    private func installTrackingArea() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard let window else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        // The badge shows once the pointer is on its button, which can
        // already put the pointer on the badge: no entry event comes then.
        if onToggle != nil, !isHovered, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            setHovered(true)
            NSCursor.pointingHand.set()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTrackingArea()
        guard window == nil else { return }
        // Removed under the pointer (customizing ended): no exit event comes.
        if isHovered { NSCursor.arrow.set() }
        setHovered(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard onToggle != nil else { return super.cursorUpdate(with: event) }
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard onToggle != nil else { return }
        setHovered(true)
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        setCursor(at: event.locationInWindow)
    }

    /// The pointing hand on the badge; back on its button the open hand;
    /// off both, the arrow.
    private func setCursor(at point: NSPoint) {
        if bounds.contains(convert(point, from: nil)) {
            NSCursor.pointingHand.set()
        } else if ToolbarItemDragSourceView.isOverDragSource(point, in: window) {
            ToolbarItemDragSourceView.cursor(isPressed: false).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHoverChange?(hovered)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        fillColor.setFill()
        circle.fill()
        if isHovered {
            hoverColor.setFill()
            circle.fill()
        }
        circle.lineWidth = 1
        borderColor.setStroke()
        circle.stroke()

        let configuration = NSImage.SymbolConfiguration(pointSize: ToolbarVisibilityBadge.symbolSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [symbolColor]))
        guard let symbol = NSImage(systemSymbolName: ToolbarVisibilityBadge.symbolName(for: visibility), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        isDispatchingPress = false
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        isPressed = true
    }

    /// A press that moves stays a press on the badge: nothing drags.
    override func mouseDragged(with event: NSEvent) {}

    /// Released over the badge: a click. Either way the hover and cursor
    /// follow where the pointer is now: the tracking area reports nothing
    /// while the button is held, so a press dragged off the badge would
    /// otherwise leave it hovered with the pointing hand.
    override func mouseUp(with event: NSEvent) {
        let point = event.locationInWindow
        let wasPressed = isPressed
        isPressed = false
        let isInside = bounds.contains(convert(point, from: nil))
        setHovered(isInside && onToggle != nil)
        setCursor(at: point)
        if wasPressed && isInside { onToggle?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { ToolbarVisibilityBadge.accessibilityLabel(for: visibility, itemName: itemName) }
    override func accessibilityHelp() -> String? { ToolbarVisibilityBadge.tooltip(for: visibility) }

    override func accessibilityPerformPress() -> Bool {
        guard let onToggle else { return false }
        onToggle()
        return true
    }
}

/// The badge in SwiftUI, `ToolbarVisibilityBadge.size` square.
struct ToolbarVisibilityBadgeButton: NSViewRepresentable {
    let visibility: ToolbarItemVisibility
    /// The name of the button it acts on.
    let itemName: String
    /// The address bar's resting fill.
    let background: NSColor
    let onToggle: () -> Void
    var onHoverChange: ((Bool) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    func makeNSView(context: Context) -> ToolbarVisibilityBadgeView {
        ToolbarVisibilityBadgeView()
    }

    func updateNSView(_ nsView: ToolbarVisibilityBadgeView, context: Context) {
        let colorScheme = context.environment.colorScheme
        let theme = context.environment.phiTheme
        let appearance = context.environment.phiAppearance
        let symbolColor = visibility == .always ? ThemedColor.textPrimary : ThemedColor.textSecondary
        nsView.visibility = visibility
        nsView.itemName = itemName
        nsView.fillColor = ToolbarCustomizationLayout.resolved(background, for: colorScheme)
        nsView.hoverColor = ToolbarCustomizationHoverFill.color(for: colorScheme)
        nsView.borderColor = ToolbarCustomizationLayout.resolved(.tertiaryLabelColor, for: colorScheme)
        nsView.symbolColor = ToolbarCustomizationLayout.resolved(symbolColor.resolver(theme, appearance), for: colorScheme)
        nsView.onToggle = onToggle
        nsView.onHoverChange = onHoverChange
        nsView.contextMenu = contextMenu
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToolbarVisibilityBadgeView, context: Context) -> CGSize? {
        CGSize(width: ToolbarVisibilityBadge.size, height: ToolbarVisibilityBadge.size)
    }
}

// MARK: - Drop target

/// One zone of the toolbar while customizing: a dashed outline that accepts
/// drops and marks where the item will land. It is laid over the zone's
/// drawn items (or, for an empty zone, over the space the zone reserves) and
/// never changes layout itself. It never takes clicks; the items' drag
/// sources beneath it do.
/// An address zone draws no outline of its own: the address bar's outline
/// and section dividers mark it (`ToolbarAddressBarOutline` and
/// `ToolbarAddressSectionDividers`).
final class ToolbarZoneDropView: NSView {
    var zone: ToolbarZone = .left
    var canDrop: (ToolbarDragPayload) -> Bool = { _ in false }
    /// Drops before the `Int`th of the zone's drawn items (the dragged one left
    /// out), passed in drawing order.
    var onDrop: (ToolbarDragPayload, Int, [ToolbarItemID]) -> Bool = { _, _, _ in false }

    private struct DrawnItem {
        let item: ToolbarItemID
        let minX: CGFloat
        let maxX: CGFloat
    }

    private var payload: ToolbarDragPayload?
    private var drawnItems: [DrawnItem] = []
    private var insertionX: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([ToolbarDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = ToolbarDragPayload(pasteboard: sender.draggingPasteboard), canDrop(payload) else {
            reset()
            return []
        }
        self.payload = payload
        needsDisplay = true
        return update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        reset()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        reset()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload else { return false }
        let items = currentDrawnItems(excluding: payload.item)
        let index = ToolbarDropIndex.index(
            forX: convert(sender.draggingLocation, from: nil).x,
            itemMidXs: items.map { ($0.minX + $0.maxX) / 2 }
        )
        reset()
        return onDrop(payload, index, items.map(\.item))
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload else { return [] }
        // The default set and the address bar do not land at an index.
        guard payload.item != nil else { return .move }
        // Read again on every move: the toolbar reflows once an item dragged
        // from it stops being laid out, which can follow the drag's entry.
        drawnItems = currentDrawnItems(excluding: payload.item)
        let x = convert(sender.draggingLocation, from: nil).x
        let index = ToolbarDropIndex.index(forX: x, itemMidXs: drawnItems.map { ($0.minX + $0.maxX) / 2 })
        let markerX: CGFloat
        if drawnItems.isEmpty {
            markerX = bounds.midX
        } else if index < drawnItems.count {
            markerX = drawnItems[index].minX - 1
        } else {
            markerX = drawnItems[drawnItems.count - 1].maxX + 1
        }
        let clamped = min(max(markerX, 2), bounds.maxX - 2)
        if clamped != insertionX {
            insertionX = clamped
            needsDisplay = true
        }
        return .move
    }

    private func reset() {
        guard payload != nil || insertionX != nil else { return }
        payload = nil
        drawnItems = []
        insertionX = nil
        needsDisplay = true
    }

    /// The drag sources of this zone in the same toolbar, left to right.
    private func currentDrawnItems(excluding dragged: ToolbarItemID?) -> [DrawnItem] {
        guard let root = ToolbarItemDragSourceView.enclosingHeader(of: self) ?? window?.contentView else { return [] }
        var result: [DrawnItem] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let source = view as? ToolbarItemDragSourceView {
                if source.zone == zone, !source.isHiddenOrHasHiddenAncestor,
                   let item = source.payload?.item, item != dragged {
                    let frame = convert(source.bounds, from: source)
                    result.append(DrawnItem(item: item, minX: frame.minX, maxX: frame.maxX))
                }
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        return result.sorted { $0.minX < $1.minX }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        // An address zone's outline is a capsule, so it fits the bar's rounded ends.
        let radius = zone.isAddress ? rect.height / 2 : 6
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        if payload != nil {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            outline.fill()
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        } else if !zone.isAddress {
            outline.setLineDash(ToolbarCustomizationLayout.outlineDash, count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            outline.stroke()
        }

        if let insertionX {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: insertionX - 1, y: rect.minY + 3, width: 2, height: max(rect.height - 6, 0)),
                xRadius: 1, yRadius: 1
            ).fill()
        }
    }
}

struct ToolbarZoneDropTarget: NSViewRepresentable {
    let zone: ToolbarZone
    let canDrop: (ToolbarDragPayload) -> Bool
    let onDrop: (ToolbarDragPayload, Int, [ToolbarItemID]) -> Bool

    func makeNSView(context: Context) -> ToolbarZoneDropView {
        ToolbarZoneDropView()
    }

    func updateNSView(_ nsView: ToolbarZoneDropView, context: Context) {
        nsView.zone = zone
        nsView.canDrop = canDrop
        nsView.onDrop = onDrop
    }
}

// MARK: - Toolbar views

/// Where Customize Toolbar draws its outlines. They are overlays and never
/// take part in layout, so turning customizing on moves nothing.
enum ToolbarCustomizationLayout {
    /// How far a side zone's outline reaches past its outer items, into the
    /// padding around the zone. An address zone's stays inside the bar.
    static let sideZoneOutset: CGFloat = 3
    /// The width of an empty zone's drop target, and of the space an empty
    /// side zone reserves for it while customizing (`sideZoneReserve`). Every
    /// empty zone looks this wide; see `addressSectionReserve`.
    static let emptyZoneWidth: CGFloat = 28
    /// How wide an empty zone looks: the outer edges of a side zone's
    /// outline, which is inset by a point and stroked a point wide.
    static var emptyZoneVisibleWidth: CGFloat { emptyZoneWidth - 1 }

    /// While customizing, every empty zone reserves layout space, so it shows
    /// as a place to drop and no two zones overlap: the owner's exception to
    /// customizing moving nothing. Nil (no reserve) for a zone with items or
    /// outside customizing, which leaves layout as it is.
    static func sideZoneReserve(isEmpty: Bool, isCustomizing: Bool) -> CGFloat? {
        isEmpty && isCustomizing ? emptyZoneWidth : nil
    }

    /// The space an empty address section reserves next to the address
    /// text, whose region starts with the section's dashed divider. From the
    /// bar's outline to the divider's far edge, the section then looks
    /// exactly as wide as an empty side zone.
    static var addressSectionReserve: CGFloat {
        emptyZoneVisibleWidth - outlineStroke.lineWidth
    }
    /// Every outline is a toolbar row tall, the address bar's height too.
    static let outlineHeight: CGFloat = HeaderTrailingLayout.rowHeight
    /// The dash of every resting outline and divider: 3 points on, 2 off.
    static let outlineDash: [CGFloat] = [3, 2]
    static let outlineStroke = StrokeStyle(lineWidth: 1, dash: outlineDash)
    /// How tall the address bar's section dividers are.
    static let dividerHeight: CGFloat = 16

    /// `color` resolved for the toolbar's color scheme, which follows the
    /// page's appearance and can differ from the window's: for what AppKit
    /// draws in the toolbar.
    static func resolved(_ color: NSColor, for colorScheme: ColorScheme) -> NSColor {
        guard let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) else { return color }
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: color.cgColor) ?? color
        }
        return resolved
    }

    /// Where an empty zone's target lies on its anchor: the side zones over
    /// their reserve; the address zones over their reserve, from the bar's
    /// leading or trailing end.
    static func emptyZoneAlignment(_ zone: ToolbarZone) -> Alignment {
        switch zone {
        case .left: return .center
        case .addressLeading: return .leading
        case .addressTrailing, .right: return .trailing
        }
    }
}

extension View {
    /// While customizing (`customization` is set), the item becomes a drag
    /// source that takes its clicks, with a hover fill behind it; dragged out
    /// of the toolbar it leaves it. `keepsHover` holds the fill while the
    /// pointer is on the item's visibility badge.
    @ViewBuilder
    func toolbarCustomizationSource(_ item: ToolbarItemID, in zone: ToolbarZone, customization: ToolbarCustomizationController?, keepsHover: Bool = false, onHoverChange: ((Bool) -> Void)? = nil) -> some View {
        if let customization {
            modifier(ToolbarCustomizationItemSource(item: item, zone: zone, customization: customization, keepsHover: keepsHover, onHoverChange: onHoverChange))
        } else {
            self
        }
    }

    /// While customizing (`customization` is set), the whole address bar
    /// becomes a drag source, laid behind its buttons so they stay
    /// draggable on their own; dragged out of the toolbar it leaves it. The
    /// bar itself keeps its identity, so customizing resets none of its state.
    /// The drag carries `dragToken`'s compact capsule with the bar's
    /// sections as drawn, not the bar.
    /// `onHoverChange` reports the pointer over the bar, its buttons included.
    func toolbarCustomizationAddressBarSource(customization: ToolbarCustomizationController?, dragToken: @escaping () -> ToolbarAddressBarDragToken, onHoverChange: ((Bool) -> Void)? = nil) -> some View {
        background {
            if let customization {
                ToolbarItemDragSource(
                    payload: .addressBar,
                    onDraggedOut: { [weak customization] in _ = customization?.addressBarDraggedOut() },
                    onHoverChange: onHoverChange,
                    makeDragImage: { context in
                        var token = dragToken()
                        token.leadingSection = context.leadingSection
                        token.trailingSection = context.trailingSection
                        return token.image(scale: context.scale)
                    },
                    // The toolbar lays out without the bar until the drag ends.
                    onDragBegan: { [weak customization] in customization?.dragBegan(.addressBar) },
                    onDragEnded: { [weak customization] in customization?.dragEnded() }
                )
            }
        }
    }

    /// While customizing, outlines the zone and accepts drops into it, as an
    /// overlay that leaves layout alone. Applied to the zone's drawn items it
    /// hugs them; `isEmpty` marks an anchor with no items drawn, over which an
    /// `emptyZoneWidth` target lies (see `emptyZoneAlignment`).
    @ViewBuilder
    func toolbarCustomizationZone(_ zone: ToolbarZone, isEmpty: Bool, customization: ToolbarCustomizationController?) -> some View {
        if let customization {
            let outset = isEmpty || zone.isAddress ? 0 : ToolbarCustomizationLayout.sideZoneOutset
            overlay(alignment: isEmpty ? ToolbarCustomizationLayout.emptyZoneAlignment(zone) : .center) {
                ToolbarZoneDropTarget(
                    zone: zone,
                    canDrop: { [weak customization] in customization?.canDrop($0, in: zone) ?? false },
                    onDrop: { [weak customization] payload, drawnIndex, drawn in
                        guard let customization else { return false }
                        let index = customization.arrangementIndex(for: payload, in: zone, drawnIndex: drawnIndex, drawn: drawn)
                        return customization.drop(payload, in: zone, at: index)
                    }
                )
                .padding(.horizontal, -outset)
                .frame(
                    width: isEmpty ? ToolbarCustomizationLayout.emptyZoneWidth : nil,
                    height: ToolbarCustomizationLayout.outlineHeight
                )
            }
        } else {
            self
        }
    }
}

/// The address bar's outline while customizing: a dashed capsule around the
/// whole bar, as an overlay that never takes part in layout. AppKit draws it
/// (`ToolbarAddressBarOutlineView`), so drag images can leave it out.
struct ToolbarAddressBarOutline: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarAddressBarOutlineView {
        ToolbarAddressBarOutlineView()
    }

    func updateNSView(_ nsView: ToolbarAddressBarOutlineView, context: Context) {
        nsView.color = ToolbarCustomizationLayout.resolved(.tertiaryLabelColor, for: context.environment.colorScheme)
    }
}

/// Draws `ToolbarAddressBarOutline`: a dashed capsule just inside its bounds.
final class ToolbarAddressBarOutlineView: NSView {
    var color: NSColor = .tertiaryLabelColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth = ToolbarCustomizationLayout.outlineStroke.lineWidth
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard !rect.isEmpty else { return }
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        path.setLineDash(ToolbarCustomizationLayout.outlineDash, count: ToolbarCustomizationLayout.outlineDash.count, phase: 0)
        color.setStroke()
        path.stroke()
    }
}

/// The address bar's section dividers while customizing, laid over the
/// address text region: a dashed line at each of its ends, right against the
/// section beside it, so the region's padding lies between the line and the
/// address. They mark the leading section, the address and the trailing
/// section. An overlay; it never takes part in layout.
struct ToolbarAddressSectionDividers: View {
    var body: some View {
        HStack(spacing: 0) {
            divider
            Spacer(minLength: 0)
            divider
        }
        .allowsHitTesting(false)
    }

    private var divider: some View {
        Path { path in
            path.move(to: CGPoint(x: 0.5, y: 0))
            path.addLine(to: CGPoint(x: 0.5, y: ToolbarCustomizationLayout.dividerHeight))
        }
        .stroke(Color(nsColor: .tertiaryLabelColor), style: ToolbarCustomizationLayout.outlineStroke)
        .frame(width: 1, height: ToolbarCustomizationLayout.dividerHeight)
    }
}

// MARK: - Address bar drag token

/// What a drag of the address bar carries while customizing: a compact
/// capsule with the bar's leading section and the page's domain, then its
/// trailing section, in the bar's resting fill under its
/// hover color, for the toolbar's color scheme. The sections are the bar's
/// own, as drawn when the drag starts (On Hover buttons included, since
/// customizing shows them), each with its rounded end and hover fill, so
/// the hover color is laid only between them. The system shrinks a drag
/// image as wide as the bar to a fixed small size on its own, so the bar is
/// not dragged as itself. Rendered offscreen, clear outside the capsule.
struct ToolbarAddressBarDragToken {
    /// The page's domain, or `placeholder` without a page.
    let text: String
    let isPlaceholder: Bool
    let colorScheme: ColorScheme
    /// The bar's resting fill: the page's color, or the window background.
    let background: Color
    let textColor: Color
    let placeholderColor: Color
    /// The bar's sections as drawn (`ToolbarItemDragSourceView.DragImageContext`).
    var leadingSection: NSImage?
    var trailingSection: NSImage?

    init(urlString: String?, colorScheme: ColorScheme, background: Color, textColor: Color, placeholderColor: Color) {
        let domain = Self.domain(of: urlString)
        text = domain ?? Self.placeholder
        isPlaceholder = domain == nil
        self.colorScheme = colorScheme
        self.background = background
        self.textColor = textColor
        self.placeholderColor = placeholderColor
    }

    static let height = HeaderTrailingLayout.rowHeight
    static let minWidth: CGFloat = 120
    /// The domain truncates first; sections wider than this widen the token.
    static let maxWidth: CGFloat = 320
    static let horizontalPadding: CGFloat = 10
    /// The address bar's text size.
    static let fontSize: CGFloat = 13

    /// The domain the bar shows with Always Show URL Path off (as Minimal
    /// does by default); nil for no page or the new tab page.
    static func domain(of urlString: String?) -> String? {
        let text = WebContentAddressBarViewModel.addressText(for: urlString ?? "", alwaysShowURLPath: false)
        return text.isEmpty ? nil : text
    }

    static var placeholder: String {
        NSLocalizedString("browser.toolbarCustomization.addressBarDragToken.placeholder", value: "Address", comment: "Customize Toolbar - Label of the small capsule that follows the pointer while the address bar is dragged, when the page has no address to show (for example a new tab)")
    }

    /// The padding between a section and the text: Standard's
    /// beside buttons, or `horizontalPadding` at an end without any.
    static func padding(besideSectionOfWidth width: CGFloat) -> CGFloat {
        width > 0 ? WebContentAddressBarView.textPaddingBesideButtons : horizontalPadding
    }

    /// Fits the sections and `textWidth` of text, between
    /// `minWidth` and `maxWidth`; longer text truncates. Sections that alone
    /// pass `maxWidth` widen it: they never truncate.
    static func width(textWidth: CGFloat, leadingSectionWidth: CGFloat = 0, trailingSectionWidth: CGFloat = 0) -> CGFloat {
        let fixed = leadingSectionWidth + padding(besideSectionOfWidth: leadingSectionWidth)
            + padding(besideSectionOfWidth: trailingSectionWidth) + trailingSectionWidth
        let natural = ceil(fixed + textWidth)
        return min(max(natural, minWidth), max(maxWidth, ceil(fixed)))
    }

    var size: CGSize {
        let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.fontSize)]).width
        let width = Self.width(
            textWidth: textWidth,
            leadingSectionWidth: leadingSection?.size.width ?? 0,
            trailingSectionWidth: trailingSection?.size.width ?? 0
        )
        return CGSize(width: width, height: Self.height)
    }

    /// The token at `scale` pixels per point, or nil if it cannot be drawn.
    @MainActor
    func image(scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: ToolbarAddressBarDragTokenView(token: self)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = scale
        renderer.isOpaque = false
        var image: NSImage?
        // AppKit-backed colors resolve for the token's scheme, not the app's.
        if let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        } else {
            image = renderer.nsImage
        }
        return image
    }
}

private struct ToolbarAddressBarDragTokenView: View {
    let token: ToolbarAddressBarDragToken

    private typealias Token = ToolbarAddressBarDragToken

    var body: some View {
        let size = token.size
        let leadingWidth = token.leadingSection?.size.width ?? 0
        let trailingWidth = token.trailingSection?.size.width ?? 0
        HStack(spacing: 0) {
            section(token.leadingSection)
            Text(verbatim: token.text)
                .font(.system(size: Token.fontSize))
                .foregroundStyle(token.isPlaceholder ? token.placeholderColor : token.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            .padding(.leading, Token.padding(besideSectionOfWidth: leadingWidth))
            .padding(.trailing, Token.padding(besideSectionOfWidth: trailingWidth))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The bar's hover color; each section brings its own.
            .background(Color(.sidebarTabHoveredColorEmphasized))
            section(token.trailingSection)
        }
        .frame(width: size.width, height: size.height)
        // The bar's resting fill under everything.
        .background(token.background)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func section(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .frame(width: image.size.width, height: image.size.height)
        }
    }
}
