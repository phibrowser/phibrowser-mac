// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State machine for the trackpad swipe-to-switch-Space gesture, shared by
/// the sidebar (vertical layouts) and the tab strip bar (traditional
/// layout). The gesture's axis is latched on the first non-zero delta and
/// holds for the rest of the gesture (including momentum), so a swipe that
/// drifts diagonally doesn't alternate between scrolling and switching.
/// Horizontal-dominant gestures are consumed entirely; callers forward
/// `.passthrough` events to `super.scrollWheel`.
final class SpaceSwipeTracker {
    enum Outcome {
        /// Legacy wheel event or vertical-dominant gesture — scroll as usual.
        case passthrough
        /// Part of a horizontal gesture; swallow without acting.
        case consumed
        /// Horizontal travel crossed the threshold — fired once per gesture.
        /// The deltas follow `scrollingDeltaX` as-is, so the system
        /// scroll-direction setting applies: content-left means the next
        /// Space (+1), content-right the previous (-1).
        case trigger(step: Int)
    }

    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var accumulatedX: CGFloat = 0
    private var triggered = false
    private static let threshold: CGFloat = 50

    func handle(_ event: NSEvent) -> Outcome {
        // Legacy wheel events carry no gesture phases; never treat them as
        // swipes.
        guard event.phase != [] || event.momentumPhase != [] else { return .passthrough }

        if event.phase == .mayBegin || event.phase == .began {
            axis = .undecided
            accumulatedX = 0
            triggered = false
        }

        if axis == .undecided {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > dy {
                axis = .horizontal
            } else if dy > dx {
                axis = .vertical
            }
        }

        guard axis == .horizontal else { return .passthrough }

        accumulatedX += event.scrollingDeltaX
        if !triggered, abs(accumulatedX) >= Self.threshold {
            triggered = true
            return .trigger(step: accumulatedX < 0 ? 1 : -1)
        }
        return .consumed
    }
}

/// Compact active-Space header that sits between the pinned-tab strip and
/// the regular tab list. Shows the active Space's icon + name on the left
/// and an ellipsis affordance on the right that opens a popover listing
/// every Space (with its bound profile) plus a "+" row to create a new one.
///
/// Per-Space actions (rename / icon / theme / URL rules / delete) live on
/// each popover row's context menu — the picker is also the place to edit
/// existing Spaces, so the user never has to leave it once it's open.
struct SpacesStripView: View {
    @ObservedObject var manager: SpaceManager
    /// Per-window slot driving the active-Space highlight and the destination
    /// of activations. Each window's sidebar gets its own slot, so clicks here
    /// only affect this window.
    @ObservedObject var slot: SpaceWindowSlot
    /// Row height. The sidebar mounts a slimmer row than the horizontal
    /// toolbar; this also sizes the scrolling-label clip window.
    var rowHeight: CGFloat = SpacesStripView.height
    /// When false (horizontal tab strip), the switch is a compact icon+name
    /// chip with no trailing ellipsis — tapping the chip opens the picker.
    /// When true (sidebar), the label sits left with a trailing ellipsis
    /// affordance and a spacer between them.
    var showsEllipsisAffordance: Bool = true
    /// Resolves the window controller that hosts this strip, evaluated lazily so
    /// it stays correct even if the controller finishes wiring up after the strip
    /// is built. `iconPickerRequestToken` is slot-wide, so every Space-window in a
    /// slot observes the same bump; this lets `openActiveIconPicker` honor the
    /// request only in the window currently on screen. Nil (previews) means the
    /// strip always treats itself as the owner. See `openActiveIconPicker`.
    var resolveOwnerController: () -> MainBrowserWindowController? = { nil }
    @ObservedObject private var profileManager: ProfileManager = .shared
    @ObservedObject private var agentSpaceManager: AgentSpaceManager = .shared
    @Environment(\.phiAppearance) private var windowAppearance: Appearance

    @State private var isPickerOpen: Bool = false
    @State private var isIconPickerOpen: Bool = false
    @State private var isAddButtonHovered: Bool = false
    @State private var isMoreButtonHovered: Bool = false

    /// Drag-reorder state for the sidebar icon strip. `stripOrderedIds` is the
    /// live arrangement shown while a pip is dragged across its siblings, and
    /// `stripDraggingId` marks the pip under the cursor. Mirrors the popover's
    /// picker (SpacePickerPopup) so the commit path through `manager.reorder`
    /// is identical.
    @State private var stripDraggingId: String?
    @State private var stripOrderedIds: [String] = []

    /// Index of the first pip inside the strip's sliding viewport. When the
    /// active Space's pip sits outside the visible window, the row slides the
    /// minimal distance that brings it in (see `ensureActivePipVisible`).
    /// Always read through `clampedStripStart`, so a shrinking Space list or
    /// a widening sidebar can never leave the window hanging past the end.
    @State private var stripStartIndex: Int = 0

    /// The pip currently under the cursor — or the active Space while the
    /// horizontal chip is hovered — driving its hover tooltip (Space name,
    /// bound profile, and keyboard shortcut). Only one pip is hovered at a
    /// time. Set `hoverCardDelay` after the cursor lands (see `hoverBegan`),
    /// so a cursor just passing across the strip doesn't flash cards.
    @State private var hoveredSpaceId: String?

    /// The pip whose hover card is scheduled but not yet shown, plus the work
    /// item that will promote it to `hoveredSpaceId` once `hoverCardDelay`
    /// elapses. Keyed by spaceId because enter/exit order between neighboring
    /// pips is undefined — a pip's exit must only cancel its own pending
    /// schedule, never a sibling's fresh one.
    @State private var pendingHoverSpaceId: String?
    @State private var pendingHoverWork: DispatchWorkItem?

    /// The pip under the cursor, driving its dim hover wash. Kept separate
    /// from `hoveredSpaceId` (the hover-card owner): that one is promoted only
    /// after `hoverCardDelay`, and the card's watchdog / auto-close can drop
    /// it while the cursor is still on the pip — either would make the wash
    /// lag in or flick off mid-hover.
    @State private var highlightedPipId: String?

    /// Pairs the strip-level glass chip with the active pip's frame anchor.
    /// The chip is ONE persistent view that re-targets the new active pip's
    /// anchor on switch, so its frame change animates as a slide — an
    /// insert/remove chip per pip appeared instantly at the target while the
    /// removed one slid over, doubling the highlight.
    @Namespace private var pipGlassNamespace

    /// The pip whose icon/emoji picker is open, presented from its right-click
    /// "Change Icon…" entry. Only one picker is open at a time.
    @State private var iconEditSpaceId: String?

    /// Externally owned tooltip controller for the horizontal chip, injected by
    /// TabStripBarController so the chip's AppKit hosting view can dismiss the
    /// card synchronously before popping the switcher menu — the menu's modal
    /// tracking loop stops the main queue, so a deferred SwiftUI-driven
    /// dismissal would land only after the menu closes. Nil in the sidebar,
    /// which uses the view-owned controller below.
    var chipTooltipController: SpaceHoverTooltipController?

    /// Owns the click-through floating panel that renders a pip's hover card.
    /// A transient `.popover` consumed the next click (its own dismissal), so the
    /// pip's switch never fired; this passthrough panel lets the click fall
    /// straight through to the pip. Mirrors TabStrip's drag-image panel — the
    /// codebase's existing `ignoresMouseEvents` floating-window pattern.
    @StateObject private var ownedTooltipController = SpaceHoverTooltipController()

    /// The controller actually driving this strip's hover card: the injected
    /// chip controller in the horizontal layout, the view-owned one in the
    /// sidebar.
    private var tooltipController: SpaceHoverTooltipController {
        chipTooltipController ?? ownedTooltipController
    }

    /// The Space whose icon + name are currently shown. Lags `slot.activeSpaceId`
    /// by one animated step so the label can scroll the outgoing Space out and
    /// the incoming one in. `scrollEdge` is set just before the animated change
    /// so the motion direction matches the Space order (later Space → scroll up).
    @State private var displayedSpaceId: String?
    @State private var scrollEdge: Edge = .bottom

    /// Single-row height — matches the visual rhythm of pinned-tab rows above.
    static let height: CGFloat = 30
    /// Slimmer height used when the switch sits at the top of the sidebar.
    static let sidebarHeight: CGFloat = 24
    private static let horizontalPadding: CGFloat = 10
    /// Tighter horizontal padding for the lone horizontal-layout chip, so the
    /// single Space icon hugs its glyph instead of floating in a wide chip.
    /// `TabStripBarController.trafficLightInset` is tuned against this value to
    /// keep the icon centered between the traffic lights and the first tab.
    private static let compactChipHorizontalPadding: CGFloat = 2
    private static let iconSize: CGFloat = 14
    private static let iconHitSize: CGFloat = 22
    /// Uniform hit-target width of every item in the single-row strip — pips,
    /// the "…" overflow affordance, and the add button — and the gap between
    /// them. Drives the fit arithmetic in `visiblePipCount`.
    private static let stripItemWidth: CGFloat = 24
    private static let stripSpacing: CGFloat = 4
    /// How long a pip must stay hovered before its card appears, so brushing
    /// the cursor across the strip doesn't flash cards.
    private static let hoverCardDelay: TimeInterval = 0.3

