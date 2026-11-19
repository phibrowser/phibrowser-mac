// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

final class WebContentAddressBarViewModel: ObservableObject {
    @Published var displayText: String = ""
    @Published var addressBarWidth: CGFloat = 0
    @Published var isInPlaceholderMode: Bool = false

    private weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()
    private var lastMeasuredWidth: CGFloat = 0

    init(browserState: BrowserState?, currentTab: Tab?) {
        self.browserState = browserState
        bind(currentTab: currentTab)
    }

    func bind(currentTab: Tab?) {
        cancellables.removeAll()

        // Placeholder-mode sink: blank text on enter, restore on exit. Lives
        // outside the `guard let tab` so it stays subscribed even when the
        // shell sets currentTab=nil.
        if let browserState {
            browserState.$isInPlaceholderMode
                .combineLatest(browserState.$pendingSplitPreview)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isPlaceholder, preview in
                    guard let self else { return }
                    self.isInPlaceholderMode = isPlaceholder
                    if isPlaceholder || (preview != nil && preview?.partnerTabId == currentTab?.guid) {
                        self.displayText = ""
                    } else if let url = currentTab?.url {
                        let alwaysShowURLPath = PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue()
                        self.displayText = Self.addressText(for: url, alwaysShowURLPath: alwaysShowURLPath)
                    } else {
                        self.displayText = ""
                    }
                }
                .store(in: &cancellables)
        }

        guard let tab = currentTab else {
            displayText = ""
            return
        }

        let alwaysShowURLPathPublisher = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in
                PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue()
            }
            .prepend(PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue())
            .removeDuplicates()

        let overviewActivePublisher = browserState?.$groupOverviewState
            .map { $0 != nil }
            .prepend(browserState?.groupOverviewState != nil)
            .removeDuplicates()
            .eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()

        tab.$url
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .combineLatest(alwaysShowURLPathPublisher, overviewActivePublisher)
            .map { urlString, alwaysShowURLPath, overviewActive in
                guard !overviewActive else { return "" }
                return Self.addressText(for: urlString ?? "", alwaysShowURLPath: alwaysShowURLPath)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                // Skip writes during placeholder mode so the placeholder sink
                // (which blanks displayText) is not raced by a stale URL update.
                guard self?.browserState?.isInPlaceholderMode != true else { return }
                if let preview = self?.browserState?.pendingSplitPreview,
                   preview.partnerTabId == tab.guid {
                    self?.displayText = ""
                    return
                }
                self?.displayText = text
            }
            .store(in: &cancellables)
    }

    /// The text the bar shows for a page: its address without the scheme
    /// with Always Show URL Path on, its domain otherwise; empty for none or
    /// the new tab page.
    static func addressText(for urlString: String, alwaysShowURLPath: Bool) -> String {
        // A reader page stands in for its article: show the article's URL.
        let urlString = ReaderExtensionBridge.sourceURLString(fromReaderPageURL: urlString) ?? urlString
        guard !urlString.isEmpty else {
            return ""
        }
        guard !urlString.isNTP else {
            return ""
        }
        if alwaysShowURLPath {
            return removingTrailingSlashIfNeeded(from: displayURLWithoutScheme(urlString))
        }
        return removingTrailingSlashIfNeeded(from: URLProcessor.displayName(for: urlString))
    }

    private static func displayURLWithoutScheme(_ urlString: String) -> String {
        let brandedURL = URLProcessor.phiBrandEnsuredUrlString(urlString)
        if let components = URLComponents(string: brandedURL),
           let host = components.host {
            let displayHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let portSuffix = components.port.map { ":\($0)" } ?? ""
            let path = components.percentEncodedPath
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""
            return "\(displayHost)\(portSuffix)\(path)\(query)\(fragment)"
        }
        if let range = brandedURL.range(of: "://") {
            let withoutScheme = String(brandedURL[range.upperBound...])
            if withoutScheme.hasPrefix("www.") {
                return String(withoutScheme.dropFirst(4))
            }
            return withoutScheme
        }
        return brandedURL
    }

    private static func removingTrailingSlashIfNeeded(from text: String) -> String {
        guard text.count > 1 else {
            return text
        }
        var result = text
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    func updateWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        if abs(width - lastMeasuredWidth) < 0.5 { return }
        lastMeasuredWidth = width
        addressBarWidth = width
    }
}

struct AddressBarAnchorView: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
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
}

struct WebContentAddressBarView: View {
    private let browserState: BrowserState?
    private let currentTab: Tab?
    private let showBackgroundWhenInactive: Bool
    private let loadingProgress: Double
    private let isLoading: Bool
    private let isProgressVisible: Bool
    private let backgroundColor: Color?
    private let allowsWindowDrag: Bool
    private let leading: [ToolbarPlacement]
    private let trailing: [ToolbarPlacement]
    private let isCustomizing: Bool
    /// A popover opened from one of the bar's buttons (Downloads, the
    /// extensions menu) is up.
    private let isPopoverShown: Bool
    private let itemActions: ToolbarItemActions
    private let headerState: WebContentHeaderState
    private let style: AddressBarStyle
    private let onOpenLocationBar: (NSView?) -> Void
    private let onMinimalLayout: (() -> Void)?

