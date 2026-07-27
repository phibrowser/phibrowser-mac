// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

enum HeaderExtensionLayout {
    static let buttonSize: CGFloat = 24
    static let iconSize: CGFloat = 14
    static let itemSpacing: CGFloat = 2
}

/// Small badge pill overlaid on an extension icon, mirroring Chrome's action
/// badge. Colors come resolved from Chromium (see ExtensionManager.BadgeState).
struct ExtensionBadge: View {
    let state: ExtensionManager.BadgeState

    var body: some View {
        Text(state.text)
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Color(nsColor: state.textColor))
            .padding(.horizontal, 2)
            .frame(minWidth: 11, minHeight: 11)
            .background(Capsule().fill(Color(nsColor: state.backgroundColor)))
            .fixedSize()
    }
}

/// Full-size, non-interactive SwiftUI overlay for embedding the badge on AppKit
/// surfaces via `NSHostingView`. Host it edge-pinned over the button/cell
/// (edges are flip-agnostic, unlike AppKit top/bottom constraints); inside, a
/// centered `iconSize` region anchors the badge to the icon's bottom-right via
/// SwiftUI's flip-correct `.bottomTrailing`. Self-observing, so the host updates
/// when the badge changes — no manual subscription needed.
struct BadgeCornerOverlay: View {
    @ObservedObject var manager: ExtensionManager
    let extensionId: String
    let iconSize: CGFloat

    var body: some View {
        Color.clear
            .overlay {
                Color.clear
                    .frame(width: iconSize, height: iconSize)
                    .extensionBadgeOverlay(manager.badges[extensionId])
            }
            .allowsHitTesting(false)
    }
}

/// Hosts a decorative badge overlay over an AppKit control without intercepting
/// its clicks. A plain `NSHostingView` can still swallow mouse events even when
/// its SwiftUI content is `.allowsHitTesting(false)` — which kills a SwiftUI
/// `Button`-backed control beneath it (e.g. the sidebar address-bar extension
/// icon, whose `HoverableButton` tap then never fires). Forcing `hitTest` to nil
/// passes every event through to the control below.
final class BadgeHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Overlays the action badge straddling this icon's bottom-right corner
    /// (partial overlap, Chrome-style). Apply directly to the icon view so the
    /// badge anchors to the icon, not its (larger) container.
    func extensionBadgeOverlay(_ state: ExtensionManager.BadgeState?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let state, !state.text.isEmpty {
                ExtensionBadge(state: state)
                    .offset(x: 4, y: 4)
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor
final class WebContentHeaderExtensionsModel: ObservableObject {
    /// The full sorted pinned set.
    @Published private(set) var pinnedExtensions: [Extension] = []
    /// Pinned extensions whose action is visible on the current tab — what the
    /// header actually lays out. Filtering here (not just per-button EmptyView)
    /// stops a hidden page action from consuming a width slot and truncating a
    /// genuinely visible extension off the header.
    @Published private(set) var visiblePinnedExtensions: [Extension] = []

    private weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()

    init(browserState: BrowserState?) {
        self.browserState = browserState
        bindExtensions()
        refreshExtensionsIfNeeded()
    }

    private func bindExtensions() {
        guard let manager = browserState?.extensionManager else { return }

        manager.$pinedExtensions
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] exts in
                let sorted = exts.sorted { lhs, rhs in
                    if lhs.pinnedIndex == rhs.pinnedIndex {
                        return lhs.name < rhs.name
                    }
                    return lhs.pinnedIndex < rhs.pinnedIndex
                }
                self?.pinnedExtensions = sorted
                self?.recomputeVisiblePinned()
            }
            .store(in: &cancellables)

        // Recompute the laid-out set when an extension's visibility flips (a page
        // action shown/hidden on the current tab). Gated on the hidden-id set so
        // a rapid badge-text tick (e.g. a blocked-count) does NOT recompute.
        manager.$badges
            .map { badges in Set(badges.compactMap { $0.value.visible ? nil : $0.key }) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeVisiblePinned()
            }
            .store(in: &cancellables)

        manager.pinnedExtensionOrdering.$presentationOrder
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeVisiblePinned()
            }
            .store(in: &cancellables)
    }

    private func recomputeVisiblePinned() {
        guard let manager = browserState?.extensionManager else {
            visiblePinnedExtensions = pinnedExtensions
            return
        }
        let ordered = manager.presentedPinnedOrder(of: pinnedExtensions)
        visiblePinnedExtensions = ordered.filter {
            manager.badges[$0.id]?.visible != false
        }
    }

    private func refreshExtensionsIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.browserState?.extensionManager.refreshExtensions()
        }
    }
}

