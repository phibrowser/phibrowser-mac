// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import Combine

/// The header's callbacks and context, handed to every toolbar item.
struct ToolbarItemActions {
    var browserState: BrowserState?
    var currentTab: Tab?

    var onSidebarTap: () -> Void
    var onBackTap: () -> Void
    var onForwardTap: () -> Void
    var onRefreshTap: () -> Void
    var onStopLoadingTap: () -> Void
    var onChatTap: () -> Void
    var onFeedbackTap: () -> Void
    var onMemoryTap: () -> Void
    var onDownloadTap: () -> Void
    /// Opens Customize Toolbar; the Site Menu ends with it.
    var onCustomizeToolbar: () -> Void = {}
    var onSidebarAnchorResolved: ((NSView?) -> Void)?
    var onChatAnchorResolved: ((NSView?) -> Void)?

    var downloadViewModel: DownloadButtonViewModel
    var isExtensionPopoverShown: Binding<Bool>
    /// Pinned extensions whose action shows on the current tab, in presented order.
    var visibleExtensions: [Extension]
    /// Set only while the toolbar is being customized: items become drag
    /// sources and zones drop targets.
    var customization: ToolbarCustomizationController? = nil
    /// A drag-reorder within a capsule of extensions completed, in its new order.
    var onExtensionsReordered: (([String]) -> Void)? = nil
}

/// What the address bar lends an item drawn inside it.
struct AddressBarItemContext {
    /// False hides the item and keeps its frame. Reader View also shows while it is on.
    var isRevealed: Bool
    /// Reports a site or memories menu opening or closing, so the bar stays highlighted.
    var onMenuShownChange: (Bool) -> Void
}

/// The items drawn only because the toolbar is being customized, such as
/// Reader View on a page without it or Site Memories without memories. The Minimal
/// address keeps its text where it was by leaving them out of its centering.
struct ToolbarCustomizeOnlyItemsKey: PreferenceKey {
    static let defaultValue: Set<ToolbarItemID> = []

    static func reduce(value: inout Set<ToolbarItemID>, nextValue: () -> Set<ToolbarItemID>) {
        value.formUnion(nextValue())
    }
}

/// One toolbar item: today's control for it, or nothing while its condition is false.
struct ToolbarItemView: View {
    let item: ToolbarItemID
    let actions: ToolbarItemActions
    @ObservedObject var state: WebContentHeaderState
    /// Set when the item sits in the address bar; side zones always show their items.
    var addressBar: AddressBarItemContext? = nil