    /// Preset palette used for new-Space creation. Ordered so successive new
    /// Spaces are visually distinct without forcing the user into a color
    /// picker on creation.
    static let colorPalette: [(hex: String, name: String)] = [
        ("#3A6FF8", "Blue"),
        ("#E5484D", "Red"),
        ("#46A758", "Green"),
        ("#F76B15", "Orange"),
        ("#8E4EC6", "Purple"),
        ("#0091FF", "Cyan")
    ]

    var body: some View {
        // Height is set by the caller (SnapKit constraint in the sidebar,
        // SwiftUI frame in the horizontal toolbar) so the picker can adapt
        // to whichever row it's plugged into.
        Group {
            if showsEllipsisAffordance {
                iconStrip
            } else {
                compactChip
            }
        }
        .padding(.horizontal, showsEllipsisAffordance ? Self.horizontalPadding : Self.compactChipHorizontalPadding)
        .contentShape(Rectangle())
        .onChange(of: slot.iconPickerRequestToken) { _ in
            openActiveIconPicker()
        }
        .ignoresSafeArea()
    }

    /// Opens the icon/emoji picker for the active Space anchored below its icon —
    /// the active pip in the sidebar, or the chip's icon in the tab strip — in
    /// response to the tab-area menu's "Change Icon…" request.
    private func openActiveIconPicker() {
        // The token is slot-wide, so every Space-window's strip in this slot
        // observes the same bump. Only the on-screen window should open the
        // picker: a hidden Space-window that also opened it would set picker
        // state (`iconEditSpaceId` / `isIconPickerOpen`) that never clears and
        // resurfaces the popup when the user later switches to that Space.
        // Ignore the request when this strip is positively identified as a
        // window other than the slot's currently visible one.
        if let owner = resolveOwnerController(),
           let visible = slot.visibleController,
           visible !== owner {
            return
        }
        guard let activeId = slot.activeSpaceId else { return }
        if showsEllipsisAffordance {
            iconEditSpaceId = activeId
        } else {
            isPickerOpen = false
            isIconPickerOpen = true
        }
    }

    /// Compact affordance for the horizontal tab strip: just the active Space's
    /// icon. Hovering it shows the same hover card as the sidebar pips (Space
    /// name, bound profile, switch shortcut); left-clicking it drops the
    /// Space-switcher menu (one item per Space, plus "New Space");
    /// right-clicking it shows the tab strip's context menu (the active-Space
    /// controls). Both menus are AppKit NSMenus attached to the chip's hosting
    /// view in TabStripBarController — the switcher on left-click, the context
    /// menu on right-click — so the chip intentionally has no SwiftUI
    /// `.contextMenu` or popover of its own. The hover card rides the injected
    /// `chipTooltipController`, which the hosting view dismisses synchronously
    /// (and click-suppresses) before popping the switcher.
    private var compactChip: some View {
        // The label is kept for VoiceOver only — it doesn't render a badge.
        activeLabel
            .accessibilityLabel(NSLocalizedString("Spaces", comment: "Accessibility label for the Spaces picker affordance"))
            .onHover { hovering in
                guard let activeId = slot.activeSpaceId else { return }
                if hovering {
                    hoverBegan(activeId)
                } else {
                    hoverEnded(activeId)
                }
            }
            .background(chipTooltipAnchor)
            .onAppear { wireTooltipPointerWatchdog() }
            .onChange(of: slot.activeSpaceId) { newId in
                // The chip's card is keyed to the ACTIVE Space, which can
                // change under a resting cursor (⌃-number, menu-bar switch, a
                // swipe over the chip, active-Space delete). The hover state
                // and any presented card still belong to the OLD Space — and
                // nothing else can reach them: the anchor only dismisses its
                // CURRENT spaceId, the hover-exit resolves the NEW active id,
                // and the pointer watchdog needs the cursor to leave the chip.
                // Drop both here. No linger: the card's content is stale the
                // moment the switch lands.
                if let pending = pendingHoverSpaceId, pending != newId {
                    pendingHoverWork?.cancel()
                    pendingHoverWork = nil
                    pendingHoverSpaceId = nil
                }
                if let hovered = hoveredSpaceId, hovered != newId {
                    hoveredSpaceId = nil
                }
                tooltipController.dismissIfOwnerMissing(liveSpaceIds: newId.map { [$0] } ?? [])
            }
    }

    /// Bridges the chip's hover state to its hover card — the active Space's
    /// card, gated like a pip's (click suppression) plus the chip's own
    /// icon-picker popover, which anchors to the same icon and would fight the
    /// card.
    @ViewBuilder
    private var chipTooltipAnchor: some View {
        if let space = spaceModel(slot.activeSpaceId) {
            SpaceTooltipAnchor(
                isPresented: hoveredSpaceId == space.spaceId && !isIconPickerOpen
                    && slot.hoverCardSuppressedSpaceId != space.spaceId,
                spaceId: space.spaceId,
                card: AnyView(hoverCard(for: space)),
                controller: tooltipController
            )
        }
    }

    /// The active Space's icon, shown in the horizontal tab strip.
    @ViewBuilder
    private var activeLabel: some View {
        scrollingLabel
        .contentShape(Rectangle())
    }

    /// The active Space's icon, scrolling vertically when the active Space
    /// changes: the outgoing Space's icon slides off one edge while the incoming
    /// one slides in from the other (later Space → scroll up, earlier → scroll
    /// down), clipped to the row height so it reads as a ticker.
    private var scrollingLabel: some View {
        // The clip + fixed frame live on the STABLE container (the ZStack), not
        // on the transitioning label — otherwise the clip travels out with the
        // outgoing icon and the old icon lingers above/below the row.
        ZStack(alignment: .leading) {
            label(for: spaceModel(displayedSpaceId))
                .id(displayedSpaceId ?? "none")
                .transition(.asymmetric(
                    insertion: .move(edge: scrollEdge).combined(with: .opacity),
                    removal: .move(edge: scrollEdge == .bottom ? .top : .bottom).combined(with: .opacity)
                ))
        }
        .frame(height: rowHeight, alignment: .leading)
        .clipped()
        .onAppear {
            if displayedSpaceId == nil { displayedSpaceId = slot.activeSpaceId }
        }
        .onChange(of: slot.activeSpaceId) { newId in
            let oldIndex = manager.spaces.firstIndex { $0.spaceId == displayedSpaceId }
            let newIndex = manager.spaces.firstIndex { $0.spaceId == newId }
            scrollEdge = (newIndex ?? 0) >= (oldIndex ?? 0) ? .bottom : .top
            // Match the band push-in exactly (same curve + duration) so the
            // icon scroll and the slide move together.
            withAnimation(.easeInOut(duration: PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration())) {
                displayedSpaceId = newId
            }
        }
    }

    private func spaceModel(_ id: String?) -> SpaceModel? {
        guard let id else { return nil }
        return manager.spaces.first { $0.spaceId == id }
    }

    private func label(for space: SpaceModel?) -> some View {
        activeIcon(for: space)
    }

    /// The active Space's icon. Clicking the chip opens the Space-switcher menu
    /// (popped by the hosting view), not the icon picker — but this view still
    /// hosts the icon-picker popover that the menu's / tab-area "Change Icon…"
    /// entry anchors to.
    private func activeIcon(for space: SpaceModel?) -> some View {
        SpaceIconView(
            storedValue: space?.iconName,
            size: Self.iconSize,
            symbolWeight: .semibold,
            tint: space.map(iconColor(for:)) ?? Color.secondary
        )
        .frame(width: Self.iconHitSize, height: Self.iconHitSize)
        .contentShape(Rectangle())
        .popover(isPresented: $isIconPickerOpen, arrowEdge: .bottom) {
            iconPicker(for: space)
        }
    }