struct CircularIconButton: View {
    let image: NSImage?
    let imageResource: ImageResource?
    let systemName: String?
    let accessibilityLabel: String
    let action: () -> Void
    let secondaryAction: (() -> Void)?

    @State private var isHovering = false

    init(
        image: NSImage? = nil,
        imageResource: ImageResource? = nil,
        systemName: String? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.image = image
        self.imageResource = imageResource
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? .sidebarTabHoveredColorEmphasized : Color.clear)

                if let imageResource {
                    Image(imageResource)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: HeaderExtensionLayout.iconSize, weight: .regular))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: HeaderExtensionLayout.buttonSize, height: HeaderExtensionLayout.buttonSize)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .overlay(
            SecondaryClickPassthrough(onSecondaryClick: secondaryAction)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

/// Red dot on the ⊞ overflow button when an *unpinned* extension has a
/// non-empty, visible badge on the current tab (so it isn't missed off-toolbar).
private struct OverflowBadgeDot: View {
    /// Product decision (2026-06): the dot is force-hidden — with several
    /// unpinned badge-setting extensions installed (Stylish, Tampermonkey,
    /// DuckDuckGo, …) it would be lit almost permanently and reads as noise.
    /// To bring the dot back, flip this to true; the detection logic below is
    /// intentionally kept working.
    private static let isEnabled = false

    @ObservedObject var manager: ExtensionManager

    var body: some View {
        let pinnedIds = Set(manager.pinedExtensions.map(\.id))
        let hasHiddenBadge = manager.badges.contains { id, state in
            !state.text.isEmpty && state.visible && !pinnedIds.contains(id)
        }
        if Self.isEnabled && hasHiddenBadge {
            Circle().fill(.red).frame(width: 6, height: 6)
        }
    }
}

struct HeaderExtensionMenuButton: View {
    let extensionManager: ExtensionManager?
    @Binding var isPopoverShown: Bool

    @State private var anchorView: NSView?

    var body: some View {
        CircularIconButton(
            imageResource: .extensionIcon,
            accessibilityLabel: NSLocalizedString("browser.webContentHeader.extensionsButton.accessibilityLabel", value: "Extensions", comment: "Web content header - Extensions menu button")
        ) {
            isPopoverShown.toggle()
        }
        .overlay(alignment: .bottomTrailing) {
            if let manager = extensionManager {
                OverflowBadgeDot(manager: manager).offset(x: 2, y: 2)
            }
        }
        .background(
            AddressBarAnchorView { view in
                anchorView = view
            }
            .allowsHitTesting(false)
        )
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            if let manager = extensionManager {
                ExtensionList(
                    extensionManager: manager,
                    needSettings: false,
                    onRequestDismiss: { isPopoverShown = false },
                    triggerAnchorView: anchorView
                )
            }
        }
    }
}

struct HeaderExtensionContainer: View {
    let pinnedExtensions: [Extension]
    let extensionManager: ExtensionManager?
    let browserState: BrowserState?
    @Binding var isPopoverShown: Bool

    @State private var isHovering = false