    @AppStorage(PhiPreferences.GeneralSettings.sidebarPositionKey)
    private var sidebarPosition = SidebarPosition.left.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let visibleExtensionIDs = actions.visibleExtensions.map(\.id)
        if Self.isShown(item, state: state, visibleExtensionIDs: visibleExtensionIDs) {
            let isCustomizeOnly = state.isCustomizing
                && !Self.isShownWhileBrowsing(item, state: state, visibleExtensionIDs: visibleExtensionIDs)
            shownControl
                // Buttons do nothing while customizing: the drag source takes
                // pointer presses, and this keeps assistive technology from
                // pressing what is underneath.
                .accessibilityHidden(state.isCustomizing)
                // Reader View and Site Memories add themselves when the page
                // does not offer them.
                .transformPreference(ToolbarCustomizeOnlyItemsKey.self) { items in
                    if isCustomizeOnly { items.insert(item) }
                }
        }
    }

    @ViewBuilder
    private var shownControl: some View {
        if item == .readerView {
            // Reader View fades itself: it stays visible while it is on.
            control
        } else {
            control
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)
                .animation(.easeInOut(duration: 0.15), value: isRevealed)
        }
    }

    private var isRevealed: Bool {
        addressBar?.isRevealed ?? true
    }

    private var onMenuShownChange: (Bool) -> Void {
        addressBar?.onMenuShownChange ?? { _ in }
    }

    /// Whether the item shows now (`isShownWhileBrowsing` outside customizing).
    /// While customizing, every placed item shows that exists in this window,
    /// except Toggle Sidebar: it shows only where this view shows it anyway
    /// (Balanced with the sidebar collapsed), so customizing does not push
    /// the rest of Left aside. Downloads, Memory and Feedback follow the layout
    /// too (`layoutShowsBottomBarItem`), so one the sidebar's bottom bar keeps
    /// is not drawn while customizing either.
    /// `arrangement` stands in for the stored one in the layout rule, which
    /// only the sheet's default row uses.
    static func isShown(_ item: ToolbarItemID, state: WebContentHeaderState, visibleExtensionIDs: [String], arrangement: ToolbarArrangement? = nil) -> Bool {
        if state.isCustomizing, !state.isInPlaceholderMode {
            switch item {
            case .sidebarToggle: return state.layoutShowsSidebarToggle(in: arrangement)
            case .extensionAction(let id): return visibleExtensionIDs.contains(id)
            case .memory: return state.isPhiAIAvailable && state.layoutShowsBottomBarItem(item, in: arrangement)
            case .chat, .siteMemories: return state.isPhiAIAvailable
            case .downloads: return state.layoutShowsBottomBarItem(item, in: arrangement)
            case .feedback: return !state.isGuest && state.layoutShowsBottomBarItem(item, in: arrangement)
            default: return true
            }
        }
        return isShownWhileBrowsing(item, state: state, visibleExtensionIDs: visibleExtensionIDs, arrangement: arrangement)
    }

    /// Today's show conditions outside customizing. Reader View and Site
    /// Memories also hide while the page does not offer them. Downloads,
    /// Memory and Feedback also follow the layout
    /// (`WebContentHeaderState.layoutShowsBottomBarItem`).
    static func isShownWhileBrowsing(_ item: ToolbarItemID, state: WebContentHeaderState, visibleExtensionIDs: [String], arrangement: ToolbarArrangement? = nil) -> Bool {
        switch item {
        case .sidebarToggle: return state.layoutShowsSidebarToggle(in: arrangement)
        case .back, .forward, .reload: return state.showNavigationButtons
        case .extensionsButton: return !state.isInPlaceholderMode
        case .extensionAction(let id): return !state.isInPlaceholderMode && visibleExtensionIDs.contains(id)
        case .downloads: return state.showDownloadButton && state.layoutShowsBottomBarItem(item, in: arrangement)
        case .memory: return state.showMemoryButton && state.layoutShowsBottomBarItem(item, in: arrangement)
        case .feedback: return state.showFeedbackButton && state.layoutShowsBottomBarItem(item, in: arrangement)
        case .chat: return state.showChatButton
        case .readerView, .siteMemories, .copyURL, .siteMenu: return !state.isInPlaceholderMode
        }
    }

    /// The item's width outside the overflow-managed Right zone, without spacing.
    static func naturalWidth(of item: ToolbarItemID) -> CGFloat {
        switch item {
        case .chat: return ChatButton.preferredContentWidth
        case .extensionAction: return HeaderExtensionLayout.buttonSize + HeaderExtensionLayout.itemSpacing
        default: return HeaderExtensionLayout.buttonSize
        }
    }

    @ViewBuilder
    private var control: some View {
        switch item {
        case .sidebarToggle:
            NavigationButton(
                systemName: sidebarPosition == SidebarPosition.right.rawValue && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional ? "sidebar.right" : "sidebar.left",
                accessibilityLabel: NSLocalizedString("browser.webContentHeader.sidebarButton.accessibilityLabel", value: "Toggle Sidebar", comment: "Web content header - Accessibility description for sidebar toggle button"),
                onAnchorResolved: actions.onSidebarAnchorResolved,
                action: actions.onSidebarTap
            )
        case .back:
            NavigationButton(
                systemName: "chevron.left",
                isEnabled: state.canGoBack,
                accessibilityLabel: NSLocalizedString("browser.webContentHeader.backButton.accessibilityLabel", value: "Back", comment: "Web content header - Accessibility description for back navigation button"),
                action: actions.onBackTap
            )
        case .forward:
            NavigationButton(
                systemName: "chevron.right",
                isEnabled: state.canGoForward,
                accessibilityLabel: NSLocalizedString("browser.webContentHeader.forwardButton.accessibilityLabel", value: "Forward", comment: "Web content header - Accessibility description for forward navigation button"),
                action: actions.onForwardTap
            )
        case .reload:
            RefreshStopNavigationButton(
                isProgressVisible: state.isProgressVisible,
                onRefreshTap: actions.onRefreshTap,
                onStopLoadingTap: actions.onStopLoadingTap
            )
        case .extensionsButton:
            HeaderExtensionMenuButton(
                extensionManager: actions.browserState?.extensionManager,
                browserState: actions.browserState,
                isPopoverShown: actions.isExtensionPopoverShown
            )
        case .extensionAction(let id):
            HeaderExtensionContainer(
                pinnedExtensions: actions.visibleExtensions.filter { $0.id == id },
                menuButton: .none,
                extensionManager: actions.browserState?.extensionManager,
                browserState: actions.browserState,
                isPopoverShown: actions.isExtensionPopoverShown
            )
        case .downloads:
            DownloadButtonView(
                viewModel: actions.downloadViewModel,
                useCircularHoverShape: true,
                onTap: {
                    actions.onDownloadTap()
                    state.isDownloadPopoverShown.toggle()
                }
            )
            .popover(isPresented: $state.isDownloadPopoverShown, arrowEdge: .bottom) {
                HeaderDownloadsPopoverContent(
                    downloadViewModel: actions.downloadViewModel,
                    colorScheme: colorScheme,
                    browserState: actions.browserState,
                    isShown: $state.isDownloadPopoverShown
                )
            }
        case .memory:
            MemoryButton(action: actions.onMemoryTap, useCircularHoverShape: true)
        case .feedback:
            FeedbackButtonSwiftUI(action: actions.onFeedbackTap, useCircularHoverShape: true)
        case .chat:
            ChatButton(
                action: actions.onChatTap,
                contentWidth: ChatButton.preferredContentWidth,
                contentHeight: HeaderTrailingLayout.rowHeight
            )
            .background(chatAnchorBackground)
        case .readerView:
            ReaderButtonView(
                browserState: actions.browserState,
                currentTab: actions.currentTab,
                isRevealed: isRevealed,
                isCustomizing: state.isCustomizing
            )
            // A fresh model per tab follows that tab's reader state.
            .id(actions.currentTab.map(ObjectIdentifier.init))
        case .siteMemories:
            SiteMemoriesButtonView(
                browserState: actions.browserState,
                currentTab: actions.currentTab,
                urlString: actions.currentTab?.url ?? "",
                isCustomizing: state.isCustomizing,
                onMenuShownChange: onMenuShownChange
            )
        case .copyURL:
            CopyURLButtonView(
                browserState: actions.browserState,
                currentTab: actions.currentTab
            )
            .customTooltip {
                CommandShortcutTooltipContent(
                    title: NSLocalizedString("browser.webContentAddressBar.copyURLTooltip", value: "Copy URL", comment: "Copy URL shortcut tooltip title"),
                    command: .PHI_COPY_URL
                )
            }
        case .siteMenu:
            SiteMenuButtonView(
                browserState: actions.browserState,
                currentTab: actions.currentTab,
                arrangement: state.arrangement,
                onCustomize: actions.onCustomizeToolbar,
                onMenuShownChange: onMenuShownChange
            )
        }
    }

    @ViewBuilder
    private var chatAnchorBackground: some View {
        if let onChatAnchorResolved = actions.onChatAnchorResolved {
            HeaderControlAnchorView { view in
                onChatAnchorResolved(view)
            }
        }
    }
}

