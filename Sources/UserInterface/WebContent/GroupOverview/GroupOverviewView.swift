// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

private enum GroupOverviewCardMetrics {
    static let previewAspectRatio: CGFloat = 16.0 / 10.0
    static let footerHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 10
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 320
    static let horizontalPadding: CGFloat = 24
    static let columnSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 18
}

private struct GroupOverviewCardLayout {
    let width: CGFloat
    let columns: [GridItem]
}

/// One item in the overview grid. A non-pinned split whose every pane is a
/// member of this group and whose panes sit at consecutive strip positions
/// collapses into one `.split` (panes in on-screen order, two to four);
/// everything else is `.tab`. The mirror of the sidebar's merged split item.
enum GroupOverviewItem: Identifiable {
    case tab(Tab)
    case split(panes: [Tab], splitId: String)

    var id: String {
        switch self {
        case .tab(let tab): return "tab:\(tab.guid)"
        case .split(_, let splitId): return "split:\(splitId)"
        }
    }
}

@MainActor
final class GroupOverviewViewModel: ObservableObject {
    @Published private(set) var members: [Tab] = []
    @Published private(set) var items: [GroupOverviewItem] = []
    @Published private(set) var title: String = ""
    @Published private(set) var rawTitle: String = ""
    @Published private(set) var color: GroupColor = .grey

    private weak var browserState: BrowserState?
    private let groupToken: String
    private var cancellables = Set<AnyCancellable>()
    private var groupChangeCancellables: [String: AnyCancellable] = [:]
    private var tabChangeCancellables: [Int: Set<AnyCancellable>] = [:]
    private var snapshotImages: [Int: NSImage] = [:]

    init(browserState: BrowserState, groupToken: String) {
        self.browserState = browserState
        self.groupToken = groupToken
        refresh()

        browserState.$normalTabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        browserState.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                guard let self else { return }
                WebContentGroupInfo.reconcileSubscriptions(
                    groups: groups,
                    cancellables: &self.groupChangeCancellables
                ) { [weak self] _ in
                    self?.refresh()
                }
                self.refresh()
            }
            .store(in: &cancellables)

