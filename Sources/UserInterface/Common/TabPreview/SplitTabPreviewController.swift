// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

enum SplitTabPreviewTargetID: Hashable {
    case live(String)
    case persisted(String, String)
    case bookmark(String)
}

private enum SplitTabPreviewPaneID: Hashable {
    case persisted(String)
    case live(Int)
    case transient(ObjectIdentifier)
    case bookmarkPrimary(String)
    case bookmarkSecondary(String)
    /// Pane `index` of a split bookmark, counted from the third pane.
    case bookmarkExtra(String, index: Int)
}

private enum SplitTabPreviewTargetSource {
    case tab(Tab)
    case bookmark(Bookmark)
}

struct SplitTabPreviewTarget {
    let logicalID: SplitTabPreviewTargetID
    fileprivate let source: SplitTabPreviewTargetSource
    fileprivate let paneIDs: Set<SplitTabPreviewPaneID>

    static func make(representing tab: Tab, in browserState: BrowserState) -> Self? {
        guard let membership = browserState.splitMembership(forCellTab: tab),
              let logicalID = logicalID(for: membership) else {
            return nil
        }
        let paneIDs = Set(membership.panes.map(paneID(for:)))
        // Every pane must resolve to its own identity; a collision means a
        // transient half-formed split that must not be previewed.
        guard paneIDs.count == membership.paneCount, paneIDs.count >= 2 else { return nil }
        return SplitTabPreviewTarget(
            logicalID: logicalID,
            source: .tab(tab),
            paneIDs: paneIDs
        )
    }

    static func make(representing bookmark: Bookmark) -> Self? {
        guard !bookmark.isEditing, bookmark.splitPanes.count >= 2 else {
            return nil
        }
        return SplitTabPreviewTarget(
            logicalID: .bookmark(bookmark.guid),
            source: .bookmark(bookmark),
            paneIDs: bookmarkPaneIDs(for: bookmark)
        )
    }

    fileprivate static func bookmarkPaneIDs(for bookmark: Bookmark) -> Set<SplitTabPreviewPaneID> {
        var paneIDs: Set<SplitTabPreviewPaneID> = [
            .bookmarkPrimary(bookmark.guid),
            .bookmarkSecondary(bookmark.guid),
        ]
        for index in bookmark.splitExtraPanes.indices {
            paneIDs.insert(.bookmarkExtra(bookmark.guid, index: index))
        }
        return paneIDs
    }

    fileprivate static func logicalID(
        for membership: BrowserState.SplitMembership
    ) -> SplitTabPreviewTargetID? {
        if let group = membership.liveGroup {
            return .live(group.id)
        }
        guard let dbGuids = membership.pinnedDBGuids, dbGuids.count >= 2 else { return nil }
        let identifiers = dbGuids.sorted()
        return .persisted(identifiers[0], identifiers.dropFirst().joined(separator: "|"))
    }

    fileprivate static func paneID(for tab: Tab) -> SplitTabPreviewPaneID {
        if let persistentID = tab.guidInLocalDB, !persistentID.isEmpty {
            return .persisted(persistentID)
        }
        if tab.guid >= 0 {
            return .live(tab.guid)
        }
        return .transient(ObjectIdentifier(tab))
    }
}

struct SplitTabPreviewPaneContent {
    fileprivate let id: SplitTabPreviewPaneID
    let title: String
    let isMemoryReclaimed: Bool
    let url: String
    let image: NSImage?
    let imageSource: SplitTabPreviewImageSource
}

struct SplitTabPreviewContent {
    let id: SplitTabPreviewTargetID
    let mode: SplitTabPreviewMode
    let layout: SplitLayout
    /// Each pane's share of the split axis, in `panes` order; sums to 1.
    let fractions: [Double]
    /// The panes in on-screen order (two to four).
    let panes: [SplitTabPreviewPaneContent]
}