/// The downloads list shown from the Downloads button or from the overflow menu.
struct HeaderDownloadsPopoverContent: View {
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    /// The header's scheme, read where the popover is presented.
    let colorScheme: ColorScheme
    let browserState: BrowserState?
    @Binding var isShown: Bool

    var body: some View {
        if let manager = downloadViewModel.downloadsManager {
            DownloadsListView(downloadsManager: manager) {
                isShown = false
                guard let owner = browserState?.windowController,
                      let source = owner.window?.contentView else { return }
                owner.showLibrary(from: source, section: .downloads)
            }
                .frame(width: 340, height: 317)
                .preferredColorScheme(colorScheme)
        }
    }
}

// MARK: - Address bar buttons

/// Follows whether the tab offers Reader View and whether the tab is in it.
private final class ReaderButtonModel: ObservableObject {
    /// Mirrors `Tab.isReaderOfferable`: a matching site rule, or Mozilla's
    /// readerability heuristic passing in the live page.
    @Published private(set) var isApplicable: Bool
    /// "In the reader" is the Phi Reader extension's page being shown in
    /// the tab; the extension reports it over the bridge.
    @Published private(set) var isActive: Bool

    init(tab: Tab?) {
        isApplicable = tab?.isReaderOfferable ?? false
        isActive = tab?.extensionReaderActive ?? false
        guard let tab else { return }
        tab.$isReaderOfferable
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$isApplicable)
        tab.$extensionReaderActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$isActive)
    }
}

