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
        let paneIDs = Set([
            paneID(for: membership.leftPane),
            paneID(for: membership.rightPane),
        ])
        guard paneIDs.count == 2 else { return nil }
        return SplitTabPreviewTarget(
            logicalID: logicalID,
            source: .tab(tab),
            paneIDs: paneIDs
        )
    }

    static func make(representing bookmark: Bookmark) -> Self? {
        guard !bookmark.isFolder,
              !bookmark.isEditing,
              let primaryURL = bookmark.url,
              !primaryURL.isEmpty,
              let secondaryURL = bookmark.secondaryUrl,
              !secondaryURL.isEmpty else {
            return nil
        }
        return SplitTabPreviewTarget(
            logicalID: .bookmark(bookmark.guid),
            source: .bookmark(bookmark),
            paneIDs: [
                .bookmarkPrimary(bookmark.guid),
                .bookmarkSecondary(bookmark.guid),
            ]
        )
    }

    fileprivate static func logicalID(
        for membership: BrowserState.SplitMembership
    ) -> SplitTabPreviewTargetID? {
        if let group = membership.liveGroup {
            return .live(group.id)
        }
        guard let pair = membership.pinnedDBPair else { return nil }
        let identifiers = [pair.left, pair.right].sorted()
        return .persisted(identifiers[0], identifiers[1])
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
    let url: String
    let image: NSImage?
    let imageSource: SplitTabPreviewImageSource
}

struct SplitTabPreviewContent {
    let id: SplitTabPreviewTargetID
    let mode: SplitTabPreviewMode
    let layout: SplitLayout
    let leftPane: SplitTabPreviewPaneContent
    let rightPane: SplitTabPreviewPaneContent
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

    func isEligible(_ target: SplitTabPreviewTarget, in browserState: BrowserState) -> Bool {
        resolvedTarget(for: target, in: browserState) != nil
    }

    func resolve(
        _ target: SplitTabPreviewTarget,
        in browserState: BrowserState,
        reusing cachedContent: SplitTabPreviewContent? = nil
    ) -> SplitTabPreviewContent? {
        guard let resolved = resolvedTarget(for: target, in: browserState) else { return nil }
        let mode = previewMode(for: resolved, in: browserState)
        return SplitTabPreviewContent(
            id: target.logicalID,
            mode: mode,
            layout: resolved.layout,
            leftPane: resolvePane(
                resolved.leftPane,
                in: browserState,
                reusing: cachedContent?.leftPane,
                includesImage: mode == .standard
            ),
            rightPane: resolvePane(
                resolved.rightPane,
                in: browserState,
                reusing: cachedContent?.rightPane,
                includesImage: mode == .standard
            )
        )
    }

    func paneTabs(
        for target: SplitTabPreviewTarget,
        in browserState: BrowserState
    ) -> [Tab] {
        guard let resolved = resolvedTarget(for: target, in: browserState) else { return [] }
        return [resolved.leftPane.liveTab, resolved.rightPane.liveTab].compactMap { $0 }
    }

    private struct ResolvedTarget {
        let layout: SplitLayout
        let leftPane: ResolvedPane
        let rightPane: ResolvedPane
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
        let currentPaneIDs = Set([
            SplitTabPreviewTarget.paneID(for: membership.leftPane),
            SplitTabPreviewTarget.paneID(for: membership.rightPane),
        ])
        guard currentPaneIDs == target.paneIDs else { return nil }
        return ResolvedTarget(
            layout: membership.liveGroup?.layout ?? .vertical,
            leftPane: resolvedPane(for: membership.leftPane, in: browserState),
            rightPane: resolvedPane(for: membership.rightPane, in: browserState),
            isOpen: membership.liveGroup != nil
        )
    }