    @ViewBuilder
    private func iconPicker(for space: SpaceModel?) -> some View {
        if let space {
            IconPicker(
                selected: IconPickerSelection.fromStorageValue(space.iconName),
                showsGroups: true,
                onSelect: { selection in
                    manager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue)
                    isIconPickerOpen = false
                }
            )
        }
    }

    /// Sidebar chooser: one tappable icon per Space (the active one carries its
    /// theme tint, the rest read muted) followed by a trailing "+" that creates
    /// a new Space. A large number of Spaces can overflow the row; the
    /// common handful fit within the sidebar width.
    private var iconStrip: some View {
        // Single row that never wraps: a clipped viewport slides along the
        // full pip row to keep the active pip in view. The trailing slot
        // (pinned right via a Spacer) holds the add button — or, once any
        // pips are hidden, a "…" affordance in its place that opens the full
        // switcher menu.
        GeometryReader { geo in
            let visibleCount = visiblePipCount(availableWidth: geo.size.width)
            let hasOverflow = visibleCount < stripOrderedSpaces.count
            HStack(spacing: Self.stripSpacing) {
                pipsViewport(visibleCount: visibleCount)
                Spacer(minLength: 4)
                if hasOverflow {
                    moreButton
                } else {
                    addButton
                }
            }
            .frame(width: geo.size.width, height: rowHeight, alignment: .leading)
            // The whole row is the add button's hover region, so the "+" is
            // already visible by the time the cursor could reach its
            // far-right slot.
            .contentShape(Rectangle())
            .onHover { stripRowHoverChanged($0) }
            // Slide the glass chip (and cross-fade the pips' dim/brighten
            // swap) to the new active pip on every switch source — click,
            // ⌃-number, menu, swipe. Match the band push-in exactly (same
            // curve + duration) so the chip lands with the slide. The
            // viewport shift rides its own `withAnimation` with the same
            // curve (see `ensureActivePipVisible`), so both slides move
            // together.
            .animation(
                .easeInOut(duration: PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration()),
                value: slot.activeSpaceId
            )
            .onAppear {
                ensureActivePipVisible(visibleCount: visibleCount, animated: false)
            }
            .onChange(of: slot.activeSpaceId) { _ in
                ensureActivePipVisible(visibleCount: visibleCount, animated: true)
            }
            .onChange(of: geo.size.width) { newWidth in
                ensureActivePipVisible(visibleCount: visiblePipCount(availableWidth: newWidth), animated: false)
            }
            .onChange(of: stripOrderedSpaces.map(\.spaceId)) { _ in
                // A delete/reorder can push the active pip out of the window
                // (e.g. removing a pip ahead of it). Re-anchor — but never
                // mid-drag, where the live rearrangement is transient.
                guard stripDraggingId == nil else { return }
                ensureActivePipVisible(visibleCount: visibleCount, animated: false)
            }
        }
        .frame(height: rowHeight)
        // Reset a drag that ends off every pip (Spacer / add button / "…" /
        // padding) so the lifted pip doesn't stay dimmed and `stripOrderedIds`
        // re-sync doesn't stay frozen until the next drag. See the delegate doc.
        .onDrop(of: [.text], delegate: SpaceListResetDropDelegate(
            draggingSpaceId: $stripDraggingId,
            orderedIds: $stripOrderedIds,
            commit: { manager.reorder(spaceIds: $0) }
        ))
        .onAppear {
            stripOrderedIds = manager.spaces.map(\.spaceId)
            wireTooltipPointerWatchdog()
        }
        .onChange(of: manager.spaces.map(\.spaceId)) { ids in
            // A deleted Space's pip leaves the ForEach with no mouse-exit, so
            // its `.onHover(false)` never fires and `hoveredSpaceId` /
            // `iconEditSpaceId` stay pinned to a Space that no longer exists.
            // Prune that stale state, and — because `dismiss(spaceId:)` is a
            // no-op unless the caller already knows the exact owner id — have
            // the controller authoritatively drop any card whose owner Space is
            // gone (covers the active-Space delete, whose strip rides the
            // leaving window's header through the push-in). This runs ahead of
            // the drag guard so it self-heals regardless of drag state and never
            // depends on SpaceTooltipAnchor.dismantleNSView firing.
            if let hovered = hoveredSpaceId, !ids.contains(hovered) { hoveredSpaceId = nil }
            if let highlighted = highlightedPipId, !ids.contains(highlighted) { highlightedPipId = nil }
            if let pending = pendingHoverSpaceId, !ids.contains(pending) {
                pendingHoverWork?.cancel()
                pendingHoverWork = nil
                pendingHoverSpaceId = nil
            }
            if let editing = iconEditSpaceId, !ids.contains(editing) { iconEditSpaceId = nil }
            tooltipController.dismissIfOwnerMissing(liveSpaceIds: ids)
            // Leave an in-flight drag's local rearrangement alone; the drop's
            // commit writes through and re-syncs on the next pass.
            guard stripDraggingId == nil else { return }
            stripOrderedIds = ids
        }
    }

    /// Clipped sliding window onto the FULL pip row. Every pip stays in the
    /// tree — the ones outside the window sit beyond the clip with hit
    /// testing off — so both the window shift and the glass chip are plain
    /// frame animations, and the chip can slide to a pip that is itself
    /// still sliding into view.
    @ViewBuilder
    private func pipsViewport(visibleCount: Int) -> some View {
        let start = clampedStripStart(visibleCount: visibleCount)
        let step = Self.stripItemWidth + Self.stripSpacing
        // When pips are hidden past an edge, the window widens by half an
        // icon there so the neighbor peeks through the clip — the cue that
        // the row continues. The peeked halves stay non-interactive: their
        // hit region would extend past the clip into the padding / Spacer.
        let peek = Self.stripItemWidth / 2 + Self.stripSpacing
        let leadingPeek: CGFloat = start > 0 ? peek : 0
        let trailingPeek: CGFloat = start + visibleCount < stripOrderedSpaces.count ? peek : 0
        HStack(spacing: Self.stripSpacing) {
            ForEach(Array(stripOrderedSpaces.enumerated()), id: \.element.spaceId) { index, space in
                spacePip(for: space)
                    .overlay(alignment: .topTrailing) {
                        agentBadge(for: space.spaceId)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        agentNumberBadge(for: space.spaceId)
                    }
                    .opacity(stripDraggingId == space.spaceId ? 0.5 : 1)
                    // `.clipped()` below is visual only — pips beyond the
                    // window would still swallow clicks/hovers aimed at the
                    // Spacer and the trailing button without this.
                    .allowsHitTesting(index >= start && index < start + visibleCount)
                    .onDrag {
                        stripDraggingId = space.spaceId
                        return NSItemProvider(object: space.spaceId as NSString)
                    }
                    .onDrop(of: [.text], delegate: SpaceRowDropDelegate(
                        targetSpaceId: space.spaceId,
                        draggingSpaceId: $stripDraggingId,
                        orderedIds: $stripOrderedIds,
                        commit: { manager.reorder(spaceIds: $0) }
                    ))
            }
        }
        // The active pip's liquid-glass chip — the selected-tab-row treatment
        // (translucent white fill + soft drop shadow). One persistent view
        // behind the row that adopts the active pip's published frame, so a
        // switch animates it as a slide. It rides inside the viewport so it
        // shifts and clips with the row.
        .background {
            if let activeId = slot.activeSpaceId,
               stripOrderedSpaces.contains(where: { $0.spaceId == activeId }) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.sidebarTabSelected)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
                    .matchedGeometryEffect(id: activeId, in: pipGlassNamespace, isSource: false)
                    .allowsHitTesting(false)
            }
        }
        .offset(x: -CGFloat(start) * step + leadingPeek)
        .frame(width: pipRowWidth(visibleCount) + leadingPeek + trailingPeek, alignment: .leading)
        .clipped()
    }

    /// Width of `count` uniform strip items plus the gaps between them.
    private func pipRowWidth(_ count: Int) -> CGFloat {
        count <= 0 ? 0 : CGFloat(count) * Self.stripItemWidth + CGFloat(count - 1) * Self.stripSpacing
    }

    /// `stripStartIndex` clamped so the window never runs past the end of the
    /// pip list (after a delete, or a sidebar resize that fits more pips).
    private func clampedStripStart(visibleCount: Int) -> Int {
        min(stripStartIndex, max(0, stripOrderedSpaces.count - visibleCount))
    }

    /// Slides the viewport the minimal distance that brings the active pip
    /// fully into the window — no-op while it is already visible. Animated
    /// for user switches (matching the glass chip's slide); instant for
    /// layout events (first appearance, sidebar resize, list changes).
    private func ensureActivePipVisible(visibleCount: Int, animated: Bool) {
        guard visibleCount > 0,
              let activeId = slot.activeSpaceId,
              let index = stripOrderedSpaces.firstIndex(where: { $0.spaceId == activeId }) else { return }
        var start = clampedStripStart(visibleCount: visibleCount)
        if index < start {
            start = index
        } else if index >= start + visibleCount {
            start = index - visibleCount + 1
        }
        guard start != stripStartIndex else { return }
        if animated {
            withAnimation(.easeInOut(duration: PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration())) {
                stripStartIndex = start
            }
        } else {
            stripStartIndex = start
        }
    }

    /// How many whole pips fit inside the sliding window, reserving the
    /// trailing slot for the add button — or the "…" affordance that replaces
    /// it when not every Space fits — plus, when overflowing, room for the
    /// half-pip peeks at the window's edges (see `pipsViewport`). All strip
    /// items share a uniform width, so the count is pure arithmetic.
    private func visiblePipCount(availableWidth: CGFloat) -> Int {
        let total = stripOrderedSpaces.count
        guard total > 0 else { return 0 }
        let item = Self.stripItemWidth
        let spacing = Self.stripSpacing
        func width(_ items: Int) -> CGFloat {
            items <= 0 ? 0 : CGFloat(items) * item + CGFloat(items - 1) * spacing
        }
        // Room left of the trailing slot (which keeps a small gap before it).
        let budget = availableWidth - item - spacing
        // Everything fits, with the "+" trailing?
        if width(total) <= budget { return total }
        // Overflowing: the "…" takes the trailing slot, and BOTH edge peeks
        // are reserved regardless of the window's position, so the whole-pip
        // count never reflows while the row slides.
        let peekAllowance = item + 2 * spacing
        var count = total - 1
        while count > 1, width(count) + peekAllowance > budget { count -= 1 }
        return count
    }

    /// Pips in drag order: the local `stripOrderedIds` snapshot (rearranged live
    /// while a drag hovers across pips), with any Space the snapshot doesn't know
    /// yet appended in the manager's order. Mirrors SpacePickerPopup.orderedSpaces.
    private var stripOrderedSpaces: [SpaceModel] {
        guard !stripOrderedIds.isEmpty else { return manager.spaces }
        let byId = Dictionary(uniqueKeysWithValues: manager.spaces.map { ($0.spaceId, $0) })
        var result = stripOrderedIds.compactMap { byId[$0] }
        let known = Set(stripOrderedIds)
        result.append(contentsOf: manager.spaces.filter { !known.contains($0.spaceId) })
        return result
    }

    /// A single Space's icon, rendered through `SpaceIconView` so phi-icons,
    /// emoji, and legacy SF Symbols all display correctly. Tapping switches this
    /// window to that Space; the active pip stays at full strength while the rest
    /// dim, so the difference is only brightness — never a different icon style.
    /// Small badge in the agent Space pip's top-trailing corner: a green dot
    /// while the agent is working, a grey dot while it's idle between steps, a
    /// hand while the user holds control, a red mark on error, and a check when a
    /// completed task hasn't been visited yet.
    @ViewBuilder
    private func agentBadge(for spaceId: String) -> some View {
        if let task = agentSpaceManager.tasksBySpaceId[spaceId] {
            // Corner badge for the agent Space's state. Error/completed take
            // precedence; otherwise it reads the three live states: the user
            // holds control (hand), the agent is working (green dot), or the
            // agent is between steps (grey dot).
            let badge: (String, Color)? = {
                if case .failed = task.status { return ("exclamationmark.circle.fill", .red) }
                if task.hasUnseenError { return ("exclamationmark.circle.fill", .red) }
                if case .completed = task.status { return ("checkmark.circle.fill", .green) }
                if task.ownership == .user { return ("hand.raised.fill", .orange) }
                if case .idle = task.status { return ("circle.fill", .gray) }
                return ("circle.fill", .green)
            }()
            if let (symbol, color) = badge {
                Image(systemName: symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(color)
                    .padding(2)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 3, y: -3)
            }
        }
    }

    /// Bottom-trailing ordinal badge (1, 2, 3…) that tells several concurrent
    /// agent Spaces apart. Only agent Spaces carry a task, so only they show it.
    @ViewBuilder
    private func agentNumberBadge(for spaceId: String) -> some View {
        if let task = agentSpaceManager.tasksBySpaceId[spaceId] {
            Text(verbatim: "\(task.number)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 9, minHeight: 9)
                .padding(2)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                .offset(x: 3, y: 3)
        }
    }

    private func spacePip(for space: SpaceModel) -> some View {
        // The highlight follows `activeSpaceId` (matching the Spaces menu).
        // `activate` flips it to the target up front — before the vertical
        // push-in animation starts — so the active pip moves to the new Space
        // immediately on switch, while the leaving Space's content slides out
        // beneath it (the strip lives in the leaving window's header, which
        // stays on screen for the animation).
        let isActive = space.spaceId == slot.activeSpaceId
        return Button {
            // While the Create-a-Space overlay is open the strip stays visible
            // for reference only: a click must NOT switch Spaces (that swaps
            // away the very window hosting the form). Hover still shows the
            // pip's info card — see `isHoverCardPresented`. Guarding the action
            // (rather than `.disabled`) keeps `.onHover` live so the card works.
            guard !slot.isCreatingSpace else { return }
            // A click means "switch", not "hover": drop this pip's hover card
            // and keep it down — across the window swap, in the target Space
            // window's strip too — until the pointer leaves the pip. Without
            // this the target strip's fresh hover re-presents the card right
            // after the swap (a disappear-then-reappear blink).
            slot.suppressHoverCard(spaceId: space.spaceId)
            slot.activate(spaceId: space.spaceId, userInitiated: true)
        } label: {
            SpaceIconView(
                storedValue: space.iconName,
                size: Self.iconSize,
                symbolWeight: .semibold,
                tint: Color.primary
            )
            .opacity(isActive ? 1 : 0.4)
            .frame(width: 24, height: rowHeight)
            // Publishes this pip's frame under its spaceId, for the
            // strip-level glass chip to target (see `iconStrip`).
            .matchedGeometryEffect(id: space.spaceId, in: pipGlassNamespace)
            .background {
                // A hovered inactive pip gets the sidebar's dim hover wash,
                // which stays flat (no shadow). The active pip's liquid-glass
                // chip is NOT drawn here — it's a single strip-level view
                // (see `iconStrip`) so a switch slides it between pips.
                if !isActive, highlightedPipId == space.spaceId {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.sidebarTabHovered)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(space.name)
        .onHover { hovering in
            if hovering {
                highlightedPipId = space.spaceId
                hoverBegan(space.spaceId)
            } else {
                if highlightedPipId == space.spaceId { highlightedPipId = nil }
                hoverEnded(space.spaceId)
            }
        }
        .background(
            SpaceTooltipAnchor(
                isPresented: isHoverCardPresented(for: space),
                spaceId: space.spaceId,
                card: AnyView(hoverCard(for: space)),
                controller: tooltipController
            )
        )
        .popover(isPresented: iconEditBinding(for: space), arrowEdge: .bottom) {
            IconPicker(
                selected: IconPickerSelection.fromStorageValue(space.iconName),
                showsGroups: true,
                onSelect: { selection in
                    manager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue)
                    iconEditSpaceId = nil
                }
            )
        }
    }

    /// A pip's hover card shows while it (and only it) is hovered, and never
    /// during a reorder drag, while its icon picker is open, or while the pip is
    /// click-suppressed (the user just clicked it to switch Spaces) — so the
    /// card doesn't trail the cursor, fight the picker, or blink back after a
    /// switch. It DOES show while the Create-a-Space overlay is open: the strip
    /// stays visible beside the form there and its clicks are disabled, so the
    /// hover card is the only way to read a pip's info. `.onHover` drives
    /// `hoveredSpaceId`.
    private func isHoverCardPresented(for space: SpaceModel) -> Bool {
        hoveredSpaceId == space.spaceId && stripDraggingId == nil && iconEditSpaceId == nil
            && slot.hoverCardSuppressedSpaceId != space.spaceId
    }

    /// Wires the controller's pointer-watchdog callback to this strip's hover
    /// state: when the watchdog tears a card down (the cursor left with no
    /// delivered `.onHover` exit), the hover state must drop too, or the next
    /// SwiftUI pass would immediately re-present the card the cursor already
    /// left. Called from both variants' `onAppear` — the sidebar strip and the
    /// horizontal chip each own their controller instance.
    private func wireTooltipPointerWatchdog() {
        let hovered = $hoveredSpaceId
        tooltipController.onPointerLeftOwner = { id in
            if hovered.wrappedValue == id { hovered.wrappedValue = nil }
        }
    }

    /// Shared hover-enter handling for the sidebar pips and the horizontal
    /// chip (which acts as a pip for the active Space). A pointer genuinely
    /// moving onto a DIFFERENT pip voids any click suppression — it only means
    /// "while the cursor stays on the clicked pip". An enter on the clicked
    /// pip itself lifts a STALE suppression too: past the hand-off window it
    /// can only be the user coming back, and without this a pointer that left
    /// the pip with no delivered exit (moved away mid-animation, or `.onHover`
    /// dropped it) would strand the suppression and swallow this pip's next
    /// hover card.
    private func hoverBegan(_ spaceId: String) {
        if let suppressed = slot.hoverCardSuppressedSpaceId,
           suppressed != spaceId || slot.isHoverCardSuppressionStale {
            slot.hoverCardSuppressedSpaceId = nil
        }
        pendingHoverWork?.cancel()
        if tooltipController.isWarm {
            // A card is already up — or just went down as the cursor hands off
            // between pips — so re-present instantly, matching system
            // tooltips' already-warm behavior.
            pendingHoverSpaceId = nil
            pendingHoverWork = nil
            hoveredSpaceId = spaceId
        } else {
            // Show the card only after the cursor settles on the pip. If the
            // scheduled work fires after `.onHover` dropped its exit (the
            // cursor is long gone), the controller's pointer watchdog tears
            // the stray card down within a tick.
            let work = DispatchWorkItem {
                pendingHoverSpaceId = nil
                pendingHoverWork = nil
                hoveredSpaceId = spaceId
            }
            pendingHoverSpaceId = spaceId
            pendingHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCardDelay, execute: work)
        }
    }

    /// Shared hover-exit handling. Only the visible window's strip may lift
    /// the click suppression: the leaving window's strip also receives a
    /// hover-exit when it orders out at the end of the swap, and clearing
    /// there would re-arm the card the click just dismissed. Same
    /// owner-vs-visible identification as `openActiveIconPicker`; nil owner
    /// (previews) counts as visible.
    private func hoverEnded(_ spaceId: String) {
        if slot.hoverCardSuppressedSpaceId == spaceId {
            let owner = resolveOwnerController()
            if owner == nil || owner === slot.visibleController {
                slot.hoverCardSuppressedSpaceId = nil
            }
        }
        if pendingHoverSpaceId == spaceId {
            pendingHoverWork?.cancel()
            pendingHoverWork = nil
            pendingHoverSpaceId = nil
        }
        if hoveredSpaceId == spaceId {
            hoveredSpaceId = nil
        }
    }

    /// Row-level hover driving the add button's reveal. Kept on the slot — not
    /// view state — so the "+" survives a Space switch: the target window's
    /// strip is a fresh view instance whose local state would start hidden and
    /// blink the button off and back on while the pointer never left the row.
    ///
    /// Exits are graded by how much their verdict can be trusted:
    /// - pointer verifiably still in the row → ignore (the order-out exit of a
    ///   swap's leaving window; the pointer never moved);
    /// - "outside"/no-authority from the VISIBLE window's strip → clear now
    ///   (a genuine move-off; its layout is settled). Nil owner (previews)
    ///   counts as visible;
    /// - "outside" from a leaving window's strip → defer to the slot's pointer
    ///   watchdog. During a spawn hand-off that exit lands while the row rect
    ///   is a mid-surfacing transient (~17.5pt low), and trusting it stranded
    ///   the "+" hidden under a stationary pointer; the watchdog re-checks
    ///   against settled geometry and also covers dropped exits.
    /// The flip animates via the add button's `.animation(_:value:)`.
    private func stripRowHoverChanged(_ hovering: Bool) {
        if hovering {
            guard !slot.isStripRowHovered else { return }
            slot.isStripRowHovered = true
            return
        }
        if slot.stripRowContainsPointer() == true { return }
        let owner = resolveOwnerController()
        guard owner == nil || owner === slot.visibleController else { return }
        guard slot.isStripRowHovered else { return }
        slot.isStripRowHovered = false
    }

    /// Presents the icon/emoji picker anchored to a pip when its right-click
    /// "Change Icon…" entry has targeted that Space.
    private func iconEditBinding(for space: SpaceModel) -> Binding<Bool> {
        Binding(
            get: { iconEditSpaceId == space.spaceId },
            set: { presented in
                if presented {
                    iconEditSpaceId = space.spaceId
                } else if iconEditSpaceId == space.spaceId {
                    iconEditSpaceId = nil
                }
            }
        )
    }

    /// Builds a pip's hover card from its bound profile, theme tint, and switch
    /// shortcut. Rendered in a passthrough floating panel (see
    /// `SpaceHoverTooltipController`) so it can't swallow the click that switches
    /// Spaces. The shortcut is empty for Spaces past the ninth, which have no
    /// ⌃-number binding.
    private func hoverCard(for space: SpaceModel) -> SpaceHoverCard {
        SpaceHoverCard(
            profileName: profileDisplayName(for: space.profileId),
            iconStoredValue: space.iconName,
            spaceName: space.name,
            iconColor: iconColor(for: space),
            shortcutTokens: spaceShortcut(for: space)?.keycapTokens ?? []
        )
    }

    /// The effective (remap-aware) switch shortcut for a Space, resolved from its
    /// position in the manager's order — mirroring how the Spaces menu binds
    /// ⌃1…⌃9. Nil past the ninth Space or if the binding was cleared.
    private func spaceShortcut(for space: SpaceModel) -> ShortcutsKey? {
        guard let index = manager.spaces.firstIndex(where: { $0.spaceId == space.spaceId }),
              let command = CommandWrapper.spaceSelectionCommand(at: index) else { return nil }
        return Shortcuts.key(for: command)
    }

    /// Trailing affordance that opens the create-Space flow, seeding the new
    /// Space with the active Space's profile so it lands in the same context.
    /// Shown only while the pointer is over the strip's row — hidden via
    /// opacity rather than removed, so it keeps the slot `visiblePipCount`
    /// reserves for it and the pips never reflow on hover.
    private var addButton: some View {
        Button {
            CreateSpacePanel.requestCreation(initialProfileId: activeSpace?.profileId)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: Self.stripItemWidth, height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isAddButtonHovered ? Color.sidebarTabHovered : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(slot.isStripRowHovered ? 1 : 0)
        .disabled(!slot.isStripRowHovered)
        .allowsHitTesting(slot.isStripRowHovered)
        .accessibilityHidden(!slot.isStripRowHovered)
        .animation(.easeInOut(duration: 0.15), value: slot.isStripRowHovered)
//        .offset(x: -2)
        .onHover { isAddButtonHovered = $0 }
        .help(NSLocalizedString("New Space", comment: "Tooltip for the add-Space button in the sidebar Spaces strip"))
    }

    /// Overflow affordance shown in the add button's trailing slot when the row
    /// can't fit every Space. Drops the exact switcher menu the horizontal chip
    /// uses — every Space plus a "New Space" row, which also carries creation
    /// while the "+" it replaces is off screen.
    private var moreButton: some View {
        Button {
            isIconPickerOpen = false
            isPickerOpen = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: Self.stripItemWidth, height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isMoreButtonHovered ? Color.sidebarTabHovered : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isMoreButtonHovered = $0 }
        .help(NSLocalizedString("More Spaces", comment: "Tooltip for the overflow button that opens the full Spaces list"))
        .background(SpaceSwitcherMenuAnchor(isPresented: $isPickerOpen) { menu in
            AppController.shared?.populateSpaceSwitcherMenu(menu)
        })
    }

    /// The Space-switcher popover content. The horizontal chip lists every Space
    /// with a "New Space" row; the sidebar's "…" overflow popover passes the
    /// already-shown pip ids to `excludedSpaceIds` and `showsCreate: false`, so it
    /// only surfaces the Spaces that didn't fit and leaves creation to the strip's
    /// own "+" button.
    @ViewBuilder
    private func pickerPopup(excludedSpaceIds: Set<String> = [], showsCreate: Bool = true) -> some View {
        SpacePickerPopup(
            manager: manager,
            slot: slot,
            profileManager: profileManager,
            windowAppearance: windowAppearance,
            onActivate: { spaceId in
                slot.activate(spaceId: spaceId, userInitiated: true)
                isPickerOpen = false
            },
            onRename: { space in
                isPickerOpen = false
                promptRename(for: space)
            },
            onChangeIcon: { manager.changeIcon(spaceId: $0, iconName: $1) },
            onSetTheme: { manager.setTheme(forSpaceId: $0, themeId: $1) },
            currentThemeId: { manager.themeId(forSpaceId: $0) },
            onDelete: { space in
                isPickerOpen = false
                confirmDelete(space)
            },
            onCreate: {
                isPickerOpen = false
                CreateSpacePanel.requestCreation(initialProfileId: activeSpace?.profileId)
            },
            excludedSpaceIds: excludedSpaceIds,
            showsCreate: showsCreate
        )
    }

    private var activeSpace: SpaceModel? {
        if let id = slot.activeSpaceId {
            return manager.spaces.first { $0.spaceId == id }
        }
        return nil
    }

    /// Resolves a Space's bound profile to a user-visible name, falling back to
    /// the raw profileId if ProfileManager hasn't refreshed yet.
    private func profileDisplayName(for profileId: String) -> String {
        profileManager.profile(for: profileId)?.displayName ?? profileId
    }

    /// Each Space's accent comes from its pinned theme (or the global theme
    /// when no override is set), so the active-Space icon previews what the
    /// window currently looks like.
    fileprivate func iconColor(for space: SpaceModel) -> Color {
        let theme: Theme
        if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
           let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
            theme = pinned
        } else {
            theme = ThemeManager.shared.currentTheme
        }
        return Color(nsColor: theme.color(for: .textPrimary, appearance: windowAppearance))
    }

    private func promptRename(for space: SpaceModel) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Space", comment: "Title of the rename-Space dialog")
        alert.informativeText = NSLocalizedString("Enter a new name for this Space.", comment: "Body of the rename-Space dialog")
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = space.name
        textField.placeholderString = space.name
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        manager.renameSpace(spaceId: space.spaceId, to: trimmed)
    }

    private func confirmDelete(_ space: SpaceModel) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = NSLocalizedString(
            "Bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.deleteSpace(spaceId: space.spaceId)
    }
}

