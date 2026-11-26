// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import AppKit
import CoreImage

struct PinnedExtensionOrderItem: Equatable {
    let id: String
    let isForcePinned: Bool
}

enum PinnedExtensionAnchorPlacement: Equatable {
    case before
    case after
}

enum PinnedExtensionSurface: Equatable {
    case contentHeader
    case sidebarAddressBar
    case sidebarExtensionShelf
}

/// Drag payload type shared by every Pinned Extension Surface. One identifier
/// lets a drag that strays over a foreign surface or window be recognized and
/// rejected through the engine's surface gate instead of silently ignored.
enum PinnedExtensionReorderPasteboard {
    static let identifier = "com.phinomenon.phi.pinned-extension-reorder"
}

extension NSPasteboard.PasteboardType {
    static let phiPinnedExtensionReorder = NSPasteboard.PasteboardType(
        PinnedExtensionReorderPasteboard.identifier
    )
}

struct PinnedExtensionMoveIntent: Equatable {
    let extensionId: String
    let destinationIndex: Int
}

struct PinnedExtensionResolution: Equatable {
    let items: [PinnedExtensionOrderItem]
    let destinationIndex: Int
}

/// Window-scoped presentation state for a reorder gesture. Chromium's complete
/// pinned snapshot remains authoritative; this engine only holds a transient
/// preview and the one move awaiting Chromium confirmation.
final class PinnedExtensionOrderingEngine: ObservableObject {
    private enum Phase: Equatable {
        case idle
        case dragging(extensionId: String, surface: PinnedExtensionSurface)
        case pending(PinnedExtensionMoveIntent)
    }

    @Published private(set) var presentationOrder: [String]?
    @Published private var phase: Phase = .idle
    /// Invoked after Pending Reorder Confirmation times out and the
    /// native-only preview has been abandoned; the owner refreshes the
    /// complete extension snapshot from Chromium.
    var onConfirmationTimeout: (() -> Void)?
    private let confirmationTimeout: TimeInterval
    private var authoritative: [PinnedExtensionOrderItem] = []
    private var visibleProjection: [String] = []
    private var proposedMove: PinnedExtensionMoveIntent?
    private var confirmationWatchdog: DispatchWorkItem?

    init(confirmationTimeout: TimeInterval = 2.0) {
        self.confirmationTimeout = confirmationTimeout
    }

    var pendingMove: PinnedExtensionMoveIntent? {
        guard case .pending(let move) = phase else { return nil }
        return move
    }

    var draggedExtensionId: String? {
        guard case .dragging(let extensionId, _) = phase else { return nil }
        return extensionId
    }

    var visiblePresentationOrder: [String] {
        guard let presentationOrder else { return [] }
        let visible = Set(visibleProjection)
        return presentationOrder.filter(visible.contains)
    }