/// Reader View's button. Hidden with the other address bar buttons, except
/// it stays visible while Reader View is on so the selected state doesn't
/// disappear with the pointer. While customizing it shows on any page.
private struct ReaderButtonView: View {
    let browserState: BrowserState?
    let currentTab: Tab?
    let isRevealed: Bool
    let isCustomizing: Bool

    @StateObject private var model: ReaderButtonModel
    @State private var isButtonHovering = false
    @State private var anchorView: NSView?
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    init(browserState: BrowserState?, currentTab: Tab?, isRevealed: Bool, isCustomizing: Bool) {
        self.browserState = browserState
        self.currentTab = currentTab
        self.isRevealed = isRevealed
        self.isCustomizing = isCustomizing
        _model = StateObject(wrappedValue: ReaderButtonModel(tab: currentTab))
    }

    var body: some View {
        if model.isApplicable || isCustomizing {
            Button {
                anchorView?.window?.customTooltipController.dismissAll()
                guard let tab = currentTab else { return }
                browserState?.toggleReaderView(for: tab, from: .addressBar)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(.sidebarTabHovered))
                        .frame(width: 24, height: 24)
                        .opacity((isButtonHovering || model.isActive) ? 1 : 0)

                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            ThemedColor.textPrimary.swiftUIColor(theme: theme,
                                                                 appearance: appearance))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .background(HeaderControlAnchorView { anchorView = $0 })
            .onHover { hovering in
                isButtonHovering = hovering
            }
            .opacity((isRevealed || model.isActive) ? 1 : 0)
            .allowsHitTesting(isRevealed || model.isActive)
            .animation(.easeInOut(duration: 0.15), value: isRevealed)
            .animation(.easeInOut(duration: 0.15), value: isButtonHovering)
            .animation(.easeInOut(duration: 0.15), value: model.isActive)
            .customTooltip {
                CommandShortcutTooltipContent(
                    title: NSLocalizedString("browser.webContentAddressBar.readerViewTooltip", value: "Reader View", comment: "Reader View shortcut tooltip title in the address bar"),
                    command: .PHI_TOGGLE_READER
                )
            }
            .transformPreference(ToolbarCustomizeOnlyItemsKey.self) { items in
                if !model.isApplicable { items.insert(.readerView) }
            }
        }
    }
}

/// Opens the memories menu for the current site, when the site can have
/// memories. While customizing it shows on any page.
private struct SiteMemoriesButtonView: View {
    let browserState: BrowserState?
    let currentTab: Tab?
    /// Passed by value so a new page re-checks whether the site can have memories.
    let urlString: String
    let isCustomizing: Bool
    let onMenuShownChange: (Bool) -> Void

    @State private var isButtonHovering = false
    @State private var isMenuShown = false
    @State private var anchorView: NSView?
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private var siteHasMemories: Bool {
        guard let browserState else { return false }
        return SiteMemoryMenuActions(
            urlString: urlString, profileID: browserState.profileId,
            isIncognito: browserState.isIncognito,
            isPhiAIEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue(),
            service: nil
        ) != nil
    }

    var body: some View {
        if isCustomizing || siteHasMemories {
            let title = NSLocalizedString("browser.webContentAddressBar.manageSiteMemoriesTooltip", value: "Manage Site Memories", comment: "Address bar - Button tooltip for opening memory controls for the current website")
            Button {
                anchorView?.window?.customTooltipController.dismissAll()
                guard let browserState else { return }
                WebContentAddressBarMenuPresenter.presentMemoryMenu(
                    browserState: browserState,
                    currentTab: currentTab,
                    anchorView: anchorView
                ) { isPresented in
                    isMenuShown = isPresented
                    onMenuShownChange(isPresented)
                }
            } label: {
                Image("memory-manage-icon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(.sidebarTabHovered))
                        .opacity(isButtonHovering || isMenuShown ? 1 : 0))
            }
            .buttonStyle(.plain)
            .background(AddressBarAnchorView { anchorView = $0 }.allowsHitTesting(false))
            .onHover { isButtonHovering = $0 }
            .accessibilityLabel(title)
            .transformPreference(ToolbarCustomizeOnlyItemsKey.self) { items in
                if !siteHasMemories { items.insert(.siteMemories) }
            }
        }
    }
}