    private func resolvedBookmarkTarget(
        _ bookmark: Bookmark,
        target: SplitTabPreviewTarget,
        in browserState: BrowserState
    ) -> ResolvedTarget? {
        guard !bookmark.isFolder,
              !bookmark.isEditing,
              let primaryURL = bookmark.url,
              !primaryURL.isEmpty,
              let secondaryURL = bookmark.secondaryUrl,
              !secondaryURL.isEmpty,
              target.logicalID == .bookmark(bookmark.guid),
              target.paneIDs == [
                  .bookmarkPrimary(bookmark.guid),
                  .bookmarkSecondary(bookmark.guid),
              ] else {
            return nil
        }

        let livePanes: (primary: Tab?, secondary: Tab?, layout: SplitLayout) = {
            guard let splitID = browserState.splitBookmarkBindings[bookmark.guid],
                  let group = browserState.splits.first(where: { $0.id == splitID }) else {
                return (nil, nil, .vertical)
            }
            return (
                browserState.tabs.first(where: { $0.guid == group.primaryTabId }),
                browserState.tabs.first(where: { $0.guid == group.secondaryTabId }),
                group.layout
            )
        }()

        return ResolvedTarget(
            layout: livePanes.layout,
            leftPane: ResolvedPane(
                id: .bookmarkPrimary(bookmark.guid),
                fallbackTitle: bookmark.title,
                fallbackURL: primaryURL,
                liveTab: livePanes.primary
            ),
            rightPane: ResolvedPane(
                id: .bookmarkSecondary(bookmark.guid),
                fallbackTitle: bookmark.secondaryTitle ?? "",
                fallbackURL: secondaryURL,
                liveTab: livePanes.secondary
            ),
            isOpen: livePanes.primary != nil && livePanes.secondary != nil
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
            includesImage: includesImage
        )
        return SplitTabPreviewPaneContent(
            id: pane.id,
            title: title,
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
        let panes = [resolved.leftPane, resolved.rightPane]
        return panes.contains { pane in
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
        static let width: CGFloat = 396
        static let imageHeight: CGFloat = 280 * 10 / 16
        static let cornerRadius: CGFloat = 14
    }

    var body: some View {
        if let content = viewModel.content {
            previewLayout(for: content)
                .frame(width: Metrics.width)
                .themedBackground(.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
                .fixedSize()
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

    @ViewBuilder
    private func paneLayout(for content: SplitTabPreviewContent) -> some View {
        switch content.layout {
        case .vertical:
            sideBySidePanes(content)
        case .horizontal:
            // Keep the current fallback stable while preserving the layout in
            // the content model for the planned stacked split preview.
            sideBySidePanes(content)
        }
    }

    private func sideBySidePanes(_ content: SplitTabPreviewContent) -> some View {
        HStack(alignment: .top, spacing: 0) {
            pane(content.leftPane)
            Divider()
            pane(content.rightPane)
        }
    }

    private func compactPaneLayout(_ content: SplitTabPreviewContent) -> some View {
        HStack(alignment: .top, spacing: 0) {
            compactPane(content.leftPane)
            Divider()
            compactPane(content.rightPane)
        }
    }

    private func pane(_ content: SplitTabPreviewPaneContent) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.primary.opacity(0.04))
                if let image = content.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.imageHeight)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !content.url.isEmpty {
                    Text(displayURL(content.url))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func compactPane(_ content: SplitTabPreviewPaneContent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !content.url.isEmpty {
                Text(content.url)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func displayURL(_ rawValue: String) -> String {
        guard let host = URL(string: rawValue)?.host, !host.isEmpty else { return rawValue }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
              resolver.isEligible(target, in: browserState) else {
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
              resolver.isEligible(target, in: browserState) else {
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
            && resolver.isEligible(target, in: browserState)
        onEligibilityChanged?(isEligible)
        return isEligible
    }

    private func subscribeToPaneTabs() {
        paneCancellables.removeAll()
        guard let target, let browserState else { return }
        for tab in resolver.paneTabs(for: target, in: browserState) {
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