    static func resolve(
        canonical: [PinnedExtensionOrderItem],
        draggedExtensionId: String,
        targetExtensionId: String,
        placement: PinnedExtensionAnchorPlacement
    ) -> PinnedExtensionResolution? {
        guard draggedExtensionId != targetExtensionId,
              Set(canonical.map(\.id)).count == canonical.count,
              let dragged = canonical.first(where: { $0.id == draggedExtensionId }),
              !dragged.isForcePinned,
              let target = canonical.first(where: { $0.id == targetExtensionId }),
              !target.isForcePinned else {
            return nil
        }

        var reordered = canonical
        guard let sourceIndex = reordered.firstIndex(where: { $0.id == draggedExtensionId }) else {
            return nil
        }
        reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == targetExtensionId }) else {
            return nil
        }
        let insertionIndex = placement == .before ? targetIndex : targetIndex + 1
        reordered.insert(dragged, at: insertionIndex)

        // Force-Pinned Extensions form a protected suffix. Reject malformed
        // input or any result that would put an ordinary action after it.
        guard Self.isForcePinnedSuffix(reordered),
              let destinationIndex = reordered.firstIndex(where: { $0.id == draggedExtensionId }) else {
            return nil
        }
        return PinnedExtensionResolution(items: reordered, destinationIndex: destinationIndex)
    }

    /// Whether every Force-Pinned Extension sits in one trailing block. This
    /// is how Chromium composes the pinned list except in one policy corner:
    /// force-pinning an action the user had already pinned leaves it at its
    /// pref position, interleaved among ordinary actions. No anchored move
    /// can resolve against that shape, so it also gates `beginDrag` — the
    /// gesture stays a plain click instead of starting a session whose every
    /// preview would be rejected. See
    /// .scratch/pinned-extension-reordering/issues/02.
    static func isForcePinnedSuffix(_ items: [PinnedExtensionOrderItem]) -> Bool {
        guard let firstForcePinned = items.firstIndex(where: \.isForcePinned) else {
            return true
        }
        return !items[firstForcePinned...].contains { !$0.isForcePinned }
    }

    func reconcile(authoritative snapshot: [PinnedExtensionOrderItem]) {
        let changed = authoritative != snapshot
        authoritative = snapshot
        switch phase {
        case .idle:
            break
        case .dragging where !changed:
            return
        case .dragging, .pending:
            reset()
        }
    }

    @discardableResult
    func beginDrag(
        extensionId: String,
        visibleProjection: [String],
        surface: PinnedExtensionSurface,
        allowsReordering: Bool
    ) -> Bool {
        reset()
        guard allowsReordering,
              Self.isForcePinnedSuffix(authoritative),
              Set(visibleProjection).count == visibleProjection.count,
              visibleProjection.contains(extensionId),
              let source = authoritative.first(where: { $0.id == extensionId }),
              !source.isForcePinned else {
            return false
        }
        self.visibleProjection = visibleProjection
        phase = .dragging(extensionId: extensionId, surface: surface)
        presentationOrder = authoritative.map(\.id)
        return true
    }

    @discardableResult
    func updatePreview(
        targetExtensionId: String,
        placement: PinnedExtensionAnchorPlacement,
        surface: PinnedExtensionSurface
    ) -> Bool {
        guard case .dragging(let draggedId, let originSurface) = phase,
              originSurface == surface,
              visibleProjection.contains(targetExtensionId) else {
            return false
        }

        if targetExtensionId == draggedId {
            // Once the preview moves the source into the pointer's slot, the
            // next hit-test naturally targets the source itself. Preserve the
            // existing proposal until the pointer crosses another midpoint.
            return true
        }
        guard let resolution = Self.resolve(
            canonical: authoritative,
            draggedExtensionId: draggedId,
            targetExtensionId: targetExtensionId,
            placement: placement
        ) else {
            return false
        }
        let order = resolution.items.map(\.id)
        if presentationOrder != order {
            presentationOrder = order
        }
        if resolution.items == authoritative {
            if proposedMove != nil {
                proposedMove = nil
            }
        } else {
            let move = PinnedExtensionMoveIntent(
                extensionId: draggedId,
                destinationIndex: resolution.destinationIndex
            )
            if proposedMove != move {
                proposedMove = move
            }
        }
        return true
    }

    func leave(surface: PinnedExtensionSurface) {
        guard case .dragging(_, let originSurface) = phase,
              originSurface == surface else { return }
        if presentationOrder != nil {
            presentationOrder = nil
        }
        if proposedMove != nil {
            proposedMove = nil
        }
    }

    func cancel(surface: PinnedExtensionSurface) {
        guard activeSurface == surface else { return }
        reset()
    }

    func commit(surface: PinnedExtensionSurface) -> PinnedExtensionMoveIntent? {
        guard case .dragging(_, let originSurface) = phase,
              originSurface == surface,
              let proposedMove else {
            return nil
        }
        phase = .pending(proposedMove)
        armConfirmationWatchdog()
        return proposedMove
    }

    /// Pending Reorder Confirmation must not become a second source of
    /// truth: if Chromium's complete snapshot does not arrive in time, drop
    /// the preview and ask the owner to pull a fresh snapshot instead.
    private func armConfirmationWatchdog() {
        confirmationWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, case .pending = self.phase else { return }
            self.reset()
            self.onConfirmationTimeout?()
        }
        confirmationWatchdog = watchdog
        DispatchQueue.main.asyncAfter(
            deadline: .now() + confirmationTimeout, execute: watchdog)
    }

    private var activeSurface: PinnedExtensionSurface? {
        switch phase {
        case .dragging(_, let surface): return surface
        case .idle, .pending: return nil
        }
    }

    private func reset() {
        confirmationWatchdog?.cancel()
        confirmationWatchdog = nil
        if phase != .idle {
            phase = .idle
        }
        if presentationOrder != nil {
            presentationOrder = nil
        }
        visibleProjection = []
        proposedMove = nil
    }
}