    var body: some View {
        let visibleProjection = pinnedExtensions.map(\.id)
        HStack(spacing: HeaderExtensionLayout.itemSpacing) {
            HStack(spacing: HeaderExtensionLayout.itemSpacing) {
                ForEach(pinnedExtensions) { ext in
                    if let manager = extensionManager {
                        PinnedExtensionButton(
                            ext: ext,
                            windowId: browserState?.windowId.int64Value ?? 0,
                            manager: manager,
                            orderingEngine: manager.pinnedExtensionOrdering
                        )
                    }
                }
            }
            // AppKit reorder surface over the icon row. SwiftUI's onDrag pair
            // is unusable here: it cannot veto the main window's
            // isMovableByWindowBackground heuristic (the gesture moves the
            // window, not the icon) and never reports the session's end, which
            // leaked an aborted drag's `.dragging` state. The overlay claims
            // left-mouse on reorderable icons only; hover, right-clicks, and
            // accessibility stay on the SwiftUI buttons underneath.
            .overlay(
                HeaderExtensionReorderSurface(
                    pinnedExtensions: pinnedExtensions,
                    extensionManager: extensionManager,
                    windowId: browserState?.windowId.int64Value ?? 0,
                    allowsReordering: browserState?.isIncognito == false
                )
            )
            HeaderExtensionMenuButton(
                extensionManager: extensionManager,
                isPopoverShown: $isPopoverShown
            )
        }
        .frame(height: HeaderTrailingLayout.rowHeight)
        .animation(.easeInOut(duration: 0.12), value: visibleProjection)
        .background(
            Capsule()
                .themedStroke(.border)
                .opacity(isHovering ? 1 : 0)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct PinnedExtensionButton: View {
    let ext: Extension
    let windowId: Int64
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var orderingEngine: PinnedExtensionOrderingEngine

    @State private var anchorView: NSView?

    var body: some View {
        let badge = manager.badges[ext.id]
        // A hidden page action is not rendered at all (Phi spec §1).
        if badge?.visible == false {
            EmptyView()
        } else {
            // Dynamic action icon (setIcon / declarative) overrides the static
            // manifest icon; a grayed action (disabled + no page interaction)
            // comes back desaturated. Re-renders on any badges change via the
            // observed manager.
            let image = manager.iconImage(extensionId: ext.id, staticIcon: ext.icon)

            CircularIconButton(
                image: image,
                accessibilityLabel: ext.name,
                action: {
                    // Reorderable icons get their left-clicks forwarded by
                    // the reorder surface; this SwiftUI action still fires
                    // for accessibility activation and for icons the surface
                    // declines (force-pinned, incognito).
                    executePinnedExtensionAction(
                        ext,
                        manager: manager,
                        windowId: windowId,
                        anchorRect: anchorView.flatMap(ExtensionPopupAnchor.rectOfView)
                    )
                },
                secondaryAction: {
                    let point = anchorView.flatMap(ExtensionPopupAnchor.pointBelowView)
                        ?? ExtensionPopupAnchor.mouseFallback()
                    ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                        withId: ext.id,
                        pointInScreen: point,
                        windowId: windowId
                    )
                }
            )
            // Anchor the badge to the centered icon (not the larger button) so
            // it straddles the icon's bottom-right corner.
            .overlay {
                Color.clear
                    .frame(width: HeaderExtensionLayout.iconSize,
                           height: HeaderExtensionLayout.iconSize)
                    .extensionBadgeOverlay(badge)
            }
            .background(
                AddressBarAnchorView { view in
                    anchorView = view
                }
                .allowsHitTesting(false)
            )
            // Hide the source while its reorder drag is active: the drag
            // image is the only visible copy, and the empty slot the row
            // keeps open marks the landing spot (upstream Chrome hides the
            // source the same way). A force-pinned action can never become
            // the dragged id, so the modifier is unconditional.
            .opacity(orderingEngine.draggedExtensionId == ext.id ? 0 : 1)
        }
    }
}

/// Runs a pinned action's primary activation. A disabled action doesn't run;
/// fall back to the context menu like Chrome (ExecuteUserAction). Shared by
/// the SwiftUI button (accessibility, non-reorderable icons) and the AppKit
/// reorder surface's forwarded clicks. Reads live badge state — callers may
/// invoke this from closures that outlive their render.
@MainActor
private func executePinnedExtensionAction(
    _ ext: Extension,
    manager: ExtensionManager,
    windowId: Int64,
    anchorRect: NSRect?
) {
    if manager.badges[ext.id]?.enabled == false {
        let point = anchorRect.map(ExtensionPopupAnchor.legacyAnchorPoint(for:))
            ?? ExtensionPopupAnchor.mouseFallback()
        ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
            withId: ext.id,
            pointInScreen: point,
            windowId: windowId
        )
        return
    }
    ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
        withId: ext.id,
        anchorRect: anchorRect,
        windowId: windowId
    )
}