enum SplitTabPreviewMode: Equatable {
    case standard
    case compact
}

enum SplitTabPreviewImageSource: Equatable {
    case thumbnail(tabID: Int64)
    case foreground(tabID: Int64?)
    case unavailable(tabID: Int64?)
    case notRequested
}

@MainActor
struct SplitTabPreviewContentResolver {
    typealias ThumbnailProvider = @MainActor (Int64) -> Data?

    private let thumbnailProvider: ThumbnailProvider

    init(thumbnailProvider: @escaping ThumbnailProvider = { tabID in
        ChromiumLauncher.sharedInstance().bridge?.thumbnail(forTab: tabID)
    }) {
        self.thumbnailProvider = thumbnailProvider
    }

    func isEligible(
        _ target: SplitTabPreviewTarget,
        in browserState: BrowserState,
        previewsEnabled: Bool = true
    ) -> Bool {
        guard previewsEnabled,
              let resolved = resolvedTarget(for: target, in: browserState) else {
            return false
        }
        return resolved.isOpen
    }

    func resolve(
        _ target: SplitTabPreviewTarget,
        in browserState: BrowserState,
        reusing cachedContent: SplitTabPreviewContent? = nil
    ) -> SplitTabPreviewContent? {
        guard let resolved = resolvedTarget(for: target, in: browserState) else { return nil }
        let mode = previewMode(for: resolved, in: browserState)
        // Cached pane images are matched by pane identity, not by position,
        // so a reorder keeps whichever thumbnails are still valid.
        let panes = resolved.panes.map { pane in
            resolvePane(
                pane,
                in: browserState,
                reusing: cachedContent?.panes.first { $0.id == pane.id },
                includesImage: mode == .standard
            )
        }
        return SplitTabPreviewContent(
            id: target.logicalID,
            mode: mode,
            layout: resolved.layout,
            fractions: resolved.fractions,
            panes: panes
        )
    }

    func paneTabs(
        for target: SplitTabPreviewTarget,
        in browserState: BrowserState
    ) -> [Tab] {
        guard let resolved = resolvedTarget(for: target, in: browserState) else { return [] }
        return resolved.panes.compactMap(\.liveTab)
    }

    private struct ResolvedTarget {
        let layout: SplitLayout
        /// One share per entry of `panes`, summing to 1.
        let fractions: [Double]
        /// The panes in on-screen order (two to four).
        let panes: [ResolvedPane]
        let isOpen: Bool
    }

    private struct ResolvedPane {
        let id: SplitTabPreviewPaneID
        let fallbackTitle: String
        let fallbackURL: String
        let liveTab: Tab?
    }

    private func resolvedTarget(
        for target: SplitTabPreviewTarget,
        in browserState: BrowserState
    ) -> ResolvedTarget? {
        switch target.source {
        case .tab(let tab):
            return resolvedTabTarget(tab, target: target, in: browserState)
        case .bookmark(let bookmark):
            return resolvedBookmarkTarget(bookmark, target: target, in: browserState)
        }
    }

    private func resolvedTabTarget(
        _ tab: Tab,
        target: SplitTabPreviewTarget,
        in browserState: BrowserState
    ) -> ResolvedTarget? {
        guard let membership = browserState.splitMembership(forCellTab: tab),
              SplitTabPreviewTarget.logicalID(for: membership) == target.logicalID else {
            return nil
        }
        let currentPaneIDs = Set(membership.panes.map(SplitTabPreviewTarget.paneID(for:)))
        guard currentPaneIDs == target.paneIDs else { return nil }
        let layout = membership.liveGroup?.layout
            ?? membership.pinnedDBGuids.map { browserState.pinnedSplitLayout(dbGuids: $0) }
            ?? .vertical
        return ResolvedTarget(
            layout: layout,
            fractions: fractions(for: membership),
            panes: membership.panes.map { resolvedPane(for: $0, in: browserState) },
            isOpen: membership.liveGroup != nil
        )
    }

