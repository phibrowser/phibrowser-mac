// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// The sidebar surface a vertical Space switch animates on. Two surfaces
/// exist per window — the docked sidebar (`SidebarViewController`) and the
/// hover floating panel (`FloatingSidebarViewController`) — and
/// `SpaceWindowSlot` drives whichever one is presenting when the switch
/// fires (see `SpaceWindowSlot.spaceSwitchSurface(of:)`): band snapshots,
/// the push-in slide overlay, and the swipe edge bounce all address the
/// surface, not a concrete controller.
///
/// Deliberately NOT annotated `@MainActor`: the nonisolated `SpaceWindowSlot`
/// drives these members synchronously (always on the main thread in
/// practice), exactly as it called the docked sidebar directly before this
/// protocol existed — an explicit annotation would make those calls hard
/// errors, while the NSViewController-inherited isolation of the conforming
/// controllers keeps the same checking the direct calls had.
protocol SpaceSwitchBandSurface: NSViewController {
    /// The views forming the contiguous per-Space content band — the
    /// pinned-tab strip and the tab list (which also hosts bookmarks).
    /// `SpaceManager` snapshots this region from the entering surface and
    /// slides it in over the leaving surface's matching region during a
    /// vertical Space switch. The header (address bar) above and the bottom
    /// toolbar below are deliberately excluded so they stay put through the
    /// push. Views not currently mounted (incognito never mounts the pinned
    /// band) are skipped by the band-frame union.
    var spaceSwitchBandViews: [NSView] { get }

    /// The stack hosting the band. Snapshots render from it — so the themed
    /// backdrop painted behind it is NOT captured and shows through the
    /// slide — and the edge bounce clips to it.
    var spaceSwitchBandContainer: NSView { get }

    /// Ramps the surface's per-Space tint in lockstep with the push-in
    /// slide. The floating panel has no dedicated tint layer (its themed
    /// background follows the window theme ramp `performSwap` drives) and
    /// no-ops.
    func rampSpaceTint(fromHex: String?, toHex: String?, duration: TimeInterval)

    /// The Spaces strip row's AppKit view — a `SpacesStripHostingView` when
    /// the strip is mounted, nil otherwise (incognito never mounts it). Both
    /// surfaces already expose it for the slot's pointer-vs-row test; the
    /// chip flight below rides the same reference.
    var spacesStripRowView: NSView? { get }
}

extension SpaceSwitchBandSurface {
    /// The band region in this surface's root view coordinate space.
    var spaceSwitchBandFrame: NSRect {
        let rects = spaceSwitchBandViews.compactMap { bandView -> NSRect? in
            guard bandView.superview != nil else { return nil }
            return view.convert(bandView.bounds, from: bandView)
        }
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Content-only snapshot of `spaceSwitchBandFrame`. The themed backdrop
    /// lives behind `spaceSwitchBandContainer`, so it is NOT captured here —
    /// the band image carries a transparent background and the ramping
    /// backdrop shows through during the slide. Renders even while the host
    /// window is off-screen, since AppKit layout/`cacheDisplay` is
    /// independent of window visibility.
    func snapshotSpaceSwitchBand() -> NSImage? {
        view.layoutSubtreeIfNeeded()
        let container = spaceSwitchBandContainer
        let bandInContainer = container.convert(spaceSwitchBandFrame, from: view)
        guard bandInContainer.width > 0, bandInContainer.height > 0,
              let rep = container.bitmapImageRepForCachingDisplay(in: bandInContainer) else {
            return nil
        }
        withStaticNewTabSnapshotIcons {
            container.cacheDisplay(in: bandInContainer, to: rep)
        }
        let image = NSImage(size: bandInContainer.size)
        image.addRepresentation(rep)
        return image
    }

    /// Flies the strip's glass chip from the source pip to the target pip as
    /// an explicit CA layer animation for a spawn/materialize switch — the
    /// one animation kind that keeps playing while the switch's synchronous
    /// window build blocks the main thread. False (zero side effects) when
    /// the strip isn't mounted or can't fly (see
    /// `SpacesStripHostingView.beginSpacesChipFlight`); the SwiftUI chip
    /// then keeps today's behavior.
    func beginSpacesChipFlight(fromSpaceId: String, toSpaceId: String,
                               duration: TimeInterval) -> Bool {
        guard let strip = spacesStripRowView as? SpacesStripHostingView else { return false }
        return strip.beginSpacesChipFlight(fromSpaceId: fromSpaceId,
                                           toSpaceId: toSpaceId,
                                           duration: duration)
    }

    /// Sweeps the chip flight's stand-in and restores the SwiftUI chip.
    /// Idempotent; wired into the switch's shared leaving-side restore so
    /// every resolution — reveal, failure, supersession — sweeps exactly
    /// once.
    func cancelSpacesChipFlight() {
        (spacesStripRowView as? SpacesStripHostingView)?.cancelSpacesChipFlight()
    }

    /// Hides/reveals the live band content while the push-in overlay (which
    /// carries the same content as a transparent snapshot) plays on top.
    /// Without this the static live content shows through the snapshot's
    /// transparent areas and reads as a doubled, non-moving copy. Uses alpha
    /// rather than `isHidden` so the stack layout — and the backdrop painted
    /// behind it — is unaffected.
    func setSwitchBandContentHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        for bandView in spaceSwitchBandViews {
            bandView.alphaValue = alpha
        }
    }

