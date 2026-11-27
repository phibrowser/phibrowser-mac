// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

struct WebContentHeaderView: View {
    @ObservedObject var state: WebContentHeaderState
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    var currentTab: Tab?
    var browserState: BrowserState?

    let onSidebarTap: () -> Void
    let onBackTap: () -> Void
    let onForwardTap: () -> Void
    let onRefreshTap: () -> Void
    let onStopLoadingTap: () -> Void
    let onChatTap: () -> Void
    let onFeedbackTap: () -> Void
    let onMemoryTap: () -> Void
    let onDownloadTap: () -> Void
    let onOpenLocationBar: (NSView?) -> Void
    var onAnchorResolved: ((NSView?) -> Void)?
    var onSidebarAnchorResolved: ((NSView?) -> Void)?
    var onChatAnchorResolved: ((NSView?) -> Void)?
    /// Called whenever the Minimal address bar lays out, so the header can
    /// re-read the window center.
    var onMinimalAddressLayout: (() -> Void)?
    /// Opens Customize Toolbar from the Site Menu.
    var onCustomizeToolbar: () -> Void
    /// Applies Customize Toolbar's drags and direct extension reorders.
    var customization: ToolbarCustomizationController?

    /// The header's own coordinates: the root fills the header's hosting view.
    static let coordinateSpaceName = "webContentHeader"

    @State private var extensionsModel: WebContentHeaderExtensionsModel
    @State private var isExtensionPopoverShown = false
    /// The header row's measured width, kept outside SwiftUI state: a
    /// sidebar divider drag changes it every frame, and re-rendering the
    /// header (address bar included) at each width cost a fifth of every
    /// drag frame. `trailingFit` is what re-renders, when a width change
    /// moves a trailing item in or out.
    @State private var measuredWidth = MeasuredHeaderWidth()
    @State private var trailingFit: ToolbarOverflow.Fit?
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    init(
        state: WebContentHeaderState,
        downloadViewModel: DownloadButtonViewModel,
        currentTab: Tab?,
        browserState: BrowserState?,
        onSidebarTap: @escaping () -> Void,
        onBackTap: @escaping () -> Void,
        onForwardTap: @escaping () -> Void,
        onRefreshTap: @escaping () -> Void,
        onStopLoadingTap: @escaping () -> Void,
        onChatTap: @escaping () -> Void,
        onFeedbackTap: @escaping () -> Void,
        onMemoryTap: @escaping () -> Void = {},
        onDownloadTap: @escaping () -> Void = {},
        onOpenLocationBar: @escaping (NSView?) -> Void,
        onAnchorResolved: ((NSView?) -> Void)? = nil,
        onSidebarAnchorResolved: ((NSView?) -> Void)? = nil,
        onChatAnchorResolved: ((NSView?) -> Void)? = nil,
        onMinimalAddressLayout: (() -> Void)? = nil,
        onCustomizeToolbar: @escaping () -> Void = {},
        customization: ToolbarCustomizationController? = nil
    ) {
        self.state = state
        self.downloadViewModel = downloadViewModel
        self.currentTab = currentTab
        self.browserState = browserState
        self.onSidebarTap = onSidebarTap
        self.onBackTap = onBackTap
        self.onForwardTap = onForwardTap
        self.onRefreshTap = onRefreshTap
        self.onStopLoadingTap = onStopLoadingTap
        self.onChatTap = onChatTap
        self.onFeedbackTap = onFeedbackTap
        self.onMemoryTap = onMemoryTap
        self.onDownloadTap = onDownloadTap
        self.onOpenLocationBar = onOpenLocationBar
        self.onAnchorResolved = onAnchorResolved
        self.onSidebarAnchorResolved = onSidebarAnchorResolved
        self.onChatAnchorResolved = onChatAnchorResolved
        self.onMinimalAddressLayout = onMinimalAddressLayout
        self.onCustomizeToolbar = onCustomizeToolbar
        self.customization = customization
        _extensionsModel = State(wrappedValue: WebContentHeaderExtensionsModel(browserState: browserState))
    }