        // A split forming / dissolving among adjacent group members can
        // happen without `normalTabs` reordering, so subscribe to splits
        // directly to fold them into combined cards.
        browserState.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let browserState else {
            members = []
            items = []
            title = NSLocalizedString("browser.tabGroupOverview.header.missingBrowserStateTitle", value: "Tab Group", comment: "Tab group overview - Fallback title when browser state is unavailable")
            rawTitle = ""
            color = .grey
            snapshotImages.removeAll()
            clearTabSubscriptions()
            return
        }
        let currentMembers = browserState.normalTabs.filter { $0.groupToken == groupToken }
        let group = browserState.groups[groupToken]
        reconcileTabSubscriptions(for: currentMembers)
        rebuildSnapshotImages(for: currentMembers)
        members = currentMembers
        items = Self.composeItems(members: currentMembers, browserState: browserState)
        color = group?.color ?? .grey
        rawTitle = group?.title ?? ""
        title = group?.displayTitle(memberCount: currentMembers.count)
            ?? NSLocalizedString("browser.tabGroupOverview.header.missingMetadataTitle", value: "Tab Group", comment: "Tab group overview - Fallback title when group metadata is unavailable")
    }

    /// Fold each non-pinned split whose every pane is a member of this group
    /// at consecutive positions into a single `.split` item, panes in member
    /// order. Other tabs surface as `.tab`. Mirrors
    /// `TabSectionController.buildItems` for the outer list and
    /// `TabGroupCellView.applyMembers` for the in-group inner table.
    private static func composeItems(members: [Tab], browserState: BrowserState) -> [GroupOverviewItem] {
        var result: [GroupOverviewItem] = []
        var consumed = Set<Int>()
        for tab in members {
            if consumed.contains(tab.guid) { continue }
            if let group = browserState.splitGroup(forTabId: tab.guid),
               !group.isPinned,
               let panes = contiguousPanes(of: group, in: members) {
                result.append(.split(panes: panes, splitId: group.id))
                consumed.formUnion(panes.map(\.guid))
                continue
            }
            result.append(.tab(tab))
            consumed.insert(tab.guid)
        }
        return result
    }

    /// The split's panes in `members` order when every pane is a member and
    /// their positions form one unbroken run; nil otherwise, so a split with
    /// a pane outside the group (or a tab between its panes) renders as
    /// separate cards.
    private static func contiguousPanes(of group: SplitGroup, in members: [Tab]) -> [Tab]? {
        var indices: [Int] = []
        for tabId in group.tabIds {
            guard let index = members.firstIndex(where: { $0.guid == tabId }) else { return nil }
            indices.append(index)
        }
        let sorted = indices.sorted()
        guard let first = sorted.first, sorted == Array(first ..< first + sorted.count) else { return nil }
        return sorted.map { members[$0] }
    }

    func snapshotImage(for tab: Tab) -> NSImage? {
        snapshotImages[tab.guid]
    }

    func updateGroupTitle(_ title: String) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let browserState,
              let group = browserState.groups[groupToken],
              group.title != normalizedTitle else { return }
        AppLogDebug(
            "[TAB_GROUPS] overview updateTitle windowId=\(browserState.windowId) " +
            "token=\(groupToken) title='\(normalizedTitle)'"
        )
        ChromiumLauncher.sharedInstance().bridge?.updateTabGroupTitle(
            withWindowId: Int64(browserState.windowId),
            tokenHex: groupToken,
            title: normalizedTitle
        )
    }

    func updateGroupColor(_ color: GroupColor) {
        guard let browserState,
              let group = browserState.groups[groupToken],
              group.color != color else { return }
        AppLogDebug(
            "[TAB_GROUPS] overview updateColor windowId=\(browserState.windowId) " +
            "token=\(groupToken) color=\(color.rawValue)"
        )
        ChromiumLauncher.sharedInstance().bridge?.updateTabGroupColor(
            withWindowId: Int64(browserState.windowId),
            tokenHex: groupToken,
            color: color.rawValue
        )
    }

    private func rebuildSnapshotImages(for currentMembers: [Tab]) {
        let desiredIds = Set(currentMembers.map(\.guid))
        snapshotImages = snapshotImages.filter { desiredIds.contains($0.key) }
        for tab in currentMembers {
            snapshotImages[tab.guid] = makeSnapshotImage(for: tab)
        }
    }

    private func makeSnapshotImage(for tab: Tab) -> NSImage? {
        // Use Chromium's cached thumbnail for both foreground and background tabs.
        // Live AppKit capture can return a blank image for Chromium's remote surface.
        // FIXME: Fix live capture of Chromium content before restoring it as a fallback.
        if let jpegData = ChromiumLauncher.sharedInstance().bridge?.thumbnail(forTab: Int64(tab.guid)),
           let image = NSImage(data: jpegData) {
            return image
        }
        return placeholderSnapshot(for: tab)
    }

    private func placeholderSnapshot(for tab: Tab) -> NSImage {
        let faviconData = tab.liveFaviconData ?? tab.cachedFaviconData
        let favicon = faviconData.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            ?? NSImage()
        let title = tab.title.isEmpty ? (tab.url ?? "") : tab.title
        return TabDraggingSession.makeTabPlaceholderSnapshot(favicon: favicon, title: title, needBorder: false)
    }

    private func reconcileTabSubscriptions(for currentMembers: [Tab]) {
        let desiredIds = Set(currentMembers.map(\.guid))
        for tabId in Array(tabChangeCancellables.keys) where !desiredIds.contains(tabId) {
            tabChangeCancellables[tabId]?.forEach { $0.cancel() }
            tabChangeCancellables[tabId] = nil
        }

        for tab in currentMembers where tabChangeCancellables[tab.guid] == nil {
            var subscriptions = Set<AnyCancellable>()
            tab.$title
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
            tab.$url
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
            tab.$liveFaviconData
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
            tab.$cachedFaviconData
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
            tab.$groupToken
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
            tabChangeCancellables[tab.guid] = subscriptions
        }
    }

    private func clearTabSubscriptions() {
        tabChangeCancellables.values.forEach { subscriptions in
            subscriptions.forEach { $0.cancel() }
        }
        tabChangeCancellables.removeAll()
    }
}

struct GroupOverviewView: View {
    @ObservedObject var viewModel: GroupOverviewViewModel
    let selectTab: (Tab) -> Void
    let closeTab: (Tab) -> Void
    let createTab: () -> Void
    let closeOverview: () -> Void