    @StateObject private var viewModel: WebContentAddressBarViewModel
    @State private var isHovering = false
    /// A tap on an On Hover button's spot shows the bar's On Hover buttons
    /// for touch, which has no hover.
    @State private var isTouchRevealed = false
    @State private var touchRevealHideTask: Task<Void, Never>?
    /// While customizing: the buttons of the bar's sections under the
    /// pointer. While any is, the bar's own hover fill steps aside.
    @State private var hoveredInnerItems: Set<ToolbarItemID> = []
    /// While customizing: the button whose visibility badge is under the
    /// pointer. It keeps that button's badge and hover fill.
    @State private var hoveredBadgeItem: ToolbarItemID?
    @State private var anchorView: NSView?
    /// A site or memories menu opened from one of the bar's buttons is up.
    @State private var isMenuShown = false
    /// Minimal only: where the bar's slot starts in the header's coordinates.
    @State private var minimalSlotMinX: CGFloat = 0
    /// Minimal only: each section's items drawn only while customizing, which
    /// the centering leaves out so the text stays put.
    @State private var minimalLeadingCustomizeOnly: Set<ToolbarItemID> = []
    @State private var minimalTrailingCustomizeOnly: Set<ToolbarItemID> = []
    /// Minimal only: each section's horizontal extent in the slot, which the
    /// slot-wide click surface leaves to the buttons.
    @State private var minimalLeadingSpan: ClosedRange<CGFloat>?
    /// Each address section's drawn width as last measured, in any mode (nil
    /// until measured): a button can count as shown yet draw nothing, as
    /// Reader View on a page without it or Site Memories without memories.
    @State private var rowWidths: [ToolbarZone: CGFloat] = [:]
    /// `rowWidths` as they were when customizing began: what the text
    /// padding goes by while customizing, which draws hidden buttons too.
    @State private var browsingRowWidths: [ToolbarZone: CGFloat] = [:]
    @State private var minimalTrailingSpan: ClosedRange<CGFloat>?
    /// Minimal only, while customizing: the pointer is over the unit, as its
    /// drag source tracks it.
    @State private var isMinimalUnitHovered = false
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    private let onAnchorResolved: ((NSView?) -> Void)?

    init(
        browserState: BrowserState?,
        currentTab: Tab?,
        showBackgroundWhenInactive: Bool,
        loadingProgress: Double,
        isLoading: Bool,
        isProgressVisible: Bool = false,
        backgroundColor: Color? = nil,
        allowsWindowDrag: Bool = false,
        leading: [ToolbarPlacement],
        trailing: [ToolbarPlacement],
        isCustomizing: Bool,
        isPopoverShown: Bool = false,
        itemActions: ToolbarItemActions,
        headerState: WebContentHeaderState,
        style: AddressBarStyle = .standard,
        onOpenLocationBar: @escaping (NSView?) -> Void,
        onAnchorResolved: ((NSView?) -> Void)? = nil,
        onMinimalLayout: (() -> Void)? = nil
    ) {
        self.browserState = browserState
        self.currentTab = currentTab
        self.showBackgroundWhenInactive = showBackgroundWhenInactive
        self.loadingProgress = loadingProgress
        self.isLoading = isLoading
        self.isProgressVisible = isProgressVisible
        self.backgroundColor = backgroundColor
        self.allowsWindowDrag = allowsWindowDrag
        self.leading = leading
        self.trailing = trailing
        self.isCustomizing = isCustomizing
        self.isPopoverShown = isPopoverShown
        self.itemActions = itemActions
        self.headerState = headerState
        self.style = style
        self.onOpenLocationBar = onOpenLocationBar
        self.onAnchorResolved = onAnchorResolved
        self.onMinimalLayout = onMinimalLayout
        _viewModel = StateObject(wrappedValue: WebContentAddressBarViewModel(
            browserState: browserState,
            currentTab: currentTab
        ))
    }

    /// Whether an address bar item shows now. Hidden items keep their frame.
    static func isShown(_ placement: ToolbarPlacement, isHovering: Bool, isMenuShown: Bool, isCustomizing: Bool) -> Bool {
        placement.visibility == .always || isHovering || isMenuShown || isCustomizing
    }

    /// Whether the bar's own hover fill shows. While customizing, a button
    /// under the pointer takes the fill for itself.
    static func showsBarHoverFill(isHovered: Bool, isCustomizing: Bool, isInnerItemHovered: Bool) -> Bool {
        isHovered && !(isCustomizing && isInnerItemHovered)
    }

    var body: some View {
        Group {
            switch style {
            case .standard: standardBody
            case .minimal: minimalBody
            }
        }
        // A badge gone with customizing may never report the pointer leaving
        // it: the next session starts with none.
        .onChange(of: itemActions.customization != nil) { _, isCustomizing in
            if isCustomizing { browsingRowWidths = rowWidths }
            hoveredBadgeItem = nil
        }
    }