    var body: some View {
        _ = trailingFit
        return VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 0) {
                let actions = itemActions
                // Without the item or address bar being dragged from it.
                let layout = state.layoutArrangement
                let left = leftItems
                ToolbarZoneRow(
                    segments: ToolbarZoneSegment.segments(left, overflowAnchor: nil),
                    spacing: Self.leftZoneSpacing,
                    zone: .left,
                    actions: actions,
                    state: state
                )
                // An empty zone reserves its drop target's width while customizing.
                .frame(width: ToolbarCustomizationLayout.sideZoneReserve(isEmpty: left.isEmpty, isCustomizing: actions.customization != nil))
                .toolbarCustomizationZone(.left, isEmpty: left.isEmpty, customization: actions.customization)
                .padding(.leading, leftZoneLeadingPadding)

                // Without it, Left and Right sit at their edges with empty space between.
                if state.drawsAddressBar {
                    WebContentAddressBarView(
                        browserState: browserState,
                        currentTab: currentTab,
                        showBackgroundWhenInactive: false,
                        loadingProgress: state.loadingProgress,
                        isLoading: state.isLoading,
                        isProgressVisible: state.isProgressVisible,
                        backgroundColor: state.pageBackgroundColor.map { Color(nsColor: $0) },
                        allowsWindowDrag: state.allowsAddressBarWindowDrag,
                        leading: layout.placements(in: .addressLeading),
                        trailing: layout.placements(in: .addressTrailing),
                        isCustomizing: state.isCustomizing,
                        isPopoverShown: isAddressBarPopoverShown,
                        itemActions: actions,
                        headerState: state,
                        style: state.arrangement.addressBarStyle,
                        onOpenLocationBar: onOpenLocationBar,
                        onAnchorResolved: onAnchorResolved,
                        onMinimalLayout: onMinimalAddressLayout
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .layoutPriority(1)
                }

                Spacer(minLength: 0)

                HeaderTrailingArea(
                    // While customizing every item shows, so nothing folds.
                    availableWidth: state.isCustomizing ? .greatestFiniteMagnitude : trailingAvailableWidth,
                    items: rightItems,
                    arranged: rightArrangedItems,
                    actions: actions,
                    state: state
                )
                .frame(height: HeaderTrailingLayout.rowHeight)
                .layoutPriority(2)

            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newValue in
                measuredWidth.value = newValue
                let fit = currentTrailingFit
                if fit != trailingFit {
                    trailingFit = fit
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .environment(\.phiAppearance, state.pageAppearance ?? appearance)
        .environment(\.colorScheme, state.pageAppearance.map { $0.isDark ? .dark : .light } ?? colorScheme)
    }

    private var trailingAvailableWidth: CGFloat {
        max(0, measuredWidth.value - leftZoneWidth - addressBarReservedWidth)
    }

    private var currentTrailingFit: ToolbarOverflow.Fit {
        HeaderTrailingArea.fit(items: rightItems, availableWidth: trailingAvailableWidth)
    }

    private static let leftZoneSpacing: CGFloat = 8

    private var leftZoneLeadingPadding: CGFloat {
        state.isInPlaceholderMode ? 8 : 16
    }

    private var leftZoneWidth: CGFloat {
        let items = leftItems
        let itemsWidth = items.reduce(0) { $0 + ToolbarItemView.naturalWidth(of: $1) }
        let spacing = CGFloat(max(items.count - 1, 0)) * Self.leftZoneSpacing
        return leftZoneLeadingPadding + itemsWidth + spacing
    }

    /// Minimum width reserved for the address bar so trailing area doesn't over-expand
    private var addressBarReservedWidth: CGFloat {
        guard state.drawsAddressBar else { return 0 }
        // Both styles draw the address zones.
        let layout = state.layoutArrangement
        let drawn = (layout.placements(in: .addressLeading) + layout.placements(in: .addressTrailing)).map(\.item)
        let visibleExtensionIDs = extensionsModel.visiblePinnedExtensions.map(\.id)
        return Self.addressBarReservedWidth(addressItems: drawn.filter {
            ToolbarItemView.isShown($0, state: state, visibleExtensionIDs: visibleExtensionIDs)
        })
    }

    /// 200pt holds the address with the standard arrangement's buttons in it.
    /// Buttons beyond those widen the reserve by what they add, so the Right
    /// zone folds before the address bar clips them. On Hover buttons count
    /// too: hidden, they keep their frame.
    static func addressBarReservedWidth(addressItems: [ToolbarItemID]) -> CGFloat {
        func width(_ items: [ToolbarItemID]) -> CGFloat {
            items.reduce(0) { $0 + ToolbarItemView.naturalWidth(of: $1) } + WebContentAddressBarView.itemSpacing * CGFloat(max(items.count - 1, 0))
        }
        let standard = (ToolbarArrangement.standard.placements(in: .addressLeading) + ToolbarArrangement.standard.placements(in: .addressTrailing)).map(\.item)
        return 200 + max(0, width(addressItems) - width(standard))
    }

    // MARK: - Zones

    private var itemActions: ToolbarItemActions {
        ToolbarItemActions(
            browserState: browserState,
            currentTab: currentTab,
            onSidebarTap: onSidebarTap,
            onBackTap: onBackTap,
            onForwardTap: onForwardTap,
            onRefreshTap: onRefreshTap,
            onStopLoadingTap: onStopLoadingTap,
            onChatTap: onChatTap,
            onFeedbackTap: onFeedbackTap,
            onMemoryTap: onMemoryTap,
            onDownloadTap: onDownloadTap,
            onCustomizeToolbar: onCustomizeToolbar,
            onSidebarAnchorResolved: onSidebarAnchorResolved,
            onChatAnchorResolved: onChatAnchorResolved,
            downloadViewModel: downloadViewModel,
            isExtensionPopoverShown: $isExtensionPopoverShown,
            visibleExtensions: extensionsModel.visiblePinnedExtensions,
            customization: state.isCustomizing ? customization : nil,
            onExtensionsReordered: { [customization] in customization?.reorderExtensions($0) }
        )
    }

    /// A popover opened from a button in the address bar keeps its On Hover
    /// buttons shown, as the bar's own menus do.
    private var isAddressBarPopoverShown: Bool {
        let items = (state.arrangement.placements(in: .addressLeading) + state.arrangement.placements(in: .addressTrailing)).map(\.item)
        return (state.isDownloadPopoverShown && items.contains(.downloads))
            || (isExtensionPopoverShown && items.contains(.extensionsButton))
    }

    /// The Left zone's items that show right now. Performance has no
    /// navigation toolbar, so its header carries no Left zone.
    private var leftItems: [ToolbarItemID] {
        guard state.showAddressBar else { return [] }
        return shownItems(state.layoutArrangement.placements(in: .left).map(\.item))
    }

    /// The Right zone's items that show right now.
    private var rightItems: [ToolbarItemID] {
        shownItems(rightArrangedItems)
    }

    /// The Right side's items as arranged, shown or not. Performance has no
    /// toolbar to customize, so its header ignores the arrangement.
    private var rightArrangedItems: [ToolbarItemID] {
        guard state.showAddressBar else {
            return Self.performanceItems(extensionIDs: extensionsModel.visiblePinnedExtensions.map(\.id))
        }
        return state.layoutArrangement.placements(in: .right).map(\.item)
    }

    /// Performance's header as before Customize Toolbar: the pinned
    /// extensions in Chromium's presented order, which the sidebar reorders,
    /// then the extensions button, always.
    static func performanceItems(extensionIDs: [String]) -> [ToolbarItemID] {
        extensionIDs.map(ToolbarItemID.extensionAction) + [.extensionsButton]
    }

    /// The arrangement decides the order; a drag-reorder's preview reorders
    /// its capsule live until the arrangement takes the new order.
    private func shownItems(_ items: [ToolbarItemID]) -> [ToolbarItemID] {
        let extensionOrder = extensionsModel.visiblePinnedExtensions.map(\.id)
        let shown = items.filter {
            ToolbarItemView.isShown($0, state: state, visibleExtensionIDs: extensionOrder)
        }
        guard browserState?.extensionManager.pinnedExtensionOrdering.presentationOrder != nil else { return shown }
        return ToolbarZoneSegment.orderingExtensionRuns(shown, by: extensionOrder)
    }
}

struct RefreshStopNavigationButton: View {
    let isProgressVisible: Bool
    let onRefreshTap: () -> Void
    let onStopLoadingTap: () -> Void

    @StateObject private var lottieState = LottieAnimationViewState()
    @State private var isHovering = false
    @State private var didPlayRefreshAnimationForCurrentHover = false

    var body: some View {
        ZStack {
            RefreshNavigationButton(lottieState: lottieState, action: onRefreshTap)
                .opacity(isProgressVisible ? 0 : 1)
                .allowsHitTesting(!isProgressVisible)
                .accessibilityHidden(isProgressVisible)

            NavigationButton(
                systemName: "xmark",
                accessibilityLabel: NSLocalizedString("browser.webContentHeader.stopButton.accessibilityLabel", value: "Stop", comment: "Web content header - Accessibility description for stop loading button"),
                action: onStopLoadingTap
            )
            .opacity(isProgressVisible ? 1 : 0)
            .allowsHitTesting(isProgressVisible)
            .accessibilityHidden(!isProgressVisible)
        }
        .frame(width: 24, height: 24)
        .onHover(perform: handleHoverChange)
    }

    private func handleHoverChange(_ hovered: Bool) {
        guard hovered != isHovering else { return }
        isHovering = hovered

        if hovered {
            guard !isProgressVisible else { return }
            didPlayRefreshAnimationForCurrentHover = true
            lottieState.triggerAnimation()
        } else if didPlayRefreshAnimationForCurrentHover {
            didPlayRefreshAnimationForCurrentHover = false
            lottieState.triggerReverseAnimation()
        }
    }
}

private struct RefreshNavigationButton: View {
    @ObservedObject var lottieState: LottieAnimationViewState
    let action: () -> Void

    var body: some View {
        let config = LottieAnimationViewConfig(
            animationName: "refresh",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 999,
            animationTrigger: .manual,
            themedTintColor: .custom(light: .black, dark: .white),
            reverseOnHoverExit: true
        )

        LottieAnimationView(config: config, state: lottieState, action: action)
            .accessibilityLabel(NSLocalizedString(
                "browser.webContentHeader.refreshButton.accessibilityLabel",
                value: "Refresh",
                comment: "Web content header - Accessibility description for refresh page button"
            ))
    }
}

// MARK: - Navigation Button

struct NavigationButton: View {
    let systemName: String
    var isEnabled: Bool = true
    var accessibilityLabel: String? = nil
    /// Vertical offset for the hover background relative to the icon (negative moves up).
    var hoverBackgroundOffsetY: CGFloat = 0
    var onAnchorResolved: ((NSView?) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(isEnabled ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .themedFill((isHovering && isEnabled) ? .hover : .clear)
                        .frame(width: 24, height: 24)
                        .offset(y: hoverBackgroundOffsetY)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(accessibilityLabel ?? "")
        .background(controlAnchorBackground)
    }

    @ViewBuilder
    private var controlAnchorBackground: some View {
        if let onAnchorResolved {
            HeaderControlAnchorView { view in
                onAnchorResolved(view)
            }
        }
    }
}

struct HeaderControlAnchorView: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughAnchorView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }

    private final class PassthroughAnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

// MARK: - Preview

#Preview("Default Layout - 40pt") {
    let state = WebContentHeaderState()
    state.showAddressBar = true
    state.showNavigationButtons = true
    state.showChatButton = true
    state.showSidebarButton = true
    state.showFeedbackButton = true
    state.showDownloadButton = true
    state.canGoBack = true
    state.canGoForward = true
    state.loadingProgress = 0.5
    state.isLoading = true

    let downloadViewModel = DownloadButtonViewModel()

    return WebContentHeaderView(
        state: state,
        downloadViewModel: downloadViewModel,
        currentTab: nil,
        browserState: nil,
        onSidebarTap: {},
        onBackTap: {},
        onForwardTap: {},
        onRefreshTap: {},
        onStopLoadingTap: {},
        onChatTap: {},
        onFeedbackTap: {},
        onOpenLocationBar: { _ in }
    )
    .frame(height: 40)
    .border(Color.green, width: 2)
}

#Preview("Tall Layout - 60pt") {
    let state = WebContentHeaderState()
    state.showAddressBar = true
    state.showNavigationButtons = true
    state.showChatButton = true
    state.showSidebarButton = false
    state.showFeedbackButton = true
    state.canGoBack = false
    state.canGoForward = true
    state.loadingProgress = 0