class ExtensionManager: ObservableObject {
    struct BadgeState: Equatable {
        var text: String
        var backgroundColor: NSColor
        var textColor: NSColor
        var visible: Bool
        var enabled: Bool
        var grayscale: Bool
    }

    @Published var extensions: [Extension] = []
    @Published var pinedExtensions: [Extension] = []
    @Published var phiExtensionVersions: [String: String] = [:]
    @Published var shouldDisplayExtensionsWithinSidebar: Bool = false
    // Per-extension action state for this window (the manager is per-window).
    @Published var badges: [String: BadgeState] = [:]
    @Published var dynamicIcons: [String: NSImage] = [:]
    let pinnedExtensionOrdering = PinnedExtensionOrderingEngine()
    private weak var browserState: BrowserState?
    init(browserState: BrowserState) {
        self.browserState = browserState
        pinnedExtensionOrdering.onConfirmationTimeout = { [weak self] in
            self?.refreshExtensions()
        }
    }
    static let phiExtensionIds = PhiExtensionID.canaryManaged
    
    func extensionChanged(_ info: [[String: Any]]) {
        let mapped = info.compactMap { Extension(from: $0) }
        phiExtensionVersions = Dictionary(uniqueKeysWithValues: mapped
            .filter { Self.phiExtensionIds.contains($0.id) }
            .map { ($0.name, $0.version) }
        )
        
        extensions = mapped
        #if NIGHTLY_BUILD || DEBUG
            .filter { $0.id != "fenmfiepnpdlhplemgijlimpbebebljo" }
        #else
            .filter { !Self.phiExtensionIds.contains($0.id) }
        #endif
            .sorted {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                if $0.isPinned && $1.isPinned {
                    return $0.pinnedIndex < $1.pinnedIndex
                }
                return $0.name < $1.name
            }
        pinedExtensions = extensions.filter { $0.isPinned }.sorted { $0.pinnedIndex < $1.pinnedIndex }
        let authoritativePinned = mapped
            .filter(\.isPinned)
            .sorted { $0.pinnedIndex < $1.pinnedIndex }
            .map { PinnedExtensionOrderItem(id: $0.id, isForcePinned: $0.isForcePinned) }
        pinnedExtensionOrdering.reconcile(authoritative: authoritativePinned)

        // Reconcile per-extension action state with the current list: drop
        // badges / dynamic icons for ids Chromium no longer reports (unloaded,
        // or filtered out — e.g. incognito-ineligible), so a stale overflow dot
        // or leftover dynamic icon can't persist. Keyed off the unfiltered set
        // (`mapped`) so Phi's own built-ins aren't pruned.
        let liveIds = Set(mapped.map(\.id))
        let prunedBadges = badges.filter { liveIds.contains($0.key) }
        if prunedBadges.count != badges.count {
            badges = prunedBadges
        }
        let prunedIcons = dynamicIcons.filter { liveIds.contains($0.key) }
        if prunedIcons.count != dynamicIcons.count {
            dynamicIcons = prunedIcons
        }

        // Existing-user backfill: the sole default profile's enabled extensions
        // are now known; adopt iCloud Passwords as the new-profile default when
        // the preference was never recorded. Gated + self-healing inside.
        ProfileManager.shared.backfillICloudPasswordsPrefIfNeeded(
            installedExtensionIds: mapped.map(\.id))
    }

    func refreshExtensions() {
        ChromiumLauncher.sharedInstance().bridge?.getAllExtensions(completion: { infos in
            if let typedInfos = infos as? [[String: Any]] {
                self.extensionChanged(typedInfos)
            }
        }, windowId: browserState?.windowId.int64Value ?? 0)
    }
    
    // MARK: - Action badge / dynamic icon (pushed from Chromium per window)