    /// The live group's pane shares, re-ordered to match `membership.panes`
    /// (a pinned split lists its panes in pinned-grid order, which may differ
    /// from slot order). Equal shares for a closed pinned split or
    /// whenever a pane cannot be mapped back to its slot.
    private func fractions(for membership: BrowserState.SplitMembership) -> [Double] {
        guard let group = membership.liveGroup else {
            return SplitGroup.equalFractions(paneCount: membership.paneCount)
        }
        var ordered: [Double] = []
        for pane in membership.panes {
            guard let slot = group.slot(of: pane.guid), slot < group.fractions.count else {
                return SplitGroup.equalFractions(paneCount: membership.paneCount)
            }
            ordered.append(group.fractions[slot])
        }
        return ordered
    }

    private func resolvedBookmarkTarget(
        _ bookmark: Bookmark,
        target: SplitTabPreviewTarget,
        in browserState: BrowserState
    ) -> ResolvedTarget? {
        let paneFields = bookmark.splitPanes
        guard !bookmark.isEditing,
              paneFields.count >= 2,
              target.logicalID == .bookmark(bookmark.guid),
              target.paneIDs == SplitTabPreviewTarget.bookmarkPaneIDs(for: bookmark) else {
            return nil
        }

        // A bound live split renders its tabs and shares; a bound split whose
        // pane count no longer matches falls back to the stored URLs with
        // equal shares.
        var liveTabs: [Tab?] = Array(repeating: nil, count: paneFields.count)
        var layout = bookmark.layout ?? .vertical
        var fractions = SplitGroup.equalFractions(paneCount: paneFields.count)
        if let splitID = browserState.splitBookmarkBindings[bookmark.guid],
           let group = browserState.splits.first(where: { $0.id == splitID }) {
            layout = group.layout
            if group.paneCount == paneFields.count {
                liveTabs = group.tabIds.map { tabId in browserState.tabs.first(where: { $0.guid == tabId }) }
                fractions = group.fractions
            }
        }

        return ResolvedTarget(
            layout: layout,
            fractions: fractions,
            panes: paneFields.enumerated().map { index, pane in
                let id: SplitTabPreviewPaneID
                let fallbackTitle: String
                switch index {
                case 0:
                    id = .bookmarkPrimary(bookmark.guid)
                    fallbackTitle = bookmark.title
                case 1:
                    id = .bookmarkSecondary(bookmark.guid)
                    fallbackTitle = bookmark.secondaryTitle ?? ""
                default:
                    id = .bookmarkExtra(bookmark.guid, index: index - 2)
                    fallbackTitle = bookmark.splitExtraPanes[index - 2].title ?? ""
                }
                return ResolvedPane(
                    id: id,
                    fallbackTitle: fallbackTitle,
                    fallbackURL: pane.url,
                    liveTab: liveTabs[index]
                )
            },
            isOpen: liveTabs.allSatisfy { $0 != nil }
        )
    }

    private func resolvedPane(
        for pane: Tab,
        in browserState: BrowserState
    ) -> ResolvedPane {
        ResolvedPane(
            id: SplitTabPreviewTarget.paneID(for: pane),
            fallbackTitle: pane.title,
            fallbackURL: pane.url ?? pane.pinnedUrl ?? "",
            liveTab: liveTab(for: pane, in: browserState)
        )
    }