    let downloadViewModel = DownloadButtonViewModel()

    return WebContentHeaderView(
        state: state,
        downloadViewModel: downloadViewModel,
        currentTab: nil,
        browserState: nil,
        onSidebarTap: {},
        onBackTap: {},
        onForwardTap: {},
        onRefreshTap: {},
        onStopLoadingTap: {},
        onChatTap: {},
        onFeedbackTap: {},
        onOpenLocationBar: { _ in }
    )
    .frame(height: 60)
    .border(Color.green, width: 2)
}

#Preview("Compact - 30pt") {
    let state = WebContentHeaderState()
    state.showAddressBar = true
    state.showNavigationButtons = true
    state.showChatButton = false
    state.showSidebarButton = false
    state.canGoBack = true
    state.canGoForward = false
    state.loadingProgress = 1.0
    state.isLoading = true

    let downloadViewModel = DownloadButtonViewModel()

    return WebContentHeaderView(
        state: state,
        downloadViewModel: downloadViewModel,
        currentTab: nil,
        browserState: nil,
        onSidebarTap: {},
        onBackTap: {},
        onForwardTap: {},
        onRefreshTap: {},
        onStopLoadingTap: {},
        onChatTap: {},
        onFeedbackTap: {},
        onOpenLocationBar: { _ in }
    )
    .frame(height: 30)
    .border(Color.green, width: 2)
}

/// Plain storage for `WebContentHeaderView`'s measured width, so writing it
/// does not re-render the header.
private final class MeasuredHeaderWidth {
    /// Unbounded until measured: every trailing item fits.
    var value: CGFloat = 10000
}