    func handleBadgeInfo(_ info: [AnyHashable: Any]) {
        guard let extensionId = info["extensionId"] as? String else { return }
        if let state = Self.badgeState(from: info) {
            badges[extensionId] = state
        } else {
            badges.removeValue(forKey: extensionId)
        }
    }

    /// Parses a badge-info dictionary into a `BadgeState`, or `nil` when the
    /// action is fully default (no badge text, visible, enabled, not grayed)
    /// and the entry should be removed. A hidden page action or a disabled
    /// action commonly has empty badge text, so removal keys on text *and* the
    /// state flags — otherwise the renderer would lose the state it needs to
    /// hide / gray / downgrade clicks. Pure; exposed for unit testing.
    static func badgeState(from info: [AnyHashable: Any]) -> BadgeState? {
        let text = info["badgeText"] as? String ?? ""
        let visible = info["visible"] as? Bool ?? true
        let enabled = info["enabled"] as? Bool ?? true
        let grayscale = info["grayscale"] as? Bool ?? false
        if text.isEmpty && visible && enabled && !grayscale {
            return nil
        }
        return BadgeState(
            text: text,
            backgroundColor: NSColor.fromRGBAString(info["backgroundColor"] as? String ?? ""),
            textColor: NSColor.fromRGBAString(info["textColor"] as? String ?? ""),
            visible: visible,
            enabled: enabled,
            grayscale: grayscale)
    }

    /// Gate value for the icon faces' rebuild subscriptions: the ids whose
    /// action *renders* non-default, with the (visible, grayscale) pair baked
    /// in so a hidden↔grayed transition also changes the set, while a
    /// badge-text tick (e.g. a blocked-count) does not. `enabled` is excluded:
    /// it only affects click handling, which reads the live badge state.
    struct ActionRenderState: Hashable {
        let id: String
        let visible: Bool
        let grayscale: Bool
    }

    static func actionRenderStates(
        _ badges: [String: BadgeState]
    ) -> Set<ActionRenderState> {
        Set(badges.compactMap { id, state in
            (state.visible && !state.grayscale)
                ? nil
                : ActionRenderState(id: id, visible: state.visible, grayscale: state.grayscale)
        })
    }

    func handleIconInfo(_ info: [AnyHashable: Any]) {
        guard let extensionId = info["extensionId"] as? String else { return }
        guard let data = info["iconData"] as? Data, !data.isEmpty else {
            dynamicIcons.removeValue(forKey: extensionId)
            return
        }
        guard let image = NSImage(data: data) else {
            dynamicIcons.removeValue(forKey: extensionId)
            return
        }
        if let dip = info["dipSize"] as? Double, dip > 0 {
            image.size = NSSize(width: dip, height: dip)
        }
        dynamicIcons[extensionId] = image
    }

    func togglePin(_ model: Extension) {
        if !model.isPinned {
            ChromiumLauncher.sharedInstance().bridge?.pinExtension(withId: model.id, windowId: Int64(browserState?.windowId ?? 0))
        } else {
            ChromiumLauncher.sharedInstance().bridge?.unpinExtension(withId: model.id, windowId: Int64(browserState?.windowId ?? 0))
        }
    }

    /// The pinned list projected through the engine's transient Reorder
    /// Preview order while a reorder is in flight; the authoritative order
    /// otherwise. Shared by every Pinned Extension Surface of this window.
    func presentedPinnedOrder(of pinnedExtensions: [Extension]) -> [Extension] {
        guard let previewOrder = pinnedExtensionOrdering.presentationOrder else {
            return pinnedExtensions
        }
        let byId = Dictionary(uniqueKeysWithValues: pinnedExtensions.map { ($0.id, $0) })
        return previewOrder.compactMap { byId[$0] }
    }

    @discardableResult
    func beginPinnedExtensionReorder(
        extensionId: String,
        visibleProjection: [String],
        surface: PinnedExtensionSurface
    ) -> Bool {
        pinnedExtensionOrdering.beginDrag(
            extensionId: extensionId,
            visibleProjection: visibleProjection,
            surface: surface,
            allowsReordering: browserState?.isIncognito == false
        )
    }