    private var standardBody: some View {
        HStack(spacing: 0) {
            standardSection(leading, zone: .addressLeading)

            HStack(spacing: 8) {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundColor(displayTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            // The padding on either side belongs to the text region, so the
            // click surface covers every point between the leading and
            // trailing controls and none of them.
            .padding(.leading, textLeadingPadding)
            .padding(.trailing, textTrailingPadding)
            .background {
                // While customizing, the bar's own drag source takes these presses.
                if !isCustomizing {
                    WebContentAddressBarDragSurface(allowsWindowDrag: allowsWindowDrag) {
                        openLocationBar()
                    }
                }
            }
            .overlay {
                if itemActions.customization != nil {
                    ToolbarAddressSectionDividers()
                }
            }

            standardSection(trailing, zone: .addressTrailing)
        }
        .frame(height: 26)
        // Behind the buttons, whose own drag sources stay on top.
        .toolbarCustomizationAddressBarSource(customization: itemActions.customization, dragToken: dragToken)
        .overlay {
            if itemActions.customization != nil {
                ToolbarAddressBarOutline()
            }
        }
        .background(progressBackgroundInline)
        .background(backgroundShape)
        .background(anchorBackground)
        .overlay(alignment: .bottom) {
            AddressBarProgressBarView(
                progress: effectiveLoadingProgress,
                isVisible: isProgressVisible
            )
            .frame(height: 1)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: isMenuShown) { _, isShown in
            if !isShown, isTouchRevealed {
                scheduleTouchRevealHide()
            }
        }
        .background(widthReader)
        .onChange(of: currentTab.map(ObjectIdentifier.init)) { _, _ in
            viewModel.bind(currentTab: currentTab)
        }
        .clipShape(Capsule())
        // Outside the capsule's clip: the badge sticks out past its button.
        .overlayPreferenceValue(ToolbarVisibilityBadgeKey.self, visibilityBadge)
    }

    /// No capsule: the address as plain text, with the leading section's
    /// buttons right before it and the trailing section's right after it.
    /// That unit is centered on the window (`MinimalAddressLayout.unit`), and
    /// its On Hover buttons show while the pointer is over the unit or one of
    /// its menus is up. Clicks on the text and on the rest of the slot open
    /// the omnibox, so an empty address (new tab page) still opens it; the
    /// anchor spans the slot, so the omnibox drops down where and as wide as
    /// the Standard capsule.
    private var minimalBody: some View {
        MinimalAddressCentering(
            windowCenter: headerState.windowCenter,
            slotMinX: minimalSlotMinX,
            leadingCustomizeOnlyWidth: minimalCustomizeOnlyWidth(leading, items: minimalLeadingCustomizeOnly),
            trailingCustomizeOnlyWidth: minimalCustomizeOnlyWidth(trailing, items: minimalTrailingCustomizeOnly),
            leadingMinimumWidth: sectionReserve(leading),
            trailingMinimumWidth: sectionReserve(trailing)
        ) {
            minimalUnitBackground
                .layoutValue(key: MinimalAddressPartKey.self, value: .unit)

            // An empty section's reserve, which takes its drops.
            if sectionReserve(leading) > 0 {
                Color.clear
                    .toolbarCustomizationZone(.addressLeading, isEmpty: true, customization: emptyZoneCustomization(leading))
                    .layoutValue(key: MinimalAddressPartKey.self, value: .leadingSection)
            }
            if sectionReserve(trailing) > 0 {
                Color.clear
                    .toolbarCustomizationZone(.addressTrailing, isEmpty: true, customization: emptyZoneCustomization(trailing))
                    .layoutValue(key: MinimalAddressPartKey.self, value: .trailingSection)
            }

            if showsZone(leading) {
                itemRow(leading, zone: .addressLeading)
                    .onPreferenceChange(ToolbarCustomizeOnlyItemsKey.self) { items in
                        minimalLeadingCustomizeOnly = items
                    }
                    .onGeometryChange(for: ClosedRange<CGFloat>.self) { proxy in
                        Self.span(of: proxy.frame(in: .named(Self.minimalSlotSpaceName)))
                    } action: { span in
                        minimalLeadingSpan = span
                    }
                    .padding(.leading, Self.sectionPaddingAtEnd)
                    .layoutValue(key: MinimalAddressPartKey.self, value: .leading)
            }

            minimalText
                .layoutValue(key: MinimalAddressPartKey.self, value: .text)

            if showsZone(trailing) {
                itemRow(trailing, zone: .addressTrailing)
                    .onPreferenceChange(ToolbarCustomizeOnlyItemsKey.self) { items in
                        minimalTrailingCustomizeOnly = items
                    }
                    .onGeometryChange(for: ClosedRange<CGFloat>.self) { proxy in
                        Self.span(of: proxy.frame(in: .named(Self.minimalSlotSpaceName)))
                    } action: { span in
                        minimalTrailingSpan = span
                    }
                    .padding(.trailing, Self.sectionPaddingAtEnd)
                    .layoutValue(key: MinimalAddressPartKey.self, value: .trailing)
            }
        }
        // Applied before the slot's click surface, so only the unit counts.
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: isMenuShown) { _, isShown in
            if !isShown, isTouchRevealed {
                scheduleTouchRevealHide()
            }
        }
        .frame(height: 26)
        .coordinateSpace(name: Self.minimalSlotSpaceName)
        .overlayPreferenceValue(ToolbarVisibilityBadgeKey.self, visibilityBadge)
        .background {
            // The slot around the unit, less the buttons, which take their
            // own clicks. While customizing, the bar's own drag source takes
            // the unit's presses.
            if !isCustomizing {
                WebContentAddressBarDragSurface(
                    allowsWindowDrag: allowsWindowDrag,
                    excludedXSpans: [
                        showsZone(leading) ? minimalLeadingSpan : nil,
                        showsZone(trailing) ? minimalTrailingSpan : nil,
                    ].compactMap { $0 }
                ) {
                    openLocationBar()
                }
            }
        }
        .background(anchorBackground)
        // The slot sits between the side zones' actual edges; its frame in the
        // header turns the window center into the slot's own coordinates. Any
        // change re-reads the window center, which an ancestor's move can
        // leave stale without a frame notification on the header.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(WebContentHeaderView.coordinateSpaceName))
        } action: { frame in
            minimalSlotMinX = frame.minX
            onMinimalLayout?()
        }
        .onChange(of: currentTab.map(ObjectIdentifier.init)) { _, _ in
            viewModel.bind(currentTab: currentTab)
        }
    }