/// Popover content shown by the ellipsis button. Lists every Space with its
/// bound profile label, plus a footer row for creating a new one. Each row
/// is clickable to activate and right-clickable to edit / delete.
private struct SpacePickerPopup: View {
    @ObservedObject var manager: SpaceManager
    @ObservedObject var slot: SpaceWindowSlot
    @ObservedObject var profileManager: ProfileManager
    let windowAppearance: Appearance
    let onActivate: (String) -> Void
    let onRename: (SpaceModel) -> Void
    let onChangeIcon: (String, String) -> Void
    let onSetTheme: (String, String?) -> Void
    let currentThemeId: (String) -> String?
    let onDelete: (SpaceModel) -> Void
    let onCreate: () -> Void
    /// Spaces already shown as pips in the strip, hidden from this list so the
    /// overflow popover only surfaces the Spaces that didn't fit. Empty for the
    /// horizontal chip, which lists every Space.
    var excludedSpaceIds: Set<String> = []
    /// Whether to show the trailing "New Space" row. Off for the sidebar overflow
    /// popover, which sits next to the strip's own "+" button.
    var showsCreate: Bool = true

    private static let popoverWidth: CGFloat = 240

    @State private var draggingSpaceId: String?
    @State private var orderedIds: [String] = []
    @State private var isCreateHovering: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedSpaces, id: \.spaceId) { space in
                        SpacePickerRow(
                            space: space,
                            isActive: space.spaceId == slot.activeSpaceId,
                            // Neither the default Space nor an Incognito
                            // Space can be deleted, and an Incognito Space's
                            // name is derived ("Incognito" / "Incognito N";
                            // it ends via Close Incognito Space instead).
                            // Icon and theme remain user-changeable for it.
                            isDeletable: space.spaceId != LocalStore.defaultSpaceId
                                && !SpaceManager.isIncognitoSpaceId(space.spaceId),
                            isRenamable: !SpaceManager.isIncognitoSpaceId(space.spaceId),
                            tint: iconColor(for: space),
                            profileName: profileDisplayName(for: space.profileId),
                            onActivate: { onActivate(space.spaceId) },
                            onRename: { onRename(space) },
                            onChangeIcon: { onChangeIcon(space.spaceId, $0) },
                            onSetTheme: { onSetTheme(space.spaceId, $0) },
                            currentThemeId: { currentThemeId(space.spaceId) },
                            onDelete: { onDelete(space) }
                        )
                        .opacity(draggingSpaceId == space.spaceId ? 0.5 : 1)
                        .onDrag {
                            draggingSpaceId = space.spaceId
                            return NSItemProvider(object: space.spaceId as NSString)
                        }
                        .onDrop(of: [.text], delegate: SpaceRowDropDelegate(
                            targetSpaceId: space.spaceId,
                            draggingSpaceId: $draggingSpaceId,
                            orderedIds: $orderedIds,
                            commit: { manager.reorder(spaceIds: $0) }
                        ))
                    }
                }
                .padding(.vertical, 6)
            }

            if showsCreate {
                Divider()

                Button(action: onCreate) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 16)
                        Text(NSLocalizedString("New Space", comment: "Spaces picker - create a new Space"))
                            .font(.system(size: 13))
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCreateHovering ? Color.primary.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isCreateHovering = $0 }
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(maxHeight: 320)
        // Reset a drag that ends off every row (the create row / list padding)
        // so the lifted row doesn't stay dimmed and `orderedIds` re-sync doesn't
        // stay frozen until the next drag. See the delegate doc.
        .onDrop(of: [.text], delegate: SpaceListResetDropDelegate(
            draggingSpaceId: $draggingSpaceId,
            orderedIds: $orderedIds,
            commit: { manager.reorder(spaceIds: $0) }
        ))
        .onAppear { orderedIds = manager.spaces.map(\.spaceId) }
        .onChange(of: manager.spaces.map(\.spaceId)) { ids in
            // Don't fight an in-flight drag's local rearrangement; the
            // commit on drop writes through and re-syncs on the next pass.
            guard draggingSpaceId == nil else { return }
            orderedIds = ids
        }
    }

    /// Rows in drag order: the local `orderedIds` snapshot (rearranged live
    /// while a drag hovers across rows), with any Space the snapshot doesn't
    /// know yet appended in strip order.
    private var orderedSpaces: [SpaceModel] {
        let ordered: [SpaceModel]
        if orderedIds.isEmpty {
            ordered = manager.spaces
        } else {
            let byId = Dictionary(uniqueKeysWithValues: manager.spaces.map { ($0.spaceId, $0) })
            var result = orderedIds.compactMap { byId[$0] }
            let known = Set(orderedIds)
            result.append(contentsOf: manager.spaces.filter { !known.contains($0.spaceId) })
            ordered = result
        }
        guard !excludedSpaceIds.isEmpty else { return ordered }
        return ordered.filter { !excludedSpaceIds.contains($0.spaceId) }
    }

    private func iconColor(for space: SpaceModel) -> Color {
        let theme: Theme
        if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
           let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
            theme = pinned
        } else {
            theme = ThemeManager.shared.currentTheme
        }
        return Color(nsColor: theme.color(for: .textPrimary, appearance: windowAppearance))
    }

    /// Falls back to the raw profileId so the row still shows *something*
    /// useful if ProfileManager hasn't refreshed yet (e.g. very early after
    /// bridge bring-up).
    private func profileDisplayName(for profileId: String) -> String {
        if let p = ProfileManager.shared.profile(for: profileId) {
            return p.displayName
        }
        return profileId
    }
}