    private func resolvePane(
        _ pane: ResolvedPane,
        in browserState: BrowserState,
        reusing cachedPane: SplitTabPreviewPaneContent?,
        includesImage: Bool
    ) -> SplitTabPreviewPaneContent {
        let rawURL = pane.liveTab?.url ?? pane.liveTab?.pinnedUrl ?? pane.fallbackURL
        let displayURL = TabPreviewURLPolicy.displayURL(for: rawURL)
        let liveTitle = pane.liveTab?.title ?? ""
        let title = liveTitle.isEmpty
            ? (pane.fallbackTitle.isEmpty ? displayURL : pane.fallbackTitle)
            : liveTitle
        let reusablePane = cachedPane?.id == pane.id ? cachedPane : nil
        let resolvedImage = image(
            liveTab: pane.liveTab,
            isForeground: isForeground(liveTab: pane.liveTab, in: browserState),
            cachedPane: reusablePane,
            includesImage: includesImage && TabPreviewURLPolicy.allowsSnapshot(for: rawURL)
        )
        return SplitTabPreviewPaneContent(
            id: pane.id,
            title: title,
            isMemoryReclaimed: pane.liveTab?.isDiscarded == true
                || pane.liveTab?.isUnloaded == true,
            url: displayURL,
            image: resolvedImage.image,
            imageSource: resolvedImage.source
        )
    }

    private func liveTab(for pane: Tab, in browserState: BrowserState) -> Tab? {
        if let persistentID = pane.guidInLocalDB, !persistentID.isEmpty,
           let liveTab = browserState.tabs.first(where: { $0.guidInLocalDB == persistentID }) {
            return liveTab
        }
        guard pane.guid >= 0 else { return nil }
        return browserState.tabs.first(where: { $0.guid == pane.guid })
    }

    private func isForeground(liveTab: Tab?, in browserState: BrowserState) -> Bool {
        if liveTab?.isActive == true { return true }
        guard let focusingTab = browserState.focusingTab else { return false }
        guard let liveTab else { return false }
        return focusingTab.guid == liveTab.guid
    }

    private func image(
        liveTab: Tab?,
        isForeground: Bool,
        cachedPane: SplitTabPreviewPaneContent?,
        includesImage: Bool
    ) -> (image: NSImage?, source: SplitTabPreviewImageSource) {
        guard includesImage else {
            return (nil, .notRequested)
        }
        if isForeground {
            let tabID = liveTab.flatMap { $0.guid >= 0 ? Int64($0.guid) : nil }
            return (nil, .foreground(tabID: tabID))
        }
        guard let liveTab, liveTab.guid >= 0 else {
            return (nil, .unavailable(tabID: nil))
        }

        let tabID = Int64(liveTab.guid)
        let thumbnailSource = SplitTabPreviewImageSource.thumbnail(tabID: tabID)
        if cachedPane?.imageSource == thumbnailSource, let cachedPane {
            return (cachedPane.image, thumbnailSource)
        }

        let unavailableSource = SplitTabPreviewImageSource.unavailable(tabID: tabID)
        if cachedPane?.imageSource == unavailableSource {
            return (nil, unavailableSource)
        }
        guard let data = thumbnailProvider(tabID), let image = NSImage(data: data) else {
            return (nil, unavailableSource)
        }
        return (image, thumbnailSource)
    }

    private func previewMode(
        for resolved: ResolvedTarget,
        in browserState: BrowserState
    ) -> SplitTabPreviewMode {
        guard resolved.isOpen else { return .compact }
        return resolved.panes.contains { pane in
            isForeground(liveTab: pane.liveTab, in: browserState)
        } ? .compact : .standard
    }
}

@MainActor
final class SplitTabPreviewViewModel: ObservableObject {
    @Published private(set) var content: SplitTabPreviewContent?

    func update(_ content: SplitTabPreviewContent) {
        self.content = content
    }
}

struct SplitTabPreviewView: View {
    @ObservedObject var viewModel: SplitTabPreviewViewModel

    private enum Metrics {
        static let width: CGFloat = 280
        /// Height of the whole split's image area; the panes share it in
        /// proportion to their fractions, so the preview keeps the 16:10
        /// shape of the real split whatever the pane count.
        static let imageHeight: CGFloat = width * 10 / 16
        static let dividerThickness: CGFloat = 1
        static let cornerRadius: CGFloat = 14
    }