    @discardableResult
    func updatePinnedExtensionReorder(
        targetExtensionId: String,
        placement: PinnedExtensionAnchorPlacement,
        surface: PinnedExtensionSurface
    ) -> Bool {
        pinnedExtensionOrdering.updatePreview(
            targetExtensionId: targetExtensionId,
            placement: placement,
            surface: surface
        )
    }

    func leavePinnedExtensionReorder(surface: PinnedExtensionSurface) {
        pinnedExtensionOrdering.leave(surface: surface)
    }

    func cancelPinnedExtensionReorder(surface: PinnedExtensionSurface) {
        pinnedExtensionOrdering.cancel(surface: surface)
    }

    @discardableResult
    func commitPinnedExtensionReorder(surface: PinnedExtensionSurface) -> Bool {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            cancelPinnedExtensionReorder(surface: surface)
            return false
        }
        guard let move = pinnedExtensionOrdering.commit(surface: surface) else {
            return false
        }
        bridge.movePinnedExtension(
            withId: move.extensionId,
            to: Int32(move.destinationIndex),
            windowId: browserState?.windowId.int64Value ?? 0
        )
        return true
    }
    
    #if DEBUG
    func loadTestData(itemCount: Int) {
        guard itemCount >= 0 else { return }
        
        let mockData: [[String: Any]]
        if itemCount == 0 {
            mockData = []
        } else {
            mockData = (1...itemCount).map { i -> [String: Any] in
                let shouldPin = i <= min(4, max(1, itemCount / 4))
                return [
                    "id": "test_\(i)",
                    "name": "Test Extension \(i)",
                    "version": "1.0.0",
                    "isPinned": shouldPin,
                    "pinnedIndex": shouldPin ? i : -1
                ]
            }
        }
        extensionChanged(mockData)
    }
    #endif
}

extension NSColor {
    /// Parses Chromium's `color_utils::SkColorToRgbaString` output —
    /// `rgba(R,G,B,A)` with R/G/B in 0..255 and A in 0..1. Returns `.clear`
    /// on any parse failure.
    static func fromRGBAString(_ s: String) -> NSColor {
        guard let open = s.firstIndex(of: "("),
              let close = s.firstIndex(of: ")") else { return .clear }
        let parts = s[s.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let r = Double(parts[0]), let g = Double(parts[1]),
              let b = Double(parts[2]), let a = Double(parts[3]) else { return .clear }
        return NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }
}

extension ExtensionManager {
    /// The icon to display for `extensionId`: the dynamic action icon (setIcon /
    /// declarative) if set, else the static manifest icon, else a puzzlepiece
    /// fallback. A grayed action (disabled with no page interaction, see the
    /// bridge contract) renders desaturated + lightened, mirroring Chrome's
    /// toolbar; a hidden page action is instead removed by the faces' layout
    /// filters. The badge is NOT composited here — it is drawn as an overlay
    /// (`extensionBadgeOverlay` in SwiftUI, `BadgeCornerOverlay` hosted on
    /// AppKit surfaces) anchored to the icon's bottom-right corner.
    func iconImage(extensionId: String, staticIcon: NSImage?) -> NSImage {
        let icon = dynamicIcons[extensionId]
            ?? staticIcon
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            ?? NSImage()
        return badges[extensionId]?.grayscale == true ? icon.disabledActionVariant : icon
    }
}

extension NSImage {
    /// Grayed variant used for a disabled extension action icon. Matches
    /// Chrome's IconWithBadgeImageSource grayscale: HSL shift {-1, 0, 0.6} =
    /// full desaturation + lightness 0.6, i.e. each channel blended 20% toward
    /// white (out = 0.8·in + 0.2), with alpha untouched. Falls back to the
    /// original image if the bitmap can't be filtered.
    var disabledActionVariant: NSImage {
        guard let tiff = tiffRepresentation,
              let ciImage = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return self }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return self }
        let grayscale = NSImage(size: size)
        grayscale.addRepresentation(NSCIImageRep(ciImage: output))
        // Resolution-independent wrapper: draws lazily at the destination's
        // backing scale, so the 2x detail survives the point-size `size`.
        // sourceAtop confines the white lightening to the icon's own alpha.
        return NSImage(size: size, flipped: false) { rect in
            grayscale.draw(in: rect)
            NSColor(white: 1.0, alpha: 0.2).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