/// Reorders Space rows live while a row drag hovers over siblings and commits
/// the arrangement on drop. Movement happens in the view's local `orderedIds`
/// (not the persisted list), so SwiftData is written once — when the drop lands
/// — rather than on every row crossing. Shared by the sidebar Space picker and
/// the Spaces settings pane.
struct SpaceRowDropDelegate: DropDelegate {
    let targetSpaceId: String
    @Binding var draggingSpaceId: String?
    @Binding var orderedIds: [String]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingSpaceId,
              dragging != targetSpaceId,
              let from = orderedIds.firstIndex(of: dragging),
              let to = orderedIds.firstIndex(of: targetSpaceId) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            orderedIds.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    /// How long to keep the lifted row hidden after a drop, covering the beat
    /// during which the system fades out its floating drag image. Revealing the
    /// row before the snapshot is gone shows the item twice -- the settling
    /// snapshot and the row reappearing beneath it. Tuned by eye: a touch long
    /// is harmless (the open slot just waits a moment longer), too short lets the
    /// double flash back.
    static let dragImageSettle: TimeInterval = 0.2

    func performDrop(info: DropInfo) -> Bool {
        // Persist the new order now. The model republish re-syncs each view's
        // orderedIds to the identical committed order (a no-op) and is gated by
        // its `draggingSpaceId == nil` onChange guard -- which still holds here
        // because the reveal below is deferred, so the in-flight order is kept.
        let dropped = draggingSpaceId
        commit(orderedIds)
        // Defer un-hiding the lifted row until the system's floating drag image
        // has faded. The `.opacity` modifier reveals the row the instant
        // `draggingSpaceId` clears; doing that immediately (as before) dropped
        // the row back into its slot while the snapshot was still settling onto
        // the same spot, so the item briefly appeared twice. Holding it hidden
        // lets the snapshot fade into the open slot first, then the row eases in
        // where it landed, with the same 0.15s curve dropEntered opened the gap
        // with (0 -> 1 in the settings list, 0.5 -> 1 in the strip/picker).
        // Guard on the captured id so a fresh drag begun within the delay keeps
        // its own hidden-source state instead of being cleared from under it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragImageSettle) {
            guard draggingSpaceId == dropped else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                draggingSpaceId = nil
            }
        }
        return true
    }
}