    var body: some View {
        if let content = viewModel.content {
            previewLayout(for: content)
                .id("\(content.layout.rawValue):\(content.panes.count)")
                .frame(width: Metrics.width)
                .themedBackground(.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func previewLayout(for content: SplitTabPreviewContent) -> some View {
        switch content.mode {
        case .standard:
            paneLayout(for: content)
        case .compact:
            compactPaneLayout(content)
        }
    }

    /// Standard mode: the panes split the image area the way the real split
    /// divides the window — columns of proportional width for a vertical
    /// split, rows of proportional height for a horizontal one.
    @ViewBuilder
    private func paneLayout(for content: SplitTabPreviewContent) -> some View {
        switch content.layout {
        case .vertical:
            let widths = Self.paneExtents(total: Metrics.width, fractions: content.fractions)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(content.panes.enumerated()), id: \.offset) { index, paneContent in
                    if index > 0 {
                        Divider().frame(width: Metrics.dividerThickness)
                    }
                    pane(paneContent, width: widths[index], imageHeight: Metrics.imageHeight)
                }
            }
        case .horizontal:
            let heights = Self.paneExtents(total: Metrics.imageHeight, fractions: content.fractions)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.panes.enumerated()), id: \.offset) { index, paneContent in
                    if index > 0 {
                        Divider().frame(height: Metrics.dividerThickness)
                    }
                    pane(paneContent, width: Metrics.width, imageHeight: heights[index])
                }
            }
        }
    }

    /// Compact mode shows titles only, so the panes take equal shares: a
    /// narrow pane's title would be unreadable at its real proportion.
    @ViewBuilder
    private func compactPaneLayout(_ content: SplitTabPreviewContent) -> some View {
        switch content.layout {
        case .vertical:
            let widths = Self.paneExtents(
                total: Metrics.width,
                fractions: SplitGroup.equalFractions(paneCount: content.panes.count)
            )
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(content.panes.enumerated()), id: \.offset) { index, paneContent in
                    if index > 0 {
                        Divider().frame(width: Metrics.dividerThickness)
                    }
                    compactPane(paneContent, width: widths[index])
                }
            }
        case .horizontal:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.panes.enumerated()), id: \.offset) { index, paneContent in
                    if index > 0 {
                        Divider().frame(height: Metrics.dividerThickness)
                    }
                    compactPane(paneContent, width: Metrics.width)
                }
            }
        }
    }

    /// Each pane's extent along the split axis: `total` less the dividers,
    /// shared out by `fractions` (the same arithmetic as
    /// `SplitPaneHostView.paneRects`, with this view's divider). The last
    /// pane absorbs the rounding remainder so the extents sum to `total`.
    static func paneExtents(total: CGFloat, fractions: [Double]) -> [CGFloat] {
        let count = fractions.count
        guard count > 0 else { return [] }
        let available = max(0, total - Metrics.dividerThickness * CGFloat(count - 1))
        var extents: [CGFloat] = []
        var used: CGFloat = 0
        for (index, fraction) in fractions.enumerated() {
            let extent = index == count - 1
                ? max(0, available - used)
                : max(0, floor(available * CGFloat(fraction)))
            extents.append(extent)
            used += extent
        }
        return extents
    }

    private func pane(
        _ content: SplitTabPreviewPaneContent,
        width: CGFloat,
        imageHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.primary.opacity(0.04))
                if let image = content.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: imageHeight)
                        .clipped()
                } else {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, height: imageHeight)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                TabPreviewTitleView(
                    title: content.title,
                    isMemoryReclaimed: content.isMemoryReclaimed
                )

                if !content.url.isEmpty {
                    Text(TabPreviewURLPolicy.shortDisplayURL(for: content.url))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .top)
    }

    private func compactPane(
        _ content: SplitTabPreviewPaneContent,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TabPreviewTitleView(
                title: content.title,
                isMemoryReclaimed: content.isMemoryReclaimed
            )

            if !content.url.isEmpty {
                Text(content.url)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
    }
}