/// The drag image content: the action's current dynamic icon with its badge,
/// matching the in-row appearance minus hover chrome.
private struct PinnedExtensionDragPreview: View {
    let image: NSImage
    let badge: ExtensionManager.BadgeState?

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: HeaderExtensionLayout.iconSize,
                   height: HeaderExtensionLayout.iconSize)
            .extensionBadgeOverlay(badge)
            .frame(width: HeaderExtensionLayout.buttonSize,
                   height: HeaderExtensionLayout.buttonSize)
    }
}

private struct HeaderExtensionReorderSurface: NSViewRepresentable {
    let pinnedExtensions: [Extension]
    let extensionManager: ExtensionManager?
    let windowId: Int64
    let allowsReordering: Bool

    func makeNSView(context: Context) -> HeaderExtensionReorderView {
        HeaderExtensionReorderView()
    }

    func updateNSView(_ nsView: HeaderExtensionReorderView, context: Context) {
        nsView.pinnedExtensions = pinnedExtensions
        nsView.extensionManager = extensionManager
        nsView.windowId = windowId
        nsView.allowsReordering = allowsReordering
    }
}

/// AppKit drag surface for the content header (Pinned Extension Surface:
/// content header). Overlays the pinned icon row and owns click-vs-drag for
/// reorderable icons, the dragging session, and the drop destination — the
/// same division of labor as DraggableExtensionButton +
/// ExtensionReorderStackView in the sidebar address bar. The icon row is
/// SwiftUI, so slots are derived from HeaderExtensionLayout's fixed grid
/// instead of live subview frames.
final class HeaderExtensionReorderView: NSView {
    var pinnedExtensions: [Extension] = []
    weak var extensionManager: ExtensionManager?
    var windowId: Int64 = 0
    var allowsReordering = false