/// Catch-all reset for a Space drag that ends off every row. The per-row
/// `SpaceRowDropDelegate`s own reordering and take precedence within their
/// bounds; this fallback, attached to the enclosing container, catches a drop
/// that lands on the surrounding chrome (the strip's Spacer / add button / "…"
/// affordance / padding, or the picker's create row and list padding). Without
/// it `draggingSpaceId` would never reset there, leaving the lifted row dimmed
/// and freezing the local `orderedIds` re-sync until the next drag. It does no
/// reordering of its own — it just clears the drag and commits the order the row
/// delegates already arranged. (A hard Esc-cancel or a drop fully outside the
/// container still self-heals on the next drag's `onDrag`, which has no SwiftUI
/// cancel hook.) Shared by the sidebar strip, the picker popover, and the
/// Spaces settings list.
struct SpaceListResetDropDelegate: DropDelegate {
    @Binding var draggingSpaceId: String?
    @Binding var orderedIds: [String]
    let commit: ([String]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Match SpaceRowDropDelegate: commit now, then hold the lifted row
        // hidden until the system's floating drag image has faded so a drop that
        // lands off every row -- the dragged row's own open slot, the area below
        // the last row, or surrounding chrome -- doesn't flash the row beside the
        // settling snapshot. Guarded on the captured id for the same reason.
        let dropped = draggingSpaceId
        commit(orderedIds)
        DispatchQueue.main.asyncAfter(deadline: .now() + SpaceRowDropDelegate.dragImageSettle) {
            guard draggingSpaceId == dropped else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                draggingSpaceId = nil
            }
        }
        return true
    }
}