@MainActor
final class SplitTabPreviewController {
    private static let showDelay: TimeInterval = 0.5
    private static let handoffDelay: TimeInterval = 0.15
    private static let handoffFrameAnimationDuration: TimeInterval = 0.18

    private weak var window: NSWindow?
    /// The same window-scoped surface used by standard tab previews. Split
    /// preview resolution, state, and rendering remain owned by this module.
    let presentationController: CustomTooltipController
    private let resolver: SplitTabPreviewContentResolver
    private let viewModel = SplitTabPreviewViewModel()
    private lazy var previewView = AnyView(SplitTabPreviewView(viewModel: viewModel))

    init(window: NSWindow) {
        self.window = window
        presentationController = window.customTooltipController
        resolver = SplitTabPreviewContentResolver()
    }

    init(window: NSWindow, resolver: SplitTabPreviewContentResolver) {
        self.window = window
        presentationController = window.customTooltipController
        self.resolver = resolver
    }

    func pointerEntered(
        ownerID: UUID,
        anchorView: NSView,
        anchorRectProvider: CustomTooltipAnchorRectProvider?,
        target: SplitTabPreviewTarget,
        browserState: BrowserState,
        placement: CustomTooltipPlacement
    ) {
        guard let window,
              anchorView.window === window,
              resolver.isEligible(
                target,
                in: browserState,
                previewsEnabled: PhiPreferences.GeneralSettings.showTabPreviews.loadValue()
              ) else {
            presentationController.dismiss(ownerID: ownerID)
            return
        }
        presentationController.pointerEntered(
            ownerID: ownerID,
            anchorView: anchorView,
            content: previewView,
            configuration: configuration(placement: placement),
            anchorRectProvider: anchorRectProvider,
            prepareForPresentation: preparation(
                anchorView: anchorView,
                target: target,
                browserState: browserState,
                reuseCurrentImages: false
            )
        )
    }

    func update(
        ownerID: UUID,
        anchorView: NSView,
        anchorRectProvider: CustomTooltipAnchorRectProvider?,
        target: SplitTabPreviewTarget,
        browserState: BrowserState,
        placement: CustomTooltipPlacement
    ) {
        guard let window,
              anchorView.window === window,
              resolver.isEligible(
                target,
                in: browserState,
                previewsEnabled: PhiPreferences.GeneralSettings.showTabPreviews.loadValue()
              ) else {
            dismiss(ownerID: ownerID)
            return
        }
        let tooltipController = presentationController
        let isActiveOwner = tooltipController.activeOwnerID == ownerID
        if isActiveOwner || tooltipController.pendingOwnerID == ownerID {
            tooltipController.update(
                ownerID: ownerID,
                anchorView: anchorView,
                content: previewView,
                configuration: configuration(placement: placement),
                anchorRectProvider: anchorRectProvider,
                prepareForPresentation: preparation(
                    anchorView: anchorView,
                    target: target,
                    browserState: browserState,
                    reuseCurrentImages: isActiveOwner
                )
            )
        } else {
            pointerEntered(
                ownerID: ownerID,
                anchorView: anchorView,
                anchorRectProvider: anchorRectProvider,
                target: target,
                browserState: browserState,
                placement: placement
            )
        }
    }

    func pointerExited(ownerID: UUID) {
        presentationController.pointerExited(ownerID: ownerID)
    }

    func dismiss(ownerID: UUID) {
        presentationController.dismiss(ownerID: ownerID)
    }

    private func configuration(placement: CustomTooltipPlacement) -> CustomTooltipConfiguration {
        CustomTooltipConfiguration(
            showDelay: Self.showDelay,
            displayDuration: nil,
            placement: placement,
            handoffDelay: Self.handoffDelay,
            handoffGroup: .tabPreview,
            handoffFrameAnimationDuration: Self.handoffFrameAnimationDuration
        )
    }