    /// Rubber-band nudge on the per-Space content band, played when a
    /// swipe-to-switch can't proceed because the active Space is already the
    /// first or last one. The band (pinned strip + tab list) shifts a short
    /// distance in the swipe's push direction and springs back — the same
    /// horizontal motion as the push-in swap, minus the Space change — so the
    /// gesture still resolves with feedback the user can feel. `forward`
    /// follows the swap convention: next-Space swipes push the band left,
    /// previous-Space swipes push it right.
    func bounceSpaceSwitchBand(forward: Bool) {
        let offset: CGFloat = forward ? -22 : 22
        let container = spaceSwitchBandContainer

        // Clip the nudge to the surface so the shifted band reveals the
        // background on the trailing edge instead of poking over the web
        // content; restored once the bounce settles.
        container.wantsLayer = true
        let priorMasksToBounds = container.layer?.masksToBounds ?? false
        container.layer?.masksToBounds = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak container] in
            container?.layer?.masksToBounds = priorMasksToBounds
        }
        for bandView in spaceSwitchBandViews {
            bandView.wantsLayer = true
            guard let layer = bandView.layer else { continue }
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.x")
            bounce.values = [0, offset, 0]
            bounce.keyTimes = [0, 0.4, 1]
            bounce.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            bounce.duration = 0.3
            layer.add(bounce, forKey: "spaceSwitchEdgeBounce")
        }
        CATransaction.commit()
    }

    /// Switches this window's active Space by `step`, clamped at the
    /// first/last Space (no wrap-around) so the push-in animation direction
    /// always matches the swipe. At a clamp edge the switch can't proceed, so
    /// a rubber-band end effect plays instead of the swipe being swallowed.
    /// Vertical layouts only.
    ///
    /// Incognito windows are excluded: they expose no Spaces (the strip is
    /// suppressed and the window never joins a slot), and without the guard
    /// the `keySlot` fallback below would switch the Space of a DIFFERENT
    /// (normal) window from a swipe in the incognito sidebar.
    func activateAdjacentSpace(by step: Int, state: BrowserState) {
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue(),
              state.participatesInSpaces else { return }
        let spaces = SpaceManager.shared.spaces
        guard let slot = state.windowController?.slot ?? SpaceManager.shared.keySlot,
              let currentId = slot.activeSpaceId,
              let currentIdx = spaces.firstIndex(where: { $0.spaceId == currentId }) else { return }
        let targetIdx = currentIdx + step
        guard spaces.indices.contains(targetIdx) else {
            // Already at the first/last Space (or only one exists) — there's
            // nowhere to switch, so play the rubber-band end effect instead of
            // silently swallowing the swipe.
            bounceSpaceSwitchBand(forward: step > 0)
            return
        }
        slot.activate(spaceId: spaces[targetIdx].spaceId, userInitiated: true)
    }

    // MARK: - Snapshot helpers

    /// The "+ New Tab" cell renders its icon via SF Symbol effects that don't
    /// survive `cacheDisplay`; swap in static icons for the duration of the
    /// snapshot render.
    private func withStaticNewTabSnapshotIcons(_ body: () -> Void) {
        let cells = newTabButtonCells(in: spaceSwitchBandContainer)
        guard !cells.isEmpty else {
            body()
            return
        }

        func apply(at index: Int) {
            guard index < cells.count else {
                body()
                return
            }
            cells[index].withStaticSnapshotIcon {
                apply(at: index + 1)
            }
        }

        apply(at: 0)
    }

    private func newTabButtonCells(in view: NSView) -> [NewTabButtonCellView] {
        var cells: [NewTabButtonCellView] = []
        if let cell = view as? NewTabButtonCellView {
            cells.append(cell)
        }
        for subview in view.subviews {
            cells.append(contentsOf: newTabButtonCells(in: subview))
        }
        return cells
    }
}