private struct CopyURLButtonView: View {
    let browserState: BrowserState?
    let currentTab: Tab?

    @State private var showCopyConfirmation = false
    @State private var isButtonHovering = false
    @State private var anchorView: NSView?
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    /// The page in front of this bar: a presented peek's, not the opener
    /// hidden behind the panel, so the button agrees with ⌘⇧C (`PHI_COPY_URL`).
    private var copyURLString: String? {
        browserState?.addressBarCopyURLString(for: currentTab)
            ?? BrowserState.copyURLString(forAddressBarShowing: currentTab)
    }

    var body: some View {
        Button {
            anchorView?.window?.customTooltipController.dismissAll()
            guard let urlString = copyURLString else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urlString, forType: .string)
            showCopyConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showCopyConfirmation = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.sidebarTabHovered))
                    .frame(width: 24, height: 24)
                    .opacity(isButtonHovering ? 1 : 0)

                Image(systemName: showCopyConfirmation ? "checkmark" : "link")
                    .contentTransition(.symbolEffect(.replace, options: .speed(3)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .background(HeaderControlAnchorView { anchorView = $0 })
        .onHover { hovering in
            isButtonHovering = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isButtonHovering)
    }
}

/// The site menu "…".
private struct SiteMenuButtonView: View {
    let browserState: BrowserState?
    let currentTab: Tab?
    let arrangement: ToolbarArrangement
    let onCustomize: () -> Void
    let onMenuShownChange: (Bool) -> Void

    @State private var isMenuShown = false
    @State private var anchorView: NSView?
    @StateObject private var lottieState = LottieAnimationViewState()