/// Drops the native Space-switcher menu anchored to a SwiftUI button when
/// `isPresented` flips true, then resets it. Lets the sidebar's "…" overflow
/// affordance show the same AppKit menu as the horizontal active-Space chip
/// (built by `AppController.populateSpaceSwitcherMenu`) instead of a SwiftUI
/// popover, so both layouts share one switcher UI.
private struct SpaceSwitcherMenuAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// Fills the menu just before it pops, so each caller chooses what it lists.
    let populate: (NSMenu) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, !context.coordinator.isShowing else { return }
        context.coordinator.isShowing = true
        // Pop on the next runloop so the menu drops after this view update and
        // mutating `isPresented` happens outside it. `isShowing` guards against a
        // second update re-scheduling while the (modal) menu is open.
        DispatchQueue.main.async {
            defer {
                context.coordinator.isShowing = false
                isPresented = false
            }
            let menu = NSMenu()
            populate(menu)
            guard menu.numberOfItems > 0 else { return }
            let bottomLeading = NSPoint(
                x: nsView.bounds.minX,
                y: nsView.isFlipped ? nsView.bounds.maxY : nsView.bounds.minY
            )
            menu.popUp(positioning: nil, at: bottomLeading, in: nsView)
        }
    }

    final class Coordinator {
        var isShowing = false
    }
}

private struct SpacePickerRow: View {
    let space: SpaceModel
    let isActive: Bool
    let isDeletable: Bool
    /// False for Incognito Spaces, whose NAME is derived ("Incognito" /
    /// "Incognito N" — a rename would be a silent store no-op on their
    /// runtime-only ids). Icon and theme stay editable everywhere —
    /// `SpaceManager.changeIcon`/`setTheme` keep their choices outside
    /// SwiftData.
    var isRenamable: Bool = true
    let tint: Color
    let profileName: String
    let onActivate: () -> Void
    let onRename: () -> Void
    let onChangeIcon: (String) -> Void
    let onSetTheme: (String?) -> Void
    let currentThemeId: () -> String?
    let onDelete: () -> Void

    @State private var isHovering: Bool = false
    @State private var showsIconPicker: Bool = false

    /// Drives the Change-Theme picker: nil = Follow Global, else a pinned id.
    private var themeSelection: Binding<String?> {
        Binding(
            get: { currentThemeId() },
            set: { onSetTheme($0) }
        )
    }

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                SpaceIconView(
                    storedValue: space.iconName,
                    size: 13,
                    symbolWeight: .semibold,
                    tint: isActive ? Color.white : tint
                )
                .frame(width: 16)
                Text(space.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                Spacer(minLength: 8)
                Text(profileName)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $showsIconPicker, arrowEdge: .trailing) {
            IconPicker(
                selected: IconPickerSelection.fromStorageValue(space.iconName),
                showsGroups: true,
                onSelect: { selection in
                    showsIconPicker = false
                    onChangeIcon(selection.storageValue)
                }
            )
        }
        .contextMenu {
            if isRenamable {
                Button(NSLocalizedString("Rename\u{2026}", comment: "")) { onRename() }
            }
            Button(NSLocalizedString("Change Icon\u{2026}", comment: "Opens the icon/emoji picker for a Space")) {
                showsIconPicker = true
            }
            Menu(NSLocalizedString("Change Theme", comment: "")) {
                Picker(NSLocalizedString("Change Theme", comment: ""), selection: themeSelection) {
                    Label {
                        Text(NSLocalizedString("Follow Global", comment: "Theme menu: clear per-Space override"))
                    } icon: {
                        Image(nsImage: .themeColorSwatch(for: ThemeManager.shared.currentTheme))
                            .renderingMode(.original)
                    }
                    .tag(String?.none)

                    Divider()

                    ForEach(ThemeManager.shared.orderedThemes, id: \.id) { theme in
                        Label {
                            Text(theme.name)
                        } icon: {
                            Image(nsImage: .themeColorSwatch(for: theme))
                                .renderingMode(.original)
                        }
                        .tag(String?(theme.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if isDeletable {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text(NSLocalizedString("Delete", comment: "Destructive menu item"))
                }
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 6)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }
}

struct SpaceIconView: View {
    let storedValue: String?
    let size: CGFloat
    let symbolWeight: Font.Weight
    let tint: Color

    private var storedIconValue: String {
        guard let storedValue, !storedValue.isEmpty else { return "rectangle.stack" }
        return storedValue
    }

    var body: some View {
        if let selection = IconPickerSelection.fromStorageValue(storedIconValue) {
            switch selection {
            case .phiIcon:
                IconPickerSelectionView(selection: selection, size: size)
            case .emoji(_, let text):
                Text(text)
                    .font(.system(size: emojiFontSize))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: emojiFrameSize.width, height: emojiFrameSize.height)
            }
        } else if let symbol = systemSymbolName(for: storedIconValue) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: symbolWeight))
                .foregroundStyle(tint)
        } else {
            Image(systemName: "rectangle.stack")
                .font(.system(size: size, weight: symbolWeight))
                .foregroundStyle(tint)
        }
    }

    private var emojiFontSize: CGFloat {
        size
    }

    private var emojiFrameSize: CGSize {
        CGSize(width: size + 4, height: size + 4)
    }