    private func preparation(
        anchorView: NSView,
        target: SplitTabPreviewTarget,
        browserState: BrowserState,
        reuseCurrentImages: Bool
    ) -> CustomTooltipPresentationPreparation {
        { [weak self, weak anchorView, weak browserState] in
            guard let self,
                  let window = self.window,
                  anchorView?.window === window,
                  let browserState else {
                return false
            }
            let reusableContent = reuseCurrentImages ? self.viewModel.content : nil
            guard self.resolver.isEligible(
                target,
                in: browserState,
                previewsEnabled: PhiPreferences.GeneralSettings.showTabPreviews.loadValue()
            ) else {
                return false
            }
            guard let content = self.resolver.resolve(
                target,
                in: browserState,
                reusing: reusableContent
            ) else {
                return false
            }
            self.viewModel.update(content)
            return true
        }
    }
}

@MainActor
final class SplitTabPreviewRegistration {
    let ownerID = UUID()
    var onEligibilityChanged: ((Bool) -> Void)?

    private weak var anchorView: NSView?
    private weak var browserState: BrowserState?
    private weak var activeController: SplitTabPreviewController?
    private var anchorRectProvider: CustomTooltipAnchorRectProvider?
    private var target: SplitTabPreviewTarget?
    private var targetID: SplitTabPreviewTargetID?
    private var placement: CustomTooltipPlacement = .below
    private var isHovering = false
    private var isDragging = false
    private var targetCancellables = Set<AnyCancellable>()
    private var paneCancellables = Set<AnyCancellable>()
    private var hoverStateCancellables = Set<AnyCancellable>()
    private let resolver = SplitTabPreviewContentResolver()