    var body: some View {
        let config = LottieAnimationViewConfig(
            animationName: "extension-button",
            size: CGSize(width: 22, height: 22),
            hoverBackgroundColor: Color(.sidebarTabHovered),
            cornerRadius: 999,
            animationTrigger: .onHoverEnter,
            themedTintColor: .textPrimary,
            reverseOnHoverExit: true
        )

        ZStack {
            Circle()
                .fill(Color(.sidebarTabHovered))
                .frame(width: 24, height: 24)
                .opacity(isMenuShown ? 1 : 0)

            LottieAnimationView(config: config, state: lottieState) {
                WebContentAddressBarMenuPresenter.present(
                    browserState: browserState,
                    currentTab: currentTab,
                    anchorView: anchorView,
                    showsSiteMemoriesEntry: WebContentAddressBarMenuPresenter.showsSiteMemoriesEntry(
                        arrangement: arrangement,
                        browserState: browserState,
                        currentTab: currentTab
                    ),
                    onCustomize: onCustomize
                ) { isPresented in
                    isMenuShown = isPresented
                    onMenuShownChange(isPresented)
                }
            }
            .background(
                AddressBarAnchorView { view in
                    anchorView = view
                }
                .allowsHitTesting(false)
            )
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Zone layout

/// A piece of a drawn zone: a single item, a run of extensions sharing one
/// capsule (with the extensions button when it sits next to them), or the
/// overflow "…".
enum ToolbarZoneSegment: Hashable, Identifiable {
    case item(ToolbarItemID)
    /// `group` counts the zone's capsules, so a capsule keeps its identity
    /// while its icons fold or reorder (its reorder drag lives in it).
    case extensions(ids: [String], menuButton: ExtensionMenuButtonPlacement, group: Int)
    case overflow

    var id: String {
        switch self {
        case .item(let item): return item.rawValue
        case .extensions(_, _, let group): return "extensions#\(group)"
        case .overflow: return "overflow"
        }
    }

    /// Groups the drawn items of a zone. `overflowAnchor` is the index in
    /// `items` the "…" takes; it moves past a capsule rather than split it.
    static func segments(_ items: [ToolbarItemID], overflowAnchor: Int?) -> [ToolbarZoneSegment] {
        var segments: [(start: Int, segment: ToolbarZoneSegment)] = []
        var group = 0
        var index = 0
        while index < items.count {
            guard case .extensionAction = items[index] else {
                segments.append((index, .item(items[index])))
                index += 1
                continue
            }
            var start = index
            var ids: [String] = []
            while index < items.count, case .extensionAction(let id) = items[index] {
                ids.append(id)
                index += 1
            }
            var menuButton = ExtensionMenuButtonPlacement.none
            if let last = segments.last, last.segment == .item(.extensionsButton) {
                segments.removeLast()
                start = last.start
                menuButton = .leading
            } else if index < items.count, items[index] == .extensionsButton {
                menuButton = .trailing
                index += 1
            }
            segments.append((start, .extensions(ids: ids, menuButton: menuButton, group: group)))
            group += 1
        }

        var result = segments.map(\.segment)
        if let overflowAnchor {
            let position = segments.firstIndex { $0.start >= overflowAnchor } ?? segments.count
            result.insert(.overflow, at: position)
        }
        return result
    }

    /// The items the segment draws, in drawing order; the "…" draws none.
    var items: [ToolbarItemID] {
        switch self {
        case .item(let item):
            return [item]
        case .extensions(let ids, let menuButton, _):
            let icons = ids.map(ToolbarItemID.extensionAction)
            switch menuButton {
            case .none: return icons
            case .leading: return [.extensionsButton] + icons
            case .trailing: return icons + [.extensionsButton]
            }
        case .overflow:
            return []
        }
    }

    /// Puts each run of adjacent extensions in the presented pin order. The
    /// header applies it only while a drag-reorder preview is up, so the
    /// preview shows live; otherwise the arrangement's order is drawn.
    static func orderingExtensionRuns(_ items: [ToolbarItemID], by order: [String]) -> [ToolbarItemID] {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result = items
        var index = 0
        while index < result.count {
            guard case .extensionAction = result[index] else {
                index += 1
                continue
            }
            let start = index
            while index < result.count, case .extensionAction = result[index] { index += 1 }
            let run = result[start..<index].sorted { lhs, rhs in
                guard case .extensionAction(let l) = lhs, case .extensionAction(let r) = rhs else { return false }
                return (rank[l] ?? Int.max) < (rank[r] ?? Int.max)
            }
            result.replaceSubrange(start..<index, with: run)
        }
        return result
    }
}

/// Draws a zone's segments in a row; `overflow` draws the "…". While
/// customizing, a capsule's items are drawn at the capsule's own spacing, so
/// nothing moves, and each is dragged on its own.
struct ToolbarZoneRow<Overflow: View>: View {
    let segments: [ToolbarZoneSegment]
    let spacing: CGFloat
    /// The zone drawn, which its items are dragged from while customizing.
    let zone: ToolbarZone
    let actions: ToolbarItemActions
    @ObservedObject var state: WebContentHeaderState
    @ViewBuilder let overflow: () -> Overflow

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(segments) { segment in
                switch segment {
                case .item(let item):
                    ToolbarItemView(item: item, actions: actions, state: state)
                        .toolbarCustomizationSource(item, in: zone, customization: actions.customization)
                case .extensions where actions.customization != nil:
                    HStack(spacing: HeaderExtensionLayout.itemSpacing) {
                        ForEach(segment.items, id: \.self) { item in
                            ToolbarItemView(item: item, actions: actions, state: state)
                                .toolbarCustomizationSource(item, in: zone, customization: actions.customization)
                        }
                    }
                    .frame(height: HeaderTrailingLayout.rowHeight)
                case .extensions(let ids, let menuButton, _):
                    HeaderExtensionContainer(
                        pinnedExtensions: ids.compactMap { id in actions.visibleExtensions.first { $0.id == id } },
                        menuButton: menuButton,
                        extensionManager: actions.browserState?.extensionManager,
                        browserState: actions.browserState,
                        isPopoverShown: actions.isExtensionPopoverShown,
                        onReorder: actions.onExtensionsReordered
                    )
                case .overflow:
                    overflow()
                }
            }
        }
    }
}

extension ToolbarZoneRow where Overflow == EmptyView {
    init(segments: [ToolbarZoneSegment], spacing: CGFloat, zone: ToolbarZone, actions: ToolbarItemActions, state: WebContentHeaderState) {
        self.init(segments: segments, spacing: spacing, zone: zone, actions: actions, state: state) { EmptyView() }
    }
}