    @State private var isEditingGroup = false

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let layout = cardLayout(for: proxy.size.width)
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: GroupOverviewCardMetrics.rowSpacing) {
                        ForEach(viewModel.items) { item in
                            switch item {
                            case .tab(let tab):
                                GroupOverviewTabCard(
                                    tab: tab,
                                    groupColor: viewModel.color,
                                    snapshotImage: viewModel.snapshotImage(for: tab),
                                    cardWidth: layout.width,
                                    selectTab: { selectTab(tab) },
                                    closeTab: { closeTab(tab) }
                                )
                            case .split(let panes, _):
                                GroupOverviewSplitCard(
                                    panes: panes,
                                    groupColor: viewModel.color,
                                    snapshots: panes.map { viewModel.snapshotImage(for: $0) },
                                    cardWidth: layout.width,
                                    selectTab: selectTab,
                                    closeTab: closeTab
                                )
                            }
                        }
                        GroupOverviewNewTabCard(
                            groupColor: viewModel.color,
                            cardWidth: layout.width,
                            action: createTab
                        )
                    }
                    .padding(.horizontal, GroupOverviewCardMetrics.horizontalPadding)
                    .padding(.vertical, 24)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cardLayout(for containerWidth: CGFloat) -> GroupOverviewCardLayout {
        let availableWidth = max(0, containerWidth - GroupOverviewCardMetrics.horizontalPadding * 2)
        let unitWidth = GroupOverviewCardMetrics.minWidth + GroupOverviewCardMetrics.columnSpacing
        let columnCount = max(1, Int((availableWidth + GroupOverviewCardMetrics.columnSpacing) / unitWidth))
        let totalSpacing = CGFloat(columnCount - 1) * GroupOverviewCardMetrics.columnSpacing
        let rawWidth = (availableWidth - totalSpacing) / CGFloat(columnCount)
        let cardWidth = min(GroupOverviewCardMetrics.maxWidth, max(GroupOverviewCardMetrics.minWidth, floor(rawWidth)))
        let columns = Array(
            repeating: GridItem(.fixed(cardWidth), spacing: GroupOverviewCardMetrics.columnSpacing),
            count: columnCount
        )
        return GroupOverviewCardLayout(width: cardWidth, columns: columns)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                isEditingGroup = true
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(nsColor: viewModel.color.nsColor))
                        .frame(width: 10, height: 10)
                    Text(viewModel.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isEditingGroup, arrowEdge: .bottom) {
                GroupOverviewGroupEditorPopover(viewModel: viewModel)
            }
            Spacer()
            GroupOverviewHoverIconButton(
                systemName: "xmark",
                accessibilityLabel: NSLocalizedString("browser.tabGroupOverview.closeButton.accessibilityLabel", value: "Close Group Overview", comment: "Tab group overview - Accessibility label for the button that closes the overview"),
                action: closeOverview
            )
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
    }
}

private struct GroupOverviewTabCard: View {
    let tab: Tab
    let groupColor: GroupColor
    let snapshotImage: NSImage?
    let cardWidth: CGFloat
    let selectTab: () -> Void
    let closeTab: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: selectTab) {
            VStack(alignment: .leading, spacing: 8) {
                GroupOverviewSnapshotView(tab: tab, groupColor: groupColor, snapshotImage: snapshotImage)
                    .frame(width: cardWidth, height: cardWidth / GroupOverviewCardMetrics.previewAspectRatio)
                    .clipped()
                HStack(spacing: 8) {
                    favicon
                    Text(tab.title.isEmpty ? (tab.url ?? "") : tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    GroupOverviewHoverIconButton(
                        systemName: "xmark",
                        accessibilityLabel: NSLocalizedString("browser.tabGroupOverview.tabCard.closeButtonAccessibilityLabel", value: "Close Tab", comment: "Tab group overview - Accessibility label for closing a single-tab card"),
                        size: 24,
                        iconSize: 11,
                        action: closeTab
                    )
                }
                .padding(.horizontal, 10)
                .frame(height: GroupOverviewCardMetrics.footerHeight)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .frame(width: cardWidth)
            .groupOverviewCardChrome(isHovered: isHovered, groupColor: groupColor)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var favicon: some View {
        if let data = tab.cachedFaviconData ?? tab.liveFaviconData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe")
                .frame(width: 16, height: 16)
        }
    }
}

/// Card that represents a non-pinned split as one combined tile in the
/// group overview. The preview area shows every pane's snapshot side by
/// side, equal widths divided by vertical separators; each pane acts as its
/// own click target (mirrors the sidebar merged cell). Two to four panes.
private struct GroupOverviewSplitCard: View {
    let panes: [Tab]
    let groupColor: GroupColor
    /// One entry per pane, in `panes` order.
    let snapshots: [NSImage?]
    let cardWidth: CGFloat
    let selectTab: (Tab) -> Void
    let closeTab: (Tab) -> Void

    @State private var isHovered = false

    /// Below this pane width the footer drops the title and keeps only the
    /// favicon and close button, so four panes still fit a narrow card.
    private static let titledFooterMinimumPaneWidth: CGFloat = 90

    var body: some View {
        let previewHeight = cardWidth / GroupOverviewCardMetrics.previewAspectRatio
        let paneCount = max(1, panes.count)
        let paneWidth = (cardWidth - CGFloat(paneCount - 1)) / CGFloat(paneCount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.guid) { index, tab in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.65))
                            .frame(width: 1, height: previewHeight)
                    }
                    Button(action: { selectTab(tab) }) {
                        GroupOverviewSnapshotView(
                            tab: tab,
                            groupColor: groupColor,
                            snapshotImage: index < snapshots.count ? snapshots[index] : nil
                        )
                        .frame(width: paneWidth, height: previewHeight)
                        .clipped()
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: cardWidth, height: previewHeight)
            .clipped()

            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.guid) { index, tab in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.65))
                            .frame(width: 1, height: GroupOverviewCardMetrics.footerHeight - 12)
                    }
                    splitFooterPane(
                        tab: tab,
                        showsTitle: paneWidth >= Self.titledFooterMinimumPaneWidth,
                        select: { selectTab(tab) },
                        close: { closeTab(tab) }
                    )
                }
            }
            .frame(height: GroupOverviewCardMetrics.footerHeight)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: cardWidth)
        .groupOverviewCardChrome(isHovered: isHovered, groupColor: groupColor)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private func splitFooterPane(tab: Tab,
                                 showsTitle: Bool,
                                 select: @escaping () -> Void,
                                 close: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(spacing: 6) {
                favicon(for: tab)
                if showsTitle {
                    Text(tab.title.isEmpty ? (tab.url ?? "") : tab.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                GroupOverviewHoverIconButton(
                    systemName: "xmark",
                    accessibilityLabel: NSLocalizedString("browser.tabGroupOverview.splitCard.closePaneButtonAccessibilityLabel", value: "Close Tab", comment: "Tab group overview - Accessibility label for closing one pane of a split card"),
                    size: 20,
                    iconSize: 10,
                    action: close
                )
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func favicon(for tab: Tab) -> some View {
        if let data = tab.cachedFaviconData ?? tab.liveFaviconData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "globe")
                .frame(width: 14, height: 14)
        }
    }
}

private struct GroupOverviewSnapshotView: View {
    let tab: Tab
    let groupColor: GroupColor
    let snapshotImage: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: groupColor.nsColor.withAlphaComponent(0.12))
            if let image = snapshotImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 26))
                    Text(tab.url ?? "")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .padding(16)
            }
        }
        .clipped()
    }
}