    func configure(
        anchorView: NSView,
        target: SplitTabPreviewTarget,
        browserState: BrowserState,
        placement: CustomTooltipPlacement,
        anchorRectProvider: CustomTooltipAnchorRectProvider? = nil
    ) {
        let sameTarget = targetID == target.logicalID && self.browserState === browserState
        let sameWindow = self.anchorView?.window === anchorView.window
        let canRebindVisibleSurface = isHovering && sameWindow
        if !sameTarget && !canRebindVisibleSurface {
            dismissImmediately()
        }
        self.anchorView = anchorView
        self.anchorRectProvider = anchorRectProvider
        self.target = target
        targetID = target.logicalID
        self.browserState = browserState
        self.placement = placement
        isDragging = browserState.tabDraggingSession.snapshot.isDragging
        subscribe(to: target)
        subscribeToPaneTabs()
        if isHovering {
            subscribeToHoveredState(browserState)
        }
        guard updateEligibility() else {
            dismissImmediately()
            return
        }
        if isHovering {
            sameTarget ? refreshIfHovering() : present()
        }
    }

    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if hovering {
            guard let browserState else { return }
            isDragging = browserState.tabDraggingSession.snapshot.isDragging
            subscribeToPaneTabs()
            subscribeToHoveredState(browserState)
            guard updateEligibility() else {
                dismissImmediately()
                return
            }
            present()
        } else {
            hoverStateCancellables.removeAll()
            isDragging = false
            activeController?.pointerExited(ownerID: ownerID)
        }
    }

    func cancelForInteraction() {
        isHovering = false
        hoverStateCancellables.removeAll()
        isDragging = false
        dismissImmediately()
    }

    func invalidate() {
        isHovering = false
        dismissImmediately()
        targetCancellables.removeAll()
        paneCancellables.removeAll()
        hoverStateCancellables.removeAll()
        anchorView = nil
        anchorRectProvider = nil
        browserState = nil
        target = nil
        targetID = nil
        isDragging = false
        onEligibilityChanged?(false)
    }

    private func present() {
        guard isHovering,
              !isDragging,
              let anchorView,
              let window = anchorView.window,
              let target,
              let browserState else { return }
        let controller = window.splitTabPreviewController
        if activeController !== controller {
            activeController?.dismiss(ownerID: ownerID)
            activeController = controller
        }
        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: anchorView,
            anchorRectProvider: anchorRectProvider,
            target: target,
            browserState: browserState,
            placement: placement
        )
    }

    private func refreshIfHovering() {
        guard updateEligibility() else {
            dismissImmediately()
            return
        }
        guard isHovering,
              let anchorView,
              let target,
              let browserState,
              let controller = activeController ?? anchorView.window?.splitTabPreviewController else {
            return
        }
        activeController = controller
        controller.update(
            ownerID: ownerID,
            anchorView: anchorView,
            anchorRectProvider: anchorRectProvider,
            target: target,
            browserState: browserState,
            placement: placement
        )
    }

    private func dismissImmediately() {
        activeController?.dismiss(ownerID: ownerID)
        activeController = nil
    }

    @discardableResult
    private func updateEligibility() -> Bool {
        guard let target, let browserState else {
            onEligibilityChanged?(false)
            return false
        }
        let isCurrentlyDragging = isDragging
            || browserState.tabDraggingSession.snapshot.isDragging
        let isEligible = !isCurrentlyDragging
            && resolver.isEligible(
                target,
                in: browserState,
                previewsEnabled: PhiPreferences.GeneralSettings.showTabPreviews.loadValue()
            )
        onEligibilityChanged?(isEligible)
        return isEligible
    }

    private func subscribeToPaneTabs() {
        paneCancellables.removeAll()
        guard let target, let browserState else { return }
        for tab in resolver.paneTabs(for: target, in: browserState) {
            Publishers.CombineLatest(tab.$isDiscarded, tab.$isUnloaded)
                .map { $0 || $1 }
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &paneCancellables)

            Publishers.CombineLatest3(tab.$title, tab.$url, tab.$isActive)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _, _ in self?.refreshIfHovering() }
                .store(in: &paneCancellables)
        }
    }

    private func subscribe(to target: SplitTabPreviewTarget) {
        targetCancellables.removeAll()
        guard case .bookmark(let bookmark) = target.source else { return }

        bookmark.$title
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &targetCancellables)
        bookmark.$url
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &targetCancellables)
        bookmark.$secondaryUrl
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &targetCancellables)
        bookmark.$secondaryTitle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &targetCancellables)
        bookmark.$isEditing
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &targetCancellables)
    }

    private func paneSetChanged() {
        subscribeToPaneTabs()
        refreshIfHovering()
    }

    private func subscribeToHoveredState(_ browserState: BrowserState) {
        hoverStateCancellables.removeAll()
        browserState.$focusingTab
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &hoverStateCancellables)
        browserState.$splits
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.paneSetChanged() }
            .store(in: &hoverStateCancellables)
        browserState.$tabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.paneSetChanged() }
            .store(in: &hoverStateCancellables)
        browserState.$normalTabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &hoverStateCancellables)
        browserState.$pinnedTabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.paneSetChanged() }
            .store(in: &hoverStateCancellables)
        browserState.tabDraggingSession.isDraggingPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDragging in
                guard let self else { return }
                self.isDragging = isDragging
                if isDragging {
                    self.updateEligibility()
                    self.dismissImmediately()
                } else {
                    self.refreshIfHovering()
                }
            }
            .store(in: &hoverStateCancellables)
    }
}

private var splitTabPreviewControllerKey: UInt8 = 0

@MainActor
extension NSWindow {
    var splitTabPreviewController: SplitTabPreviewController {
        if let controller = objc_getAssociatedObject(
            self,
            &splitTabPreviewControllerKey
        ) as? SplitTabPreviewController {
            return controller
        }
        let controller = SplitTabPreviewController(window: self)
        objc_setAssociatedObject(
            self,
            &splitTabPreviewControllerKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return controller
    }
}