    /// A menu-ready icon for a Space's stored icon value, for use as an
    /// `NSMenuItem.image`. SF Symbols — including the empty-icon and legacy
    /// fallback — stay template images that invert with menu selection; phi-icons
    /// and emoji, which `NSImage(systemSymbolName:)` can't resolve, are rasterized
    /// from this view so they show in menus too. Call on the main thread (menu
    /// builds are synchronous on it); `ImageRenderer` is main-actor-bound.
    @MainActor
    static func menuImage(for storedValue: String, size: CGFloat = 16) -> NSImage? {
        let stored = storedValue.isEmpty ? "rectangle.stack" : storedValue
        if let symbolImage = NSImage(systemSymbolName: stored, accessibilityDescription: nil) {
            return symbolImage
        }
        // Match the menu's appearance so phi-icons pick their light/dark asset
        // variant — ImageRenderer defaults to light, which leaves dark-mode menus
        // showing the dark-ink variant on a dark background. Unlike the import
        // label (always dark) this follows the current system appearance.
        let icon = SpaceIconView(
            storedValue: stored,
            size: size,
            symbolWeight: .semibold,
            tint: Color(nsColor: .labelColor)
        )
        .environment(\.colorScheme, appAppearance.isDark ? .dark : .light)
        .frame(width: size + 4, height: size + 4)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// SpaceModel.iconName may be either an IconPicker storage value or the legacy
/// SF Symbol id (e.g. "rectangle.stack"). Legacy symbols are resolved at view
/// time so old rows keep rendering without a data migration.
private func systemSymbolName(for stored: String) -> String? {
    stored.isEmpty ? nil : stored
}

/// A pip's hover card: the Space (icon + name) as a tinted pill on the left, the
/// bound profile name in the middle, and its switch shortcut as keycaps on the
/// right.
/// Self-contained (plain data in) so it can be hosted in a standalone panel by
/// `SpaceHoverTooltipController` instead of a transient `.popover` — the popover
/// swallowed the next click (its own dismissal), so the pip's switch never ran.
struct SpaceHoverCard: View {
    let profileName: String
    let iconStoredValue: String?
    let spaceName: String
    let iconColor: Color
    /// Per-keycap tokens (modifiers then key), or empty for Spaces without a
    /// ⌃-number binding.
    let shortcutTokens: [String]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                SpaceIconView(
                    storedValue: iconStoredValue,
                    size: 11,
                    symbolWeight: .semibold,
                    tint: iconColor
                )
                Text(spaceName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(iconColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(iconColor.opacity(0.15)))

            separatorDot

            Text(profileName)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            if !shortcutTokens.isEmpty {
                separatorDot

                HStack(spacing: 3) {
                    ForEach(Array(shortcutTokens.enumerated()), id: \.offset) { _, token in
                        keycap(token)
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The panel hosting this card is borderless and clear, so the card draws
        // its own popover-like chrome (the popover used to provide it).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    /// A subtle middle-dot divider between the card's sections.
    private var separatorDot: some View {
        Text("\u{00B7}")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.secondary.opacity(0.45))
    }

    /// A single keycap badge (one modifier symbol or the character).
    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}

/// Hosts a pip's hover card in a click-through floating `NSPanel`
/// (`ignoresMouseEvents`) anchored just above the pip. Because it is a separate,
/// non-interactive window there is no transient-popover dismiss monitor to
/// consume the next click, so a click on the pip falls straight through to its
/// Button and switches the Space. Mirrors TabStrip's drag-image panel.
final class SpaceHoverTooltipController: ObservableObject {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    /// The spaceId currently shown, so a stale pip's `dismiss` can't tear down a
    /// card another pip just presented (update order between pips isn't defined).
    private var ownerId: String?

    /// When the card last went down, feeding `isWarm`'s grace window.
    private var lastHiddenAt: Date?
    private static let warmGrace: TimeInterval = 0.3

    /// True while a card is on screen, plus a short grace after it goes down.
    /// The strip skips `hoverCardDelay` while warm, so walking the cursor
    /// pip → pip re-presents each card instantly. The grace covers the hand-off
    /// gap between pips, where render ordering or the pointer watchdog may drop
    /// the old card before the next pip's hover-enter arrives.
    var isWarm: Bool {
        if ownerId != nil { return true }
        guard let lastHiddenAt else { return false }
        return Date().timeIntervalSince(lastHiddenAt) < Self.warmGrace
    }

    /// The owner pip's screen frame, expanded a hair so sub-pixel cursor jitter
    /// at the pip's edge doesn't read as "left". The pointer watchdog tears the
    /// card down once the real cursor leaves this rect.
    private var ownerAnchorRect: CGRect = .zero

    /// Polls the real cursor position (`NSEvent.mouseLocation`) while a card is
    /// up. SwiftUI's `.onHover` silently drops its exit callback when the pointer
    /// leaves the pip fast, crosses onto another window or app, or the strip
    /// relayouts under the cursor — pinning `hoveredSpaceId` and stranding the
    /// card on screen with no way to dismiss it. This watchdog is the
    /// authoritative "pointer left the pip" signal that `.onHover` is not.
    private var pointerWatchdog: Timer?

    /// Absolute safety cap: a card that somehow outlives both `.onHover` and the
    /// pointer watchdog still tears itself down after `autoCloseAfter`. Armed
    /// once per fresh presentation (not reset by same-owner re-renders), so a
    /// stranded card can never linger on screen indefinitely.
    private var autoCloseTimer: Timer?
    private static let autoCloseAfter: TimeInterval = 10

    /// Invoked with the stranded owner id when the watchdog tears a card down
    /// or `present` rejects a pip the cursor is not over, so the strip can
    /// clear its `hoveredSpaceId` — otherwise the next SwiftUI pass (any
    /// `manager` republish re-renders every pip) would immediately re-present
    /// the card the cursor already left.
    var onPointerLeftOwner: ((String) -> Void)?

    /// Pending deferred `orderOut`. Losing an owner hides the panel only after
    /// `hideLinger`, and a `present` in the meantime cancels it — so walking
    /// the cursor pip → pip reads as ONE card sliding along and swapping its
    /// content, never a hide/show blink (whichever order the old pip's dismiss
    /// and the new pip's present land in, and even when the watchdog fires
    /// mid-gap). Must stay below `warmGrace`, so a lingering panel always
    /// belongs to a warm hand-off.
    private var hideWork: DispatchWorkItem?
    private static let hideLinger: TimeInterval = 0.15

    deinit {
        pointerWatchdog?.invalidate()
        autoCloseTimer?.invalidate()
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    /// Shows `card` for `spaceId`, centered above `anchorScreenRect`. Idempotent:
    /// re-presenting the same pip just repositions and refreshes the content.
    /// Rejected when the real cursor is not inside the pip — see the guard.
    func present(spaceId: String, card: AnyView, anchorScreenRect: CGRect, screen: NSScreen?) {
        let panel = ensurePanel()
        let expandedAnchor = anchorScreenRect.insetBy(dx: -2, dy: -2)
        // The strip's show delay is scheduled purely off `.onHover(true)`, and
        // `.onHover` drops its exit when the pointer leaves fast (see
        // `pointerWatchdog`) — so the scheduled work can fire after the cursor
        // is long gone and would pop a ghost card here. Gate every presentation
        // on the real cursor being inside the pip (same authority and inset as
        // the watchdog), and hand the stale owner id back to the strip so its
        // pinned hover state can't re-present on the next render pass; deferred
        // because present() runs inside a SwiftUI view update.
        guard expandedAnchor.contains(NSEvent.mouseLocation) else {
            DispatchQueue.main.async { [weak self] in self?.onPointerLeftOwner?(spaceId) }
            return
        }
        cancelScheduledHide()
        // A genuine owner change re-arms the absolute timeout; a same-owner
        // re-present (any `manager` republish re-runs `updateNSView`) leaves the
        // running deadline alone so it can't be pushed out forever.
        let isNewPresentation = ownerId != spaceId
        ownerId = spaceId
        ownerAnchorRect = expandedAnchor
        guard let hostingView else { return }
        hostingView.rootView = card
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize

        let gap: CGFloat = 6
        var origin = CGPoint(
            x: anchorScreenRect.midX - size.width / 2,
            y: anchorScreenRect.maxY + gap            // screen coords: +y is up → above the pip
        )
        if let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            // Flip below the pip if showing above would clip the screen top.
            if origin.y + size.height > visible.maxY - 4 {
                origin.y = anchorScreenRect.minY - gap - size.height
            }
            origin.y = max(origin.y, visible.minY + 4)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        startPointerWatchdog()
        if isNewPresentation || autoCloseTimer == nil { startAutoCloseTimer() }
    }

    /// Hides the card NOW — no linger, and no warmth left behind (a click-hide
    /// is not a pip hand-off). For the horizontal chip's AppKit hosting view,
    /// which must clear the card synchronously before popping the switcher
    /// menu: the menu's modal tracking loop stops the main queue, so the
    /// deferred linger hide (and any SwiftUI-driven dismissal) would land only
    /// after the menu closes.
    func dismissImmediately() {
        ownerId = nil
        lastHiddenAt = nil
        stopPointerWatchdog()
        stopAutoCloseTimer()
        cancelScheduledHide()
        panel?.orderOut(nil)
    }

    /// Hides the card (after `hideLinger`) iff `spaceId` is the one currently
    /// shown.
    func dismiss(spaceId: String) {
        guard ownerId == spaceId else { return }
        ownerId = nil
        lastHiddenAt = Date()
        stopPointerWatchdog()
        stopAutoCloseTimer()
        scheduleHide()
    }

    /// Tears the card down when the Space it shows is no longer live. The
    /// per-id `dismiss(spaceId:)` only fires for a caller that passes the exact
    /// owner id, so a deleted Space — whose pip leaves the strip with no
    /// mouse-exit and no `dismiss` keyed to its now-missing id — would never be
    /// cleared by it, and `dismantleNSView` is not guaranteed to run in time on
    /// ForEach removal or window teardown. The strip calls this on every
    /// `manager.spaces` change as the authoritative escape hatch. The
    /// `contains` check preserves the per-id guard's intent: a card still owned
    /// by a live Space (e.g. a sibling pip that just re-presented) is untouched.
    func dismissIfOwnerMissing(liveSpaceIds: [String]) {
        guard let ownerId, !liveSpaceIds.contains(ownerId) else { return }
        self.ownerId = nil
        lastHiddenAt = Date()
        stopPointerWatchdog()
        stopAutoCloseTimer()
        // No linger: the card shows a Space that no longer exists, so it must
        // not stay up a moment longer.
        cancelScheduledHide()
        panel?.orderOut(nil)
    }

    private func startPointerWatchdog() {
        guard pointerWatchdog == nil else { return }
        // `.common` mode so it keeps firing through scroll/resize tracking loops.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.dismissIfPointerLeftOwner()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerWatchdog = timer
    }

    private func stopPointerWatchdog() {
        pointerWatchdog?.invalidate()
        pointerWatchdog = nil
    }

    private func startAutoCloseTimer() {
        autoCloseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autoCloseAfter, repeats: false) { [weak self] _ in
            self?.tearDown()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
    }

    private func stopAutoCloseTimer() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    /// Tears the card down the moment the real cursor leaves the owner pip,
    /// independent of whether `.onHover` ever delivered its exit.
    private func dismissIfPointerLeftOwner() {
        guard ownerId != nil else { stopPointerWatchdog(); return }
        guard !ownerAnchorRect.contains(NSEvent.mouseLocation) else { return }
        tearDown()
    }

    /// Hides the card, stops both timers, and tells the strip to drop its hover
    /// state so a later SwiftUI pass can't re-present the card the cursor already
    /// left. Shared by the pointer watchdog and the absolute auto-close timeout.
    private func tearDown() {
        guard let owner = ownerId else { return }
        ownerId = nil
        lastHiddenAt = Date()
        stopPointerWatchdog()
        stopAutoCloseTimer()
        scheduleHide()
        onPointerLeftOwner?(owner)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideWork = nil
            self?.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideLinger, execute: work)
    }

    private func cancelScheduledHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
        return panel
    }
}

/// Invisible SwiftUI ↔ AppKit bridge placed behind a pip. It reports the pip's
/// screen frame to `SpaceHoverTooltipController` and shows/hides the card as the
/// pip's hover state changes — without participating in event handling itself.
private struct SpaceTooltipAnchor: NSViewRepresentable {
    let isPresented: Bool
    let spaceId: String
    let card: AnyView
    let controller: SpaceHoverTooltipController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, spaceId: spaceId) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.spaceId = spaceId
        guard isPresented, let window = nsView.window else {
            controller.dismiss(spaceId: spaceId)
            return
        }
        let rectInWindow = nsView.convert(nsView.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        controller.present(spaceId: spaceId, card: card, anchorScreenRect: screenRect, screen: window.screen)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // The pip left the hierarchy (e.g. overflow recompute) while its card was
        // up; tear the card down so it can't linger.
        coordinator.controller.dismiss(spaceId: coordinator.spaceId)
    }

    final class Coordinator {
        var controller: SpaceHoverTooltipController
        var spaceId: String
        init(controller: SpaceHoverTooltipController, spaceId: String) {
            self.controller = controller
            self.spaceId = spaceId
        }
    }
}