    /// Spans the centered unit behind its buttons and text: Standard's hover
    /// fill, the bar's drag source and outline while customizing, and a hover
    /// shape that keeps the unit hovered between and over hidden buttons.
    private var minimalUnitBackground: some View {
        Color.clear
            .background {
                // Standard's hover color, in the outline's shape.
                Capsule()
                    .fill(Color(.sidebarTabHoveredColorEmphasized))
                    .opacity(showsMinimalHoverFill ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Behind the buttons, whose own drag sources stay on top.
            .toolbarCustomizationAddressBarSource(customization: itemActions.customization, dragToken: dragToken) { isMinimalUnitHovered = $0 }
            .background(Color.clear.contentShape(Rectangle()))
            .overlay {
                if itemActions.customization != nil {
                    ToolbarAddressBarOutline()
                }
            }
    }

    /// The address text, the only part of the unit that truncates. As in
    /// Standard, it opens the omnibox, carries the section dividers while
    /// customizing.
    private var minimalText: some View {
        Text(displayText)
            .font(.system(size: 13))
            .foregroundColor(displayTextColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsHitTesting(false)
            .padding(.leading, textLeadingPadding)
            .padding(.trailing, textTrailingPadding)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                AddressBarProgressBarView(
                    progress: effectiveLoadingProgress,
                    isVisible: isProgressVisible
                )
                .frame(height: 1)
            }
            .background {
                // While customizing, the bar's own drag source takes these presses.
                if !isCustomizing {
                    WebContentAddressBarDragSurface(allowsWindowDrag: allowsWindowDrag) {
                        openLocationBar()
                    }
                }
            }
            .overlay {
                if itemActions.customization != nil {
                    ToolbarAddressSectionDividers()
                }
            }
    }

    private static let minimalSlotSpaceName = "minimalAddressSlot"

    /// The spacing between the bar's buttons.
    static let itemSpacing: CGFloat = 2

    private static func span(of frame: CGRect) -> ClosedRange<CGFloat> {
        frame.minX...max(frame.minX, frame.maxX)
    }

    /// What a Minimal section's customize-only items add to its width;
    /// nothing outside customizing.
    private func minimalCustomizeOnlyWidth(_ placements: [ToolbarPlacement], items: Set<ToolbarItemID>) -> CGFloat {
        guard isCustomizing else { return 0 }
        return Self.customizeOnlyWidth(of: placements.map(\.item), customizeOnly: items)
    }

    /// As in Standard, while the pointer is over the unit or one of its
    /// menus is up; while customizing, the bar's drag source tracks the
    /// pointer and a button under it takes the fill for itself.
    private var showsMinimalHoverFill: Bool {
        let isCustomizing = itemActions.customization != nil
        return Self.showsBarHoverFill(
            isHovered: isCustomizing ? isMinimalUnitHovered : isHoverActive,
            isCustomizing: isCustomizing,
            isInnerItemHovered: isInnerItemHovered
        ) || (!isCustomizing && isMenuShown)
    }

    /// The widths of `items` that are customize-only, with the spacing each adds.
    static func customizeOnlyWidth(of items: [ToolbarItemID], customizeOnly: Set<ToolbarItemID>) -> CGFloat {
        MinimalAddressLayout.customizeOnlyWidth(
            itemWidths: items.filter(customizeOnly.contains).map(ToolbarItemView.naturalWidth(of:)),
            spacing: itemSpacing
        )
    }

    /// What a drag of the bar carries while customizing, for the page shown
    /// when the drag starts: in Standard and Minimal alike, the Standard
    /// bar's colors.
    private var dragToken: () -> ToolbarAddressBarDragToken {
        let colorScheme = colorScheme
        let background = backgroundColor ?? ThemedColor.windowBackground.swiftUIColor(theme: theme, appearance: appearance)
        let textColor = ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)
        let placeholderColor = ThemedColor.textSecondary.swiftUIColor(theme: theme, appearance: appearance)
        return { [currentTab] in
            ToolbarAddressBarDragToken(
                urlString: currentTab?.url,
                colorScheme: colorScheme,
                background: background,
                textColor: textColor,
                placeholderColor: placeholderColor
            )
        }
    }

    private var isHoverActive: Bool {
        isHovering || isTouchRevealed
    }

    /// Takes the first touch tap on a hidden On Hover button so it only
    /// reveals the bar's On Hover buttons; once shown, taps reach them.
    @ViewBuilder
    private var touchRevealSurface: some View {
        if #available(macOS 27, *) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 1, inputKinds: .directTouch).onEnded {
                    isTouchRevealed = true
                    scheduleTouchRevealHide()
                })
                .allowsHitTesting(!isHoverActive && !isMenuShown)
        }
    }

    /// Hides the touch reveal after a few seconds. A menu opened from these
    /// buttons keeps the bar in its hover state, as it does for the pointer;
    /// the countdown restarts when the menu closes.
    private func scheduleTouchRevealHide() {
        touchRevealHideTask?.cancel()
        touchRevealHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !isMenuShown else { return }
            isTouchRevealed = false
        }
    }

    private var backgroundShape: some View {
        // Placeholder mode shows the inactive background so users can spot
        // the address bar without hovering — it'd otherwise be a blank patch.
        let baseColor = (showBackgroundWhenInactive || viewModel.isInPlaceholderMode)
            ? Color(.sidebarTabHovered)
            : (backgroundColor == nil
               ? ThemedColor.windowBackground.swiftUIColor(theme: theme, appearance: appearance)
               : .clear)
        let hoverColor = Color(.sidebarTabHoveredColorEmphasized)
        let shouldHighlight = Self.showsBarHoverFill(isHovered: isHoverActive, isCustomizing: isCustomizing, isInnerItemHovered: isInnerItemHovered) || isMenuShown
        return Capsule()
            .fill(shouldHighlight ? hoverColor : baseColor)
    }

    /// Progress background rendered in `.background()` so it never changes layout.
    private var progressBackgroundInline: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let clampedProgress = min(max(effectiveLoadingProgress, 0), 1)
            let baseColor = ThemedColor.themeColor.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
            let backgroundLead: CGFloat = 100
            let progressWidth = totalWidth * clampedProgress
            let backgroundWidth = min(totalWidth, progressWidth + backgroundLead)

            if isProgressVisible && clampedProgress > 0 && totalWidth > 0 {
                LinearGradient(
                    stops: [
                        .init(color: baseColor.opacity(0.0), location: 0),
                        .init(color: baseColor.opacity(0.2), location: 0.8),
                        .init(color: baseColor.opacity(0.0), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: backgroundWidth, height: proxy.size.height)
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.2), value: clampedProgress)
            }
        }
        .allowsHitTesting(false)
    }

    private var displayText: String {
        if viewModel.isInPlaceholderMode {
            return NSLocalizedString("browser.webContentAddressBar.emptyWindowPlaceholder", value: "Search or Enter URL", comment: "Web content address bar - Placeholder text shown when window has no tab")
        }
        if viewModel.displayText.isEmpty {
            return ""
        }
        return viewModel.displayText
    }

    private var displayTextColor: Color {
        if viewModel.isInPlaceholderMode {
            // Match SideAddressBar's placeholder text — system standard placeholder
            // color is weaker than textSecondary and signals "fill me in" affordance.
            return Color(NSColor.placeholderTextColor)
        }
        return viewModel.displayText.isEmpty
            ? ThemedColor.textSecondary.swiftUIColor(theme: theme, appearance: appearance)
            : ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)
    }

    private var isNTP: Bool {
        currentTab?.isNTP == true
    }

    private var effectiveLoadingProgress: Double {
        if isNTP || !isLoading {
            return 0
        }
        return loadingProgress
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: AddressBarWidthPreferenceKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(AddressBarWidthPreferenceKey.self) { width in
            viewModel.updateWidth(width)
        }
    }

    private var anchorBackground: some View {
        AddressBarAnchorView { view in
            anchorView = view
            onAnchorResolved?(view)
        }
        .allowsHitTesting(false)
    }

    private var showsItems: Bool {
        !viewModel.isInPlaceholderMode
    }

    private func showsZone(_ placements: [ToolbarPlacement]) -> Bool {
        showsItems && !placements.isEmpty
    }

    /// Whether the zone draws none of its items right now.
    private func drawsNothing(_ placements: [ToolbarPlacement]) -> Bool {
        let visibleExtensionIDs = itemActions.visibleExtensions.map(\.id)
        return !placements.contains {
            ToolbarItemView.isShown($0.item, state: headerState, visibleExtensionIDs: visibleExtensionIDs)
        }
    }

    /// The controller for a zone that draws nothing while customizing, whose
    /// drop target then lies over the text; nil otherwise.
    private func emptyZoneCustomization(_ placements: [ToolbarPlacement]) -> ToolbarCustomizationController? {
        showsItems && drawsNothing(placements) ? itemActions.customization : nil
    }

    /// The space an address section reserves next to the text: an empty
    /// section's `addressSectionReserve` while customizing, nothing otherwise.
    private func sectionReserve(_ placements: [ToolbarPlacement]) -> CGFloat {
        Self.sectionReserve(
            isEmpty: drawsNothing(placements),
            isCustomizing: itemActions.customization != nil && showsItems
        )
    }

    static func sectionReserve(isEmpty: Bool, isCustomizing: Bool) -> CGFloat {
        isEmpty && isCustomizing ? ToolbarCustomizationLayout.addressSectionReserve : 0
    }

    /// One of Standard's sections: its buttons at the bar's end. While
    /// customizing, an empty section reserves `sectionReserve` next to the
    /// text, which makes room, and takes its drops there. Otherwise it is
    /// exactly its buttons, as before.
    @ViewBuilder
    private func standardSection(_ placements: [ToolbarPlacement], zone: ToolbarZone) -> some View {
        let reserve = sectionReserve(placements)
        if reserve > 0 {
            HStack(spacing: 0) {
                if showsZone(placements) {
                    itemRow(placements, zone: zone)
                }
            }
            .frame(width: reserve)
            .toolbarCustomizationZone(zone, isEmpty: true, customization: emptyZoneCustomization(placements))
        } else if showsZone(placements) {
            itemRow(placements, zone: zone)
                .padding(zone == .addressLeading ? .leading : .trailing, Self.sectionPaddingAtEnd)
        }
    }

    /// The text padding in both styles, while browsing and customizing:
    /// beside a section with buttons, and at the bar's end beside an empty
    /// one (`textPaddingAtEnd`, the same on both sides, a trailing side
    /// without items included). Beside buttons it is Phi's own 8pt, and
    /// holds a section divider's 1pt line while customizing, the same
    /// padding as while browsing, so customizing moves neither text nor
    /// buttons.
    static let textPaddingBesideButtons: CGFloat = 8
    /// The gap between a section's outermost button and the bar's end: none,
    /// as Phi has always had it; the button's hover circle is its own margin.
    static let sectionPaddingAtEnd: CGFloat = 0
    static let textPaddingAtEnd: CGFloat = 12
    /// How an On Hover button is drawn while customizing.
    static let onHoverOpacityWhileCustomizing: Double = 0.55

    /// The text padding beside a section: `textPaddingBesideButtons` when it
    /// shows buttons, `textPaddingAtEnd` when it is empty, the same on both sides.
    static func textPadding(sectionShowsButtons: Bool) -> CGFloat {
        sectionShowsButtons ? textPaddingBesideButtons : textPaddingAtEnd
    }

    private var textLeadingPadding: CGFloat {
        Self.textPadding(sectionShowsButtons: showsButtonsWhileBrowsing(leading, zone: .addressLeading))
    }

    private var textTrailingPadding: CGFloat {
        Self.textPadding(sectionShowsButtons: showsButtonsWhileBrowsing(trailing, zone: .addressTrailing))
    }

    /// The width the padding decision goes by: the latest measure while
    /// browsing, which is the row as drawn, so a row rebuilt while customizing
    /// never leaves a stale value behind; the measure from when customizing
    /// began while customizing, so entering it moves nothing.
    static func measuredBrowsingWidth(rowWidth: CGFloat?, widthWhenCustomizingBegan: CGFloat?, isCustomizing: Bool) -> CGFloat? {
        isCustomizing ? widthWhenCustomizingBegan : rowWidth
    }

    /// Reader View and Site Memories count as shown while browsing but draw
    /// nothing on a page without them; every other item draws when shown.
    private static func mayDrawNothing(_ item: ToolbarItemID) -> Bool {
        item == .readerView || item == .siteMemories
    }

    /// Whether a section draws a button while browsing, from the items that
    /// count as shown (`ToolbarItemView.isShownWhileBrowsing`). One that always
    /// draws decides it alone, so a measure taken before it rendered never
    /// matters. A section of only Reader View and Site Memories goes by its
    /// measured width: empty when it drew nothing. Unmeasured, it counts as
    /// drawing.
    static func drawsButtonsWhileBrowsing(shownItems: [ToolbarItemID], measuredWidth: CGFloat?) -> Bool {
        if shownItems.contains(where: { !mayDrawNothing($0) }) { return true }
        if shownItems.isEmpty { return false }
        return measuredWidth.map { $0 > 0 } ?? true
    }

    /// Whether a section draws any button while browsing (On Hover ones
    /// keep their space hidden). A section whose buttons draw nothing on
    /// this page or in this build counts as empty. What customizing adds does
    /// not count, so the text never moves when customizing starts.
    private func showsButtonsWhileBrowsing(_ placements: [ToolbarPlacement], zone: ToolbarZone) -> Bool {
        guard showsItems, !placements.isEmpty else { return false }
        let visibleExtensionIDs = itemActions.visibleExtensions.map(\.id)
        let shown = placements.map(\.item).filter {
            ToolbarItemView.isShownWhileBrowsing($0, state: headerState, visibleExtensionIDs: visibleExtensionIDs)
        }
        return Self.drawsButtonsWhileBrowsing(
            shownItems: shown,
            measuredWidth: Self.measuredBrowsingWidth(rowWidth: rowWidths[zone], widthWhenCustomizingBegan: browsingRowWidths[zone], isCustomizing: itemActions.customization != nil)
        )
    }

    /// Clicking the address does nothing while customizing.
    private func openLocationBar() {
        guard !isCustomizing else { return }
        onOpenLocationBar(anchorView)
    }

    private func itemRow(_ placements: [ToolbarPlacement], zone: ToolbarZone) -> some View {
        let customization = itemActions.customization
        return HStack(spacing: Self.itemSpacing) {
            ForEach(placements, id: \.item) { placement in
                ToolbarItemView(
                    item: placement.item,
                    actions: itemActions,
                    state: headerState,
                    addressBar: AddressBarItemContext(
                        isRevealed: Self.isShown(placement, isHovering: isHoverActive, isMenuShown: isMenuShown || isPopoverShown, isCustomizing: isCustomizing),
                        onMenuShownChange: { isMenuShown = $0 }
                    )
                )
                .overlay {
                    if placement.visibility == .onHover, customization == nil {
                        touchRevealSurface
                    }
                }
                // While customizing, an On Hover button is drawn dimmed; its
                // eye badge and hover fill, drawn apart from it, stay full.
                .opacity(customization != nil && placement.visibility == .onHover ? Self.onHoverOpacityWhileCustomizing : 1)
                .toolbarCustomizationSource(placement.item, in: zone, customization: customization, keepsHover: hoveredBadgeItem == placement.item) { hovered in
                    if hovered {
                        hoveredInnerItems.insert(placement.item)
                    } else {
                        hoveredInnerItems.remove(placement.item)
                    }
                }
                .anchorPreference(key: ToolbarVisibilityBadgeKey.self, value: .bounds) { bounds in
                    guard customization != nil, ToolbarVisibilityBadge.isOffered(in: zone),
                          visibilityBadgeItem == placement.item else { return nil }
                    return ToolbarVisibilityBadgeTarget(item: placement.item, visibility: placement.visibility, bounds: bounds)
                }
            }
        }
        .toolbarCustomizationZone(zone, isEmpty: false, customization: drawsNothing(placements) ? nil : customization)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidths[zone] = width
        }
    }
}