    private var mouseDownPoint: CGPoint?
    private var pressedSlotIndex: Int?
    private var hasCrossedHysteresis = false
    private let dragThreshold: CGFloat = 5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.phiPinnedExtensionReorder])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Slot geometry (buttonSize-wide columns on an itemSpacing grid)

    private static let slotStride =
        HeaderExtensionLayout.buttonSize + HeaderExtensionLayout.itemSpacing

    /// The icon column containing x, or nil for the spacing gaps and the
    /// area past the last icon — there the row behaves as before this
    /// feature existed.
    static func slotIndex(atX x: CGFloat, slotCount: Int) -> Int? {
        guard x >= 0 else { return nil }
        let index = Int(x / slotStride)
        guard index < slotCount,
              x - CGFloat(index) * slotStride <= HeaderExtensionLayout.buttonSize else {
            return nil
        }
        return index
    }

    /// Maps a pointer x to the Anchored Reorder intent: the slot whose
    /// column contains the pointer (clamped to the ends) is the target, and
    /// the pointer's side of its midpoint picks the placement — the sidebar
    /// address bar's rule on the header's fixed grid.
    static func reorderAnchor(
        atX x: CGFloat,
        orderedIds: [String]
    ) -> (targetId: String, placement: PinnedExtensionAnchorPlacement)? {
        guard !orderedIds.isEmpty else { return nil }
        let index = min(max(Int(x / slotStride), 0), orderedIds.count - 1)
        let midpoint = CGFloat(index) * slotStride + HeaderExtensionLayout.buttonSize / 2
        return (orderedIds[index], x < midpoint ? .before : .after)
    }

    private func slotButtonRect(at index: Int) -> NSRect {
        NSRect(
            x: CGFloat(index) * Self.slotStride,
            y: (bounds.height - HeaderExtensionLayout.buttonSize) / 2,
            width: HeaderExtensionLayout.buttonSize,
            height: HeaderExtensionLayout.buttonSize
        )
    }

    // MARK: - Click-vs-drag ownership

    /// The main window sets isMovableByWindowBackground; its drag heuristic
    /// honors these two overrides (TabItemView precedent). Without them a
    /// drag on the icon moves the window instead of reordering.
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// Claim left-mouse events over reorderable icons only. Everything else
    /// — hover, right-clicks, force-pinned icons, incognito windows, the
    /// spacing gaps — falls through to the SwiftUI buttons underneath.
    /// Drop-destination discovery does not consult hitTest, so returning
    /// nil never blocks an in-flight reorder drop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            let x = convert(point, from: superview).x
            guard allowsReordering,
                  let index = Self.slotIndex(atX: x, slotCount: pinnedExtensions.count),
                  !pinnedExtensions[index].isForcePinned else {
                return nil
            }
            return self
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        mouseDownPoint = local
        pressedSlotIndex = Self.slotIndex(atX: local.x, slotCount: pinnedExtensions.count)
        hasCrossedHysteresis = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint, !hasCrossedHysteresis else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard abs(currentPoint.x - startPoint.x) > dragThreshold
                || abs(currentPoint.y - startPoint.y) > dragThreshold else { return }
        // Crossing hysteresis consumes the gesture whether or not a session
        // starts (DraggableExtensionButton rule): a rejected reorder attempt
        // must not fall back to a click.
        hasCrossedHysteresis = true
        if let index = pressedSlotIndex, pinnedExtensions.indices.contains(index) {
            beginReorderDrag(for: pinnedExtensions[index], at: index, with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !hasCrossedHysteresis,
           let index = pressedSlotIndex,
           pinnedExtensions.indices.contains(index),
           slotButtonRect(at: index).contains(convert(event.locationInWindow, from: nil)),
           let manager = extensionManager {
            executePinnedExtensionAction(
                pinnedExtensions[index],
                manager: manager,
                windowId: windowId,
                anchorRect: ExtensionPopupAnchor.rectOfRect(
                    slotButtonRect(at: index), in: self)
            )
        }
        mouseDownPoint = nil
        pressedSlotIndex = nil
        hasCrossedHysteresis = false
    }

    private func beginReorderDrag(for ext: Extension, at index: Int, with event: NSEvent) {
        guard let manager = extensionManager,
              manager.beginPinnedExtensionReorder(
                  extensionId: ext.id,
                  visibleProjection: pinnedExtensions.map(\.id),
                  surface: .contentHeader
              ) else {
            return
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(ext.id, forType: .phiPinnedExtensionReorder)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            slotButtonRect(at: index),
            contents: dragImage(for: ext, manager: manager)
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// Renders the drag image offscreen so it carries the current dynamic
    /// icon and badge without capturing hover chrome from the live row.
    private func dragImage(for ext: Extension, manager: ExtensionManager) -> NSImage {
        let icon = manager.iconImage(extensionId: ext.id, staticIcon: ext.icon)
        let hosting = NSHostingView(rootView: PinnedExtensionDragPreview(
            image: icon, badge: manager.badges[ext.id]))
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: HeaderExtensionLayout.buttonSize,
            height: HeaderExtensionLayout.buttonSize)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return icon
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: - Drop destination (mirrors ExtensionReorderStackView)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        reorderOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        reorderOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        extensionManager?.leavePinnedExtensionReorder(surface: .contentHeader)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let manager = extensionManager,
              updatePreview(atX: convert(sender.draggingLocation, from: nil).x),
              manager.commitPinnedExtensionReorder(surface: .contentHeader) else {
            extensionManager?.cancelPinnedExtensionReorder(surface: .contentHeader)
            return false
        }
        return true
    }

    private func reorderOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        updatePreview(atX: convert(sender.draggingLocation, from: nil).x) ? .move : []
    }

    private func updatePreview(atX x: CGFloat) -> Bool {
        guard let manager = extensionManager,
              let anchor = Self.reorderAnchor(atX: x, orderedIds: pinnedExtensions.map(\.id)) else {
            return false
        }
        return manager.updatePinnedExtensionReorder(
            targetExtensionId: anchor.targetId,
            placement: anchor.placement,
            surface: .contentHeader
        )
    }
}

extension HeaderExtensionReorderView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Surface-Local Reorder: the payload never leaves the application.
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // The session-end signal SwiftUI's onDrag never provided. A
        // successful drop already advanced the engine to Pending Reorder
        // Confirmation, which makes this cancel a no-op; Escape, a drop
        // outside the row, and a rejected drop abandon the drag here instead
        // of leaking `.dragging` state and its hidden source icon.
        extensionManager?.cancelPinnedExtensionReorder(surface: .contentHeader)
    }
}