private struct GroupOverviewNewTabCard: View {
    let groupColor: GroupColor
    let cardWidth: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack {
                    Color(nsColor: groupColor.nsColor.withAlphaComponent(0.08))
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .regular))
                }
                .frame(width: cardWidth, height: cardWidth / GroupOverviewCardMetrics.previewAspectRatio)
                .clipped()

                HStack {
                    Spacer()
                    Text(NSLocalizedString("browser.tabGroupOverview.newTabCardTitle", value: "New Tab", comment: "Title for the group overview card that creates a new tab in the selected group"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .frame(height: GroupOverviewCardMetrics.footerHeight)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .frame(width: cardWidth)
            .groupOverviewCardChrome(isHovered: isHovered, groupColor: groupColor)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct GroupOverviewGroupEditorPopover: View {
    @ObservedObject var viewModel: GroupOverviewViewModel

    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            TextField(
                NSLocalizedString("browser.tabGroupOverview.nameField.placeholder", value: "Name group", comment: "Tab group overview editor - Placeholder for the editable group title field"),
                text: $draftTitle
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .frame(width: 228, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: viewModel.color.nsColor), lineWidth: 2)
            )
            .onSubmit(commitTitle)

            HStack(spacing: 8) {
                ForEach(GroupColor.allCases, id: \.self) { color in
                    GroupOverviewColorButton(
                        color: color,
                        isSelected: color == viewModel.color
                    ) {
                        viewModel.updateGroupColor(color)
                    }
                }
            }
        }
        .padding(12)
        .onAppear {
            draftTitle = viewModel.rawTitle
        }
        .onDisappear(perform: commitTitle)
    }

    private func commitTitle() {
        viewModel.updateGroupTitle(draftTitle)
    }
}

private struct GroupOverviewColorButton: View {
    let color: GroupColor
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .stroke(Color(nsColor: color.nsColor), lineWidth: isSelected ? 2 : 0)
                        .frame(width: 22, height: 22)
                )
                .scaleEffect(isHovered ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color.localizedName))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct GroupOverviewHoverIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 13
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered
                              ? Color(nsColor: .labelColor).opacity(0.10)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct GroupOverviewCardChrome: ViewModifier {
    let isHovered: Bool
    let groupColor: GroupColor

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: GroupOverviewCardMetrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GroupOverviewCardMetrics.cornerRadius, style: .continuous)
                    .stroke(
                        isHovered
                            ? Color(nsColor: groupColor.nsColor)
                            : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.14 : 0.08),
                    radius: isHovered ? 10 : 6,
                    x: 0,
                    y: isHovered ? 5 : 3)
            .scaleEffect(isHovered ? 1.01 : 1)
    }
}

private extension View {
    func groupOverviewCardChrome(isHovered: Bool, groupColor: GroupColor) -> some View {
        modifier(GroupOverviewCardChrome(isHovered: isHovered, groupColor: groupColor))
    }
}