extension WebContentAddressBarView {
    /// While customizing, a button of the bar's sections or its visibility
    /// badge is under the pointer.
    private var isInnerItemHovered: Bool {
        !hoveredInnerItems.isEmpty || hoveredBadgeItem != nil
    }

    /// The button that shows its visibility badge (`ToolbarVisibilityBadge.item`).
    private var visibilityBadgeItem: ToolbarItemID? {
        guard itemActions.customization != nil else { return nil }
        return ToolbarVisibilityBadge.item(
            drawnItems: (leading + trailing).map(\.item),
            hoveredItems: hoveredInnerItems,
            badgeHoveredItem: hoveredBadgeItem,
            isDragging: headerState.draggedPayload != nil
        )
    }

    /// The name the sheet shows for the button, or an extension's own.
    private func badgeItemName(of item: ToolbarItemID) -> String {
        if case .extensionAction(let id) = item, let ext = itemActions.visibleExtensions.first(where: { $0.id == id }) {
            return ext.name
        }
        return ToolbarPalette.name(of: item)
    }

    /// The badge at its button's top right, above everything the
    /// bar draws. An overlay: it moves nothing.
    @ViewBuilder
    private func visibilityBadge(_ target: ToolbarVisibilityBadgeTarget?) -> some View {
        if let target, let customization = itemActions.customization {
            GeometryReader { proxy in
                let item = target.item
                ToolbarVisibilityBadgeButton(
                    visibility: target.visibility,
                    itemName: badgeItemName(of: item),
                    background: backgroundColor.map { NSColor($0) } ?? ThemedColor.windowBackground.resolver(theme, appearance),
                    onToggle: { [weak customization] in customization?.toggleVisibility(of: item) },
                    onHoverChange: { hovered in
                        if hovered {
                            hoveredBadgeItem = item
                        } else if hoveredBadgeItem == item {
                            hoveredBadgeItem = nil
                        }
                    },
                    contextMenu: { [weak customization] in customization?.visibilityMenu(for: item) }
                )
                .frame(width: ToolbarVisibilityBadge.size, height: ToolbarVisibilityBadge.size)
                .position(ToolbarVisibilityBadge.center(in: proxy[target.bounds]))
            }
        }
    }
}

/// Installs `WebContentAddressBarDragView` behind the Content Address Bar's
/// leading text region (same shape as the pinned-extension reorder surface).
private struct WebContentAddressBarDragSurface: NSViewRepresentable {
    let allowsWindowDrag: Bool
    /// Horizontal spans, in the surface's own coordinates, left to controls
    /// drawn over it (Minimal's buttons).
    var excludedXSpans: [ClosedRange<CGFloat>] = []
    let onClick: () -> Void

    func makeNSView(context: Context) -> WebContentAddressBarDragView {
        WebContentAddressBarDragView()
    }

    func updateNSView(_ nsView: WebContentAddressBarDragView, context: Context) {
        nsView.allowsWindowDrag = allowsWindowDrag
        nsView.excludedXSpans = excludedXSpans
        nsView.onClick = onClick
    }
}

/// AppKit owner of the Content Address Bar's left-button click and window
/// drag. A press released within `dragThreshold` points of where it started,
/// measured in screen space, opens the omnibox. A press that travels further
/// is a drag and never opens it: from that point the window follows the
/// pointer when `allowsWindowDrag` is set (Balanced), and nothing happens
/// otherwise. Hover, right-clicks and scrolls fall through to the SwiftUI bar
/// beneath, which keeps its hover highlight and hover-gated controls.
final class WebContentAddressBarDragView: NSView {
    var allowsWindowDrag = false
    /// Presses in these horizontal spans (own coordinates) belong to controls
    /// drawn over the surface, not to the surface.
    var excludedXSpans: [ClosedRange<CGFloat>] = []
    var onClick: (() -> Void)?

    /// Matches the click-vs-drag threshold of the sidebar's empty area and
    /// the pinned-extension reorder surface.
    private static let dragThreshold: CGFloat = 5

    private var mouseDownScreenLocation: NSPoint?
    private var hasCrossedDragThreshold = false

    static func claimsEvent(ofType type: NSEvent.EventType?) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return true
        default:
            return false
        }
    }

    static func isExcluded(_ x: CGFloat, by spans: [ClosedRange<CGFloat>]) -> Bool {
        spans.contains { $0.contains(x) }
    }

    static func isClick(from mouseDownLocation: NSPoint, to mouseUpLocation: NSPoint) -> Bool {
        abs(mouseUpLocation.x - mouseDownLocation.x) <= dragThreshold
            && abs(mouseUpLocation.y - mouseDownLocation.y) <= dragThreshold
    }

    /// Keeps the window's background drag off the bar: the press belongs to
    /// this surface, which moves the window only explicitly.
    override var mouseDownCanMoveWindow: Bool { false }

    // Keep the activation click so mouseUp can open the omnibox.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil,
              Self.claimsEvent(ofType: NSApp.currentEvent?.type) else {
            return nil
        }
        if let superview, Self.isExcluded(convert(point, from: superview).x, by: excludedXSpans) {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // A Control-click is a right-click: it goes on to the toolbar's menu.
        if event.modifierFlags.contains(.control) {
            mouseDownScreenLocation = nil
            rightMouseDown(with: event)
            return
        }
        mouseDownScreenLocation = window?.convertPoint(toScreen: event.locationInWindow)
        hasCrossedDragThreshold = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasCrossedDragThreshold,
              let window,
              let mouseDownScreenLocation,
              !Self.isClick(
                from: mouseDownScreenLocation,
                to: window.convertPoint(toScreen: event.locationInWindow)
              ) else {
            return
        }
        // Crossing the threshold consumes the gesture (the pinned-extension
        // reorder surface's rule). The window drag starts only now because on
        // macOS 27 performDrag(with:) can return before the release, so a
        // click cannot be decided after it; a full-screen window cannot move.
        hasCrossedDragThreshold = true
        if allowsWindowDrag, !window.styleMask.contains(.fullScreen) {
            window.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownScreenLocation = nil }
        guard !hasCrossedDragThreshold,
              let mouseDownScreenLocation,
              let mouseUpScreenLocation = window?.convertPoint(toScreen: event.locationInWindow),
              Self.isClick(from: mouseDownScreenLocation, to: mouseUpScreenLocation) else {
            return
        }
        onClick?()
    }
}

/// Observes the window center for the Minimal address, so its moves re-place
/// the address without re-rendering the header around it.
private struct MinimalAddressCentering<Content: View>: View {
    @ObservedObject var windowCenter: HeaderWindowCenter
    /// Where the slot starts in the header's coordinates.
    let slotMinX: CGFloat
    let leadingCustomizeOnlyWidth: CGFloat
    let trailingCustomizeOnlyWidth: CGFloat
    let leadingMinimumWidth: CGFloat
    let trailingMinimumWidth: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        MinimalAddressPlacement(
            centerX: windowCenter.x - slotMinX,
            leadingCustomizeOnlyWidth: leadingCustomizeOnlyWidth,
            trailingCustomizeOnlyWidth: trailingCustomizeOnlyWidth,
            leadingMinimumWidth: leadingMinimumWidth,
            trailingMinimumWidth: trailingMinimumWidth
        ) {
            content()
        }
    }
}

/// The parts of the Minimal address that `MinimalAddressPlacement` places.
private enum MinimalAddressPart {
    /// Spans the whole unit, behind the others.
    case unit
    /// Span an empty section's reserve.
    case leadingSection, trailingSection
    case leading, text, trailing
}

private struct MinimalAddressPartKey: LayoutValueKey {
    static let defaultValue = MinimalAddressPart.text
}

/// Fills the Minimal address bar's slot and centers the unit (leading
/// buttons, address text, trailing buttons) on `centerX`, in the slot's own
/// coordinates, through `MinimalAddressLayout.unit`. The buttons keep their
/// size; only the text truncates.
private struct MinimalAddressPlacement: Layout {
    var centerX: CGFloat
    /// What each section draws only while customizing; it extends outward.
    var leadingCustomizeOnlyWidth: CGFloat
    var trailingCustomizeOnlyWidth: CGFloat
    /// An empty section's reserve while customizing; zero otherwise.
    var leadingMinimumWidth: CGFloat
    var trailingMinimumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews
            .filter { ![.unit, .leadingSection, .trailingSection].contains($0[MinimalAddressPartKey.self]) }
            .reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 26
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func part(_ part: MinimalAddressPart) -> LayoutSubview? {
            subviews.first { $0[MinimalAddressPartKey.self] == part }
        }
        let leading = part(.leading)
        let text = part(.text)
        let trailing = part(.trailing)
        let leadingWidth = leading?.sizeThatFits(.unspecified).width ?? 0
        let trailingWidth = trailing?.sizeThatFits(.unspecified).width ?? 0
        let textWidth = text?.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width ?? 0
        let unit = MinimalAddressLayout.unit(
            leadingWidth: leadingWidth,
            textWidth: textWidth,
            trailingWidth: trailingWidth,
            centerX: bounds.minX + centerX,
            freeMinX: bounds.minX,
            freeMaxX: bounds.maxX,
            leadingCustomizeOnlyWidth: leadingCustomizeOnlyWidth,
            trailingCustomizeOnlyWidth: trailingCustomizeOnlyWidth,
            leadingMinimumWidth: leadingMinimumWidth,
            trailingMinimumWidth: trailingMinimumWidth
        )

        func place(_ subview: LayoutSubview?, minX: CGFloat, width: CGFloat) {
            subview?.place(
                at: CGPoint(x: minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
        place(part(.unit), minX: unit.minX, width: unit.width)
        place(part(.leadingSection), minX: unit.minX, width: unit.leadingWidth)
        place(part(.trailingSection), minX: unit.trailingMinX, width: unit.trailingWidth)
        // Right before the text: a reserve wider than the buttons lies outside them.
        place(leading, minX: unit.textMinX - leadingWidth, width: leadingWidth)
        place(text, minX: unit.textMinX, width: unit.textWidth)
        place(trailing, minX: unit.trailingMinX, width: unit.trailingWidth)
    }
}

private struct AddressBarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AddressBarProgressBarView: View {
    let progress: Double
    let isVisible: Bool
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let clampedProgress = min(max(progress, 0), 1)
            let progressWidth = width * clampedProgress
            let baseColor = ThemedColor.themeColor.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
            let backgroundColor = ThemedColor.windowBackground.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
            let fadeStart: Double = 0.3
            let fadeRange: Double = 0.2
            let gradientOpacity = max(0, min(1, (clampedProgress - fadeStart) / fadeRange))

            ZStack(alignment: .leading) {
                if isVisible && clampedProgress > 0 {
                    Capsule()
                        .fill(baseColor)
                        .frame(width: progressWidth, height: height)
                        .opacity(1 - gradientOpacity)

                    LinearGradient(
                        colors: [backgroundColor, baseColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: progressWidth, height: height)
                    .clipShape(Capsule())
                    .opacity(gradientOpacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: clampedProgress)
        }
    }
}

#if DEBUG
#Preview("AddressBar Progress States") {
    let arrangement = ToolbarArrangement.standard
    let actions = ToolbarItemActions(
        onSidebarTap: {}, onBackTap: {}, onForwardTap: {}, onRefreshTap: {},
        onStopLoadingTap: {}, onChatTap: {}, onFeedbackTap: {}, onMemoryTap: {},
        onDownloadTap: {},
        downloadViewModel: DownloadButtonViewModel(),
        isExtensionPopoverShown: .constant(false),
        visibleExtensions: []
    )
    return VStack(spacing: 12) {
        ForEach([(0.1, true), (0.6, true), (0.9, true), (1.0, false)], id: \.0) { progress, isLoading in
            WebContentAddressBarView(
                browserState: nil,
                currentTab: nil,
                showBackgroundWhenInactive: false,
                loadingProgress: progress,
                isLoading: isLoading,
                leading: arrangement.placements(in: .addressLeading),
                trailing: arrangement.placements(in: .addressTrailing),
                isCustomizing: false,
                itemActions: actions,
                headerState: WebContentHeaderState(),
                onOpenLocationBar: { _ in }
            )
            .frame(height: 26)
        }
    }
    .padding()
}
#endif
