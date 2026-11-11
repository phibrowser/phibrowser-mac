// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI
import SnapKit

// MARK: - Helper Views

/// A hosting view that lets mouse events pass through to its parent.
class HitTransparentHostingView<Content: View>: ZeroSafeAreaHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so that clicks pass through to TabItemView
        return nil
    }
}

private final class TabItemPageAppearanceState: ObservableObject {
    @Published var appearance: Appearance?

    init(appearance: Appearance? = nil) {
        self.appearance = appearance
    }
}

private struct TabItemPageAppearanceModifier: ViewModifier {
    @ObservedObject private var state: TabItemPageAppearanceState
    @Environment(\.phiAppearance) private var inheritedAppearance
    @Environment(\.colorScheme) private var inheritedColorScheme

    init(state: TabItemPageAppearanceState) {
        _state = ObservedObject(wrappedValue: state)
    }

    func body(content: Content) -> some View {
        let appearance = state.appearance ?? inheritedAppearance
        let colorScheme = state.appearance.map { $0.isDark ? ColorScheme.dark : .light }
            ?? inheritedColorScheme
        content
            .environment(\.phiAppearance, appearance)
            .environment(\.colorScheme, colorScheme)
    }
}

final class TabItemView: NSView {
    static let statusBadgeViewIdentifier = NSUserInterfaceItemIdentifier("tabStripStatusBadge")

    // MARK: - Types

    private enum LayoutMode {
        case pinned
        case compact
        case normal
    }

    func resetHoverState(immediately: Bool = false) {
        if isHovered {
            isHovered = false
        }
        if immediately {
            cancelPreviewForInteraction()
        }
        viewModel.isPressed = false
    }

    // MARK: - Public Properties

    var shouldSelectOnMouseDown: (() -> Bool)?
    private var selectedOnMouseDown = false

    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleSelect: ((NSEvent.ModifierFlags) -> Void)?
    /// Fires for merged split cells when the click falls on one of the other
    /// panes' columns, with that pane's tab. The host pane (`sourceTab`) and
    /// standalone tabs route every click through `onSelect`; a cell whose
    /// owner leaves this nil routes every click through `onSelect` too.
    var onPaneSelect: ((Tab, NSEvent.ModifierFlags) -> Void)?
    var onPaneDoubleSelect: ((Tab, NSEvent.ModifierFlags) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    /// Called when a drag begins from this tab view.
    var onDragStart: ((NSEvent) -> Void)?
    /// Called when the drag position updates.
    var onDragUpdate: ((NSEvent) -> Void)?
    /// Called when the drag ends.
    var onDragEnd: (() -> Void)?

    // MARK: - Private Properties

    private var currentTabId: String?
    private weak var sourceTab: Tab?
    private let tabPreviewRegistration = TabPreviewRegistration()
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    private var showsTabPreview = false
    private var isTabPreviewEligible = false
    private var isSplitTabPreviewEligible = false
    private var cancellables = Set<AnyCancellable>()
    private var themeObservation: AnyObject?
    private var themeObserver = ThemeObserver.shared
    private let pageAppearanceState = TabItemPageAppearanceState()

    private let backgroundLayer = TabBackgroundLayer()
    
    // Unified Data Layer
    private let viewModel = TabViewModel()

    // MARK: - Drag Gesture State
    private var isDraggingInternal = false
    private var mouseDownPoint: CGPoint?
    private var mouseDownLocationInWindow: CGPoint?
    private var mouseDownModifierFlags: NSEvent.ModifierFlags?

    // MARK: - Tracking Area
    private var hoverTrackingArea: NSTrackingArea?

    // MARK: - State

    private var isActive = false
    private var activePageBackgroundColor: NSColor?
    private var activePageAppearance: Appearance?
    private var isMultiSelected = false
    private var isPinned = false
    /// The pane count the status badge was last built for (0 = a plain cell).
    private var statusBadgeMergedPaneCount = 0

    /// Views and bindings for one non-host pane of a merged split cell. The
    /// host pane (`sourceTab`) renders through the cell's own favicon,
    /// title, mute and close views; every other pane gets one of these,
    /// created on demand by `makeMergedPaneViews()` and kept in
    /// `mergedPanePool` for reuse across configures. Its view model carries
    /// the pane's bindings so favicon, title and audio updates flow
    /// independently of the host's.
    @MainActor
    private final class MergedPaneViews {
        weak var tab: Tab?
        let viewModel = TabViewModel()
        let faviconHostingView = HitTransparentHostingView(rootView: AnyView(EmptyView()))
        let titleHostingView = HitTransparentHostingView(rootView: AnyView(EmptyView()))
        let muteButtonHostingView = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
        let closeButtonHostingView = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
        /// Thin vertical line on the pane's leading edge, separating it from
        /// the pane before it. Sizing + color mirror the tab↔tab separator
        /// (`TabStripMetrics.Content.separator*`) so the divider inside a
        /// merged cell reads as the same affordance as the divider between
        /// any two normal tabs.
        let dividerView = NSView()

        var hostingViews: [NSView] {
            [faviconHostingView, muteButtonHostingView, titleHostingView, closeButtonHostingView]
        }

        var views: [NSView] { hostingViews + [dividerView] }

        var showsMute: Bool { viewModel.isCurrentlyAudible || viewModel.isMuted }
    }

    /// Pane view sets created so far, host excluded. Entries past
    /// `mergedPaneCount` are idle (hidden, unbound) and reused by the next
    /// configure that needs them.
    private var mergedPanePool: [MergedPaneViews] = []
    /// How many pool entries are in use: the other panes of the merged split
    /// this cell hosts (`TabRenderData.mergedSplitPanes`). 0 for a
    /// standalone tab.
    private var mergedPaneCount = 0
    private var mergedPanes: ArraySlice<MergedPaneViews> { mergedPanePool.prefix(mergedPaneCount) }
    private var isMergedSplitCell: Bool { mergedPaneCount > 0 }
    /// Panes rendered by this cell, host included.
    private var paneCount: Int { 1 + mergedPaneCount }
    private var isDragHighlighted = false {
        didSet {
            guard oldValue != isDragHighlighted else { return }
            updateAppearance()
        }
    }
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            tabPreviewRegistration.setHovering(isHovered)
            splitTabPreviewRegistration.setHovering(isHovered)
            onHoverChanged?(isHovered)
            updateAppearance()
            layoutContent()
        }
    }

    // MARK: - Subviews

    // Favicon & Title (Non-interactive parts)
    private lazy var faviconHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(rootView: makeFaviconRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    private lazy var openIndicatorHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(
            rootView: AnyView(TabOpenIndicatorView().phiThemeObserver(themeObserver))
        )
        view.layer?.backgroundColor = .clear
        view.isHidden = true
        return view
    }()

    private lazy var titleHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(rootView: makeTitleRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    /// Cell-level Sidecar/agent status. A merged split still exposes one badge
    /// for the whole cell, using the same cross-pane priority as sidebar split
    /// cells. The host is decorative so it never intercepts tab interaction.
    private lazy var statusBadgeHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(
            rootView: makeStatusBadgeRootView(mergedPaneCount: 0)
        )
        view.identifier = Self.statusBadgeViewIdentifier
        view.layer?.backgroundColor = .clear
        return view
    }()

    // Interactive Components (Must be interactive)
    private lazy var muteButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeMuteButtonRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    private lazy var recordingIconHostingView: TabRecordingIconHostingView = {
        let view = TabRecordingIconHostingView { [weak self] in
            self?.makeRecordingIconRootView() ?? AnyView(EmptyView())
        }
        view.layer?.backgroundColor = .clear
        return view
    }()

    private lazy var closeButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeCloseButtonRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    // MARK: - Computed Properties

    private var layoutMode: LayoutMode {
        if isPinned { return .pinned }
        let compactThreshold = isMergedSplitCell
            ? TabStripMetrics.Content.splitCompactModeThreshold(paneCount: paneCount)
            : TabStripMetrics.Content.compactModeThreshold
        if bounds.width < compactThreshold { return .compact }
        return .normal
    }

    private var shouldShowCloseButton: Bool {
        // Merged split cells expose one close button per pane; all fade in
        // on hover. Each `MergedPaneViews.closeButtonHostingView` closes
        // its own pane's tab.
        layoutMode == .normal && isHovered
    }

    /// Horizontal extent of pane `index` (0 = host) when the merged cell
    /// lays its panes out as equal columns.
    private func paneColumn(_ index: Int) -> (minX: CGFloat, maxX: CGFloat) {
        let width = bounds.width / CGFloat(paneCount)
        return (width * CGFloat(index), width * CGFloat(index + 1))
    }

    /// The non-host pane whose column contains `point`, or nil when the
    /// point falls in the host column or the cell is not a merged split.
    private func mergedPane(at point: CGPoint) -> MergedPaneViews? {
        guard isMergedSplitCell, bounds.width > 0 else { return nil }
        let column = Int(point.x / (bounds.width / CGFloat(paneCount)))
        let index = max(0, min(paneCount - 1, column))
        guard index > 0 else { return nil }
        return mergedPanePool[index - 1]
    }

    /// True when `point` lands on a visible close button of any pane.
    private func isOnCloseButton(_ point: CGPoint) -> Bool {
        if !closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(point) {
            return true
        }
        return mergedPanes.contains {
            !$0.closeButtonHostingView.isHidden && $0.closeButtonHostingView.frame.contains(point)
        }
    }

    /// The non-host pane whose visible mute toggle contains `point`.
    private func mergedPaneWithMuteButton(at point: CGPoint) -> MergedPaneViews? {
        mergedPanes.first {
            !$0.muteButtonHostingView.isHidden && $0.muteButtonHostingView.frame.contains(point)
        }
    }

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        setupUI()
        bindTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    // MARK: - Setup

    private func setupUI() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
        wantsLayer = true
        layer?.masksToBounds = false
        backgroundLayer.sourceView = self
        layer?.insertSublayer(backgroundLayer, at: 0)
        tabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            self?.isTabPreviewEligible = isEligible
            self?.updatePreviewEligibility()
        }
        splitTabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            self?.isSplitTabPreviewEligible = isEligible
            self?.updatePreviewEligibility()
        }

        addSubview(faviconHostingView)
        addSubview(openIndicatorHostingView)
        addSubview(muteButtonHostingView)
        addSubview(recordingIconHostingView)
        addSubview(titleHostingView)
        addSubview(statusBadgeHostingView)
        addSubview(closeButtonHostingView)
    }

    /// Creates the view set for one more non-host pane and installs it
    /// below the status badge so the badge stays on top of pane content.
    private func makeMergedPaneViews() -> MergedPaneViews {
        let pane = MergedPaneViews()
        pane.faviconHostingView.rootView = makeThemedRootView(
            UnifiedTabFaviconView(viewModel: pane.viewModel)
        )
        pane.titleHostingView.rootView = makeThemedRootView(
            UnifiedTabTitleView(viewModel: pane.viewModel)
        )
        pane.muteButtonHostingView.rootView = makeThemedRootView(
            UnifiedTabMuteButton(viewModel: pane.viewModel)
        )
        // Closes this pane's own tab, not the host's.
        pane.closeButtonHostingView.rootView = makeThemedRootView(
            UnifiedTabCloseButton { [weak self, weak pane] in
                self?.cancelPreviewForInteraction()
                pane?.tab?.close()
            }
        )
        for view in pane.hostingViews {
            view.layer?.backgroundColor = .clear
        }
        pane.dividerView.wantsLayer = true
        pane.dividerView.phiLayer?.setBackgroundColor(TabStripMetrics.Content.separatorColor)
        for view in pane.views {
            view.isHidden = true
            addSubview(view, positioned: .below, relativeTo: statusBadgeHostingView)
        }
        return pane
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            tabPreviewRegistration.invalidate()
            splitTabPreviewRegistration.invalidate()
            return
        }
        themeObserver.rebind(to: themeStateProvider)
    }

    // MARK: - Constants

    private let muteButtonSize = CGSize(width: 16, height: 16)
    private let recordingIconSize = CGSize(width: 14, height: 14)
    private let defaultMergedFaviconGap: CGFloat = 2
    private let separatedMergedFaviconGap: CGFloat = 7

    private var mergedFaviconGap: CGFloat {
        guard let sourceTab, isMergedSplitCell else { return defaultMergedFaviconGap }
        let paneTabs = [sourceTab] + mergedPanes.compactMap(\.tab)
        guard paneTabs.count == paneCount else { return defaultMergedFaviconGap }
        let allShowOutlines = paneTabs.allSatisfy {
            TabFaviconPresentation.showsDashedOutline(
                isDiscarded: $0.isDiscarded,
                isUnloaded: $0.isUnloaded
            )
        }
        return allShowOutlines ? separatedMergedFaviconGap : defaultMergedFaviconGap
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        backgroundLayer.updatePath(in: bounds)
        CATransaction.commit()

        layoutContent()
    }

    private func centeredFrame(for size: CGSize) -> CGRect {
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func layoutFaviconAndMedia(mode: LayoutMode) -> CGFloat {
        let metrics = TabStripMetrics.Content.self
        let showRecording = viewModel.isCapturingMedia
        let showMute = viewModel.isCurrentlyAudible || viewModel.isMuted
        let centerY = bounds.height / 2
        let panes = Array(mergedPanes)

        // Pane mute toggles only render inside merged split cells; reset
        // to hidden up front so recycled cells transitioning into non-split
        // modes never leak another pane's mute icon.
        for pane in mergedPanePool {
            pane.muteButtonHostingView.isHidden = true
        }
        openIndicatorHostingView.isHidden = true
        openIndicatorHostingView.alphaValue = TabFaviconPresentation.opacity(
            isDiscarded: sourceTab?.isDiscarded == true
                || panes.contains { $0.tab?.isDiscarded == true },
            isUnloaded: sourceTab?.isUnloaded == true
                || panes.contains { $0.tab?.isUnloaded == true }
        )
        // Pinned and compact cells show recording as the centered icon below
        // and hide every favicon; drop their corner badges with them.
        let hidesRecordingBadges = showRecording && mode != .normal
        viewModel.hidesRecordingBadge = hidesRecordingBadges
        for pane in panes {
            pane.viewModel.hidesRecordingBadge = hidesRecordingBadges
        }
        let hideAllFavicons = {
            self.faviconHostingView.isHidden = true
            for pane in panes { pane.faviconHostingView.isHidden = true }
        }

        switch mode {
        case .pinned, .compact:
            // Pinned/compact cells never carry the dividers; reset so a
            // recycled view that previously rendered a normal-mode split
            // doesn't leak its column decorations.
            for pane in mergedPanePool {
                pane.dividerView.isHidden = true
            }
            // Merged cells surface ANY pane's audio state as ONE centered
            // glyph for the whole cell. Per-pane glyphs were tried and read
            // wrong: [favicon][speaker] mimics a normal tab's "favicon + its
            // indicator" row, misattributing another pane's sound to the
            // first pane. The glyph and its mute toggle bind to the first
            // pane in slot order that carries the state, the host first.
            // Host recording still outranks audio (single-tab precedence).
            // While a centered glyph is up, the favicons — and the per-pane
            // recording corner badges they carry — are hidden, so a narrow
            // cell shows at most one state at a time by design.
            let audiblePane = panes.first { $0.showsMute }
            if showRecording {
                recordingIconHostingView.isHidden = false
                recordingIconHostingView.frame = centeredFrame(for: recordingIconSize)
                hideAllFavicons()
                muteButtonHostingView.isHidden = true
            } else if showMute {
                muteButtonHostingView.isHidden = false
                muteButtonHostingView.frame = centeredFrame(for: muteButtonSize)
                hideAllFavicons()
                recordingIconHostingView.isHidden = true
            } else if let audiblePane {
                audiblePane.muteButtonHostingView.isHidden = false
                audiblePane.muteButtonHostingView.frame = centeredFrame(for: muteButtonSize)
                hideAllFavicons()
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            } else if isMergedSplitCell {
                // One favicon per pane inside one pinned/compact cell. Stack
                // them horizontally around the cell's center so the cell
                // still occupies a single slot in the strip's layout.
                let iconSize = metrics.faviconSize
                let gap = mergedFaviconGap
                let rowWidth = iconSize.width * CGFloat(paneCount)
                    + gap * CGFloat(paneCount - 1)
                var iconX = (bounds.width - rowWidth) / 2
                let iconY = centerY - iconSize.height / 2
                faviconHostingView.isHidden = false
                faviconHostingView.frame = CGRect(
                    x: iconX,
                    y: iconY,
                    width: iconSize.width,
                    height: iconSize.height
                )
                var rowFrame = faviconHostingView.frame
                for pane in panes {
                    iconX += iconSize.width + gap
                    pane.faviconHostingView.isHidden = false
                    pane.faviconHostingView.frame = CGRect(
                        x: iconX,
                        y: iconY,
                        width: iconSize.width,
                        height: iconSize.height
                    )
                    rowFrame = rowFrame.union(pane.faviconHostingView.frame)
                }
                if shouldShowOpenIndicator {
                    openIndicatorHostingView.isHidden = false
                    openIndicatorHostingView.frame = openIndicatorFrame(
                        below: rowFrame,
                        centerX: bounds.midX
                    )
                }
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            } else {
                faviconHostingView.isHidden = false
                faviconHostingView.frame = centeredFrame(for: metrics.faviconSize)
                if shouldShowOpenIndicator {
                    openIndicatorHostingView.isHidden = false
                    openIndicatorHostingView.frame = openIndicatorFrame(
                        below: faviconHostingView.frame
                    )
                }
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            }
            return 0

        case .normal:
            // Merged split cell: render one equal column per pane (favicon +
            // title each), each non-host column led by a vertical divider.
            // Each pane carries its own mute toggle so audible state stays
            // addressable per-pane; recording also shows per-pane, as the
            // corner badge UnifiedTabFaviconView overlays on each favicon —
            // only the dedicated centered recording icon is dropped here.
            if isMergedSplitCell {
                faviconHostingView.isHidden = false
                faviconHostingView.frame = CGRect(
                    x: metrics.faviconLeading,
                    y: centerY - metrics.faviconSize.height / 2,
                    width: metrics.faviconSize.width,
                    height: metrics.faviconSize.height
                )
                muteButtonHostingView.isHidden = !showMute
                if showMute {
                    muteButtonHostingView.frame = CGRect(
                        x: faviconHostingView.frame.maxX + metrics.titleToFavicon,
                        y: centerY - muteButtonSize.height / 2,
                        width: muteButtonSize.width,
                        height: muteButtonSize.height
                    )
                }
                let sepSize = TabStripMetrics.Content.separatorSize
                for (offset, pane) in panes.enumerated() {
                    let column = paneColumn(offset + 1)
                    pane.dividerView.isHidden = false
                    pane.dividerView.frame = CGRect(
                        x: column.minX - sepSize.width / 2,
                        y: (bounds.height - sepSize.height) / 2,
                        width: sepSize.width,
                        height: sepSize.height
                    )
                    pane.faviconHostingView.isHidden = false
                    pane.faviconHostingView.frame = CGRect(
                        x: column.minX + metrics.faviconLeading,
                        y: centerY - metrics.faviconSize.height / 2,
                        width: metrics.faviconSize.width,
                        height: metrics.faviconSize.height
                    )
                    let paneShowsMute = pane.showsMute
                    pane.muteButtonHostingView.isHidden = !paneShowsMute
                    if paneShowsMute {
                        pane.muteButtonHostingView.frame = CGRect(
                            x: pane.faviconHostingView.frame.maxX + metrics.titleToFavicon,
                            y: centerY - muteButtonSize.height / 2,
                            width: muteButtonSize.width,
                            height: muteButtonSize.height
                        )
                    }
                }
                recordingIconHostingView.isHidden = true
                return faviconHostingView.frame.maxX + metrics.titleToFavicon
            }

            faviconHostingView.isHidden = false
            for pane in mergedPanePool {
                pane.faviconHostingView.isHidden = true
                pane.titleHostingView.isHidden = true
                pane.dividerView.isHidden = true
            }
            faviconHostingView.frame = CGRect(
                x: metrics.faviconLeading,
                y: centerY - metrics.faviconSize.height / 2,
                width: metrics.faviconSize.width,
                height: metrics.faviconSize.height
            )

            var currentX = faviconHostingView.frame.maxX + metrics.titleToFavicon

            muteButtonHostingView.isHidden = !showMute
            if showMute {
                muteButtonHostingView.frame = CGRect(
                    x: currentX,
                    y: centerY - muteButtonSize.height / 2,
                    width: muteButtonSize.width,
                    height: muteButtonSize.height
                )
                currentX = muteButtonHostingView.frame.maxX + metrics.titleToFavicon
            }
            // recording status showed as badge of favicon
            recordingIconHostingView.isHidden = true
            return currentX
        }
    }

    private func layoutContent() {
        guard !bounds.isEmpty else {
            hideContentForEmptyBounds()
            return
        }

        let metrics = TabStripMetrics.Content.self
        let mode = layoutMode
        viewModel.isHorizontalCompactMode = (mode == .compact || mode == .pinned)
        // Mirror onto every other pane's view model: their mute buttons
        // share the same "non-interactive in compact unless focused" gate,
        // and one can render centered in a compact merged cell.
        for pane in mergedPanes {
            pane.viewModel.isHorizontalCompactMode = viewModel.isHorizontalCompactMode
        }

        let titleStartX = layoutFaviconAndMedia(mode: mode)

        switch mode {
        case .pinned, .compact:
            // Reset every pane's title/close as well: a merged split cell
            // shrinking out of normal mode would otherwise keep their stale
            // frames and paint a pane's title over neighboring tabs.
            titleHostingView.isHidden = true
            closeButtonHostingView.isHidden = true
            for pane in mergedPanePool {
                pane.titleHostingView.isHidden = true
                pane.closeButtonHostingView.isHidden = true
            }

        case .normal:
            // Close buttons: one per pane for a merged split cell (all
            // visible on hover), single button for a regular tab.
            if isMergedSplitCell {
                layoutMergedPaneText(
                    column: paneColumn(0),
                    faviconView: faviconHostingView,
                    muteView: muteButtonHostingView,
                    titleView: titleHostingView,
                    closeView: closeButtonHostingView
                )
                for (offset, pane) in mergedPanes.enumerated() {
                    layoutMergedPaneText(
                        column: paneColumn(offset + 1),
                        faviconView: pane.faviconHostingView,
                        muteView: pane.muteButtonHostingView,
                        titleView: pane.titleHostingView,
                        closeView: pane.closeButtonHostingView
                    )
                }
            } else {
                closeButtonHostingView.isHidden = !shouldShowCloseButton
                closeButtonHostingView.frame = CGRect(
                    x: bounds.width - metrics.closeButtonTrailing - metrics.closeButtonSize.width,
                    y: (bounds.height - metrics.closeButtonSize.height) / 2,
                    width: metrics.closeButtonSize.width,
                    height: metrics.closeButtonSize.height
                )
                titleHostingView.isHidden = false
                for pane in mergedPanePool {
                    pane.titleHostingView.isHidden = true
                    pane.closeButtonHostingView.isHidden = true
                }
                let titleMaxX = shouldShowCloseButton
                    ? closeButtonHostingView.frame.minX - metrics.titleToCloseButton
                    : bounds.width - metrics.titleTrailing
                titleHostingView.frame = CGRect(
                    x: titleStartX,
                    y: (bounds.height - metrics.titleHeight) / 2,
                    width: max(0, titleMaxX - titleStartX),
                    height: metrics.titleHeight
                )
            }
        }

        layoutStatusBadge()
        updatePaneToolTips(mode: mode)
    }

    /// Lays out one pane's title and hover close button inside its column
    /// of a merged cell (normal mode). The title is clipped against the
    /// close button when hovered; when the pane carries a mute icon, the
    /// title starts past it so the speaker glyph and the page name don't
    /// overlap.
    private func layoutMergedPaneText(
        column: (minX: CGFloat, maxX: CGFloat),
        faviconView: NSView,
        muteView: NSView,
        titleView: NSView,
        closeView: NSView
    ) {
        let metrics = TabStripMetrics.Content.self
        let closeFrame = CGRect(
            x: column.maxX - metrics.closeButtonTrailing - metrics.closeButtonSize.width,
            y: (bounds.height - metrics.closeButtonSize.height) / 2,
            width: metrics.closeButtonSize.width,
            height: metrics.closeButtonSize.height
        )
        // A pane too narrow for both controls drops its close button in
        // favor of the mute toggle — stacked on top of the speaker glyph, a
        // "mute" click would close the pane.
        let showClose = shouldShowCloseButton
            && (muteView.isHidden || closeFrame.minX >= muteView.frame.maxX)
        closeView.isHidden = !showClose
        closeView.frame = closeFrame

        let titleStart = (muteView.isHidden ? faviconView : muteView).frame.maxX
            + metrics.titleToFavicon
        let titleMax = showClose
            ? closeFrame.minX - metrics.titleToCloseButton
            : column.maxX - metrics.titleTrailing
        titleView.isHidden = false
        titleView.frame = CGRect(
            x: titleStart,
            y: (bounds.height - metrics.titleHeight) / 2,
            width: max(0, titleMax - titleStart),
            height: metrics.titleHeight
        )
    }

    private func layoutStatusBadge() {
        let size = TabCornerBadgeMetrics.visualSize
        let overhang = TabCornerBadgeMetrics.overhang
        let y = isFlipped
            ? bounds.minY - overhang
            : bounds.maxY - size + overhang
        statusBadgeHostingView.isHidden = false
        statusBadgeHostingView.frame = CGRect(
            x: bounds.maxX - size + overhang,
            y: y,
            width: size,
            height: size
        )
    }

    private func hideContentForEmptyBounds() {
        let ownViews: [NSView] = [
            faviconHostingView,
            openIndicatorHostingView,
            muteButtonHostingView,
            recordingIconHostingView,
            titleHostingView,
            statusBadgeHostingView,
            closeButtonHostingView,
        ]
        for view in ownViews + mergedPanePool.flatMap(\.views) {
            view.isHidden = true
            view.frame = .zero
        }
        // SwiftUI keeps animating a hidden host's recording badge.
        viewModel.hidesRecordingBadge = true
        for pane in mergedPanePool {
            pane.viewModel.hidesRecordingBadge = true
        }
        removePaneToolTips()
    }

    // MARK: - Appearance

    private func updateAppearance(animatesPageColor: Bool = false) {
        let pageAppearance = isActive && !isPinned ? activePageAppearance : nil
        if appearance?.phiAppearance != pageAppearance {
            appearance = pageAppearance?.nsAppearance
        }
        if pageAppearanceState.appearance != pageAppearance {
            pageAppearanceState.appearance = pageAppearance
        }

        backgroundLayer.isPinned = isPinned
        backgroundLayer.setActiveFillColor(
            isPinned ? nil : activePageBackgroundColor,
            animated: animatesPageColor
        )

        if isActive {
            backgroundLayer.tabState = .active
            layer?.zPosition = 10
        } else if isMultiSelected {
            // Sub-selection is a persistent state and must win over the
            // transient hover background, otherwise a Cmd+click on a hovered
            // tab shows no visible change.
            backgroundLayer.tabState = .subSelected
            layer?.zPosition = 0
        } else if isHovered || isDragHighlighted {
            backgroundLayer.tabState = .hovered
            layer?.zPosition = 5
        } else {
            backgroundLayer.tabState = .inactive
            layer?.zPosition = 0
        }
        
        backgroundLayer.refreshAppearance()
    }

    func setActivePageStyle(backgroundColor: NSColor?, appearance: Appearance?, animated: Bool = false) {
        guard activePageBackgroundColor != backgroundColor
                || activePageAppearance != appearance else { return }
        activePageBackgroundColor = backgroundColor
        activePageAppearance = appearance
        updateAppearance(animatesPageColor: animated)
    }

    private var shouldShowOpenIndicator: Bool {
        isPinned && TabFaviconPresentation.showsOpenIndicator(
            isOpened: sourceTab?.hasWebContent == true
                || mergedPanes.contains { $0.tab?.hasWebContent == true },
            isActive: isActive
        )
    }

    private func openIndicatorFrame(
        below faviconFrame: CGRect,
        centerX: CGFloat? = nil
    ) -> CGRect {
        let diameter = TabOpenIndicatorMetrics.diameter
        let y = isFlipped
            ? faviconFrame.maxY + TabOpenIndicatorMetrics.comfortablePinnedSpacing
            : faviconFrame.minY
                - TabOpenIndicatorMetrics.comfortablePinnedSpacing
                - diameter
        return CGRect(
            x: (centerX ?? faviconFrame.midX) - diameter / 2,
            y: y,
            width: diameter,
            height: diameter
        )
    }
    
    private func bindTheme() {
        themeObservation = subscribe { [weak self] _, _ in
            self?.backgroundLayer.refreshAppearance()
        }
    }

    private func makeThemedRootView<Content: View>(_ content: Content) -> AnyView {
        AnyView(
            content
                .modifier(TabItemPageAppearanceModifier(state: pageAppearanceState))
                .phiThemeObserver(themeObserver)
        )
    }
    
    private func makeFaviconRootView() -> AnyView {
        makeThemedRootView(
            UnifiedTabFaviconView(viewModel: viewModel)
        )
    }

    private func updateStatusBadgeContent() {
        // One badge for the whole merged cell, fed by every pane's status
        // model; rebuilt when the cell's pane count changes.
        let mergedPaneCountForBadge = isMergedSplitCell ? mergedPaneCount : 0
        guard mergedPaneCountForBadge != statusBadgeMergedPaneCount else { return }
        statusBadgeMergedPaneCount = mergedPaneCountForBadge
        statusBadgeHostingView.rootView = makeStatusBadgeRootView(
            mergedPaneCount: mergedPaneCountForBadge
        )
    }

    private func makeStatusBadgeRootView(mergedPaneCount: Int) -> AnyView {
        // Pool entries are stable across configures, so binding the badge to
        // their status models once per pane count is enough; each model is
        // rebound to whichever tab occupies that pane.
        if mergedPaneCount > 0 {
            let models = [viewModel.status]
                + mergedPanePool.prefix(mergedPaneCount).map { $0.viewModel.status }
            return makeThemedRootView(MergedTabCornerBadgeView(models: models))
        }
        return makeThemedRootView(TabCornerBadgeView(model: viewModel.status))
    }

    private func makeTitleRootView() -> AnyView {
        makeThemedRootView(UnifiedTabTitleView(viewModel: viewModel))
    }

    private func makeMuteButtonRootView() -> AnyView {
        makeThemedRootView(UnifiedTabMuteButton(viewModel: viewModel))
    }

    private func makeRecordingIconRootView() -> AnyView {
        makeThemedRootView(UnifiedTabRecordingIcon())
    }

    private func makeCloseButtonRootView() -> AnyView {
        makeThemedRootView(
            UnifiedTabCloseButton { [weak self] in
                self?.cancelPreviewForInteraction()
                self?.sourceTab?.close()
            }
        )
    }

    // MARK: - Configuration

    func configure(with data: TabRenderData, browserState: BrowserState? = nil) {
        cancellables.removeAll()
        TabFaviconPresentation.dimmingEnabledPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.layoutContent()
            }
            .store(in: &cancellables)

        currentTabId = data.id
        isActive = data.isActive
        isMultiSelected = data.isMultiSelected
        isPinned = data.isPinned
        sourceTab = data.sourceTab
        faviconHostingView.rootView = makeFaviconRootView()
        configureMergedPanes(data.mergedSplitPanes, browserState: browserState)
        backgroundLayer.splitPanePosition = data.splitPanePosition
        backgroundLayer.isSplitGroupActive = data.isSplitGroupActive

        if let tab = data.sourceTab,
           let browserState,
           let splitTarget = SplitTabPreviewTarget.make(representing: tab, in: browserState) {
            tabPreviewRegistration.invalidate()
            splitTabPreviewRegistration.configure(
                anchorView: self,
                target: splitTarget,
                browserState: browserState,
                placement: .belowAttached
            )
        } else if let tab = data.sourceTab, let browserState {
            splitTabPreviewRegistration.invalidate()
            tabPreviewRegistration.configure(
                anchorView: self,
                target: .tab(tab),
                browserState: browserState,
                placement: .belowAttached
            )
        } else {
            tabPreviewRegistration.invalidate()
            splitTabPreviewRegistration.invalidate()
        }

        updateStatusBadgeContent()

        updateAppearance()
        
        if let tab = data.sourceTab {
            viewModel.configure(with: tab, in: browserState)
            viewModel.onToggleMute = { [weak tab] in
                guard let tab else { return }
                tab.toggleAudioMuted()
            }
            
            viewModel.onToolTipUpdated = { [weak self] in
                self?.updateTitleHostingToolTips()
            }
            
            updateTitleHostingToolTips()

            // Listen for state changes to trigger re-layout
            Publishers.CombineLatest3(tab.$isCapturingAudio, tab.$isCapturingVideo, tab.$isSharingScreen)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)
            
            tab.$isCurrentlyAudible
                .combineLatest(tab.audioMutePublisher)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)

            tab.$hasWebContent
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)

            Publishers.CombineLatest(tab.$isDiscarded, tab.$isUnloaded)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)
        }

        // Same re-layout triggers for every other pane so its mute icon
        // appears / disappears in sync with that tab's audio state, matching
        // the host pane's behavior above.
        for paneTab in mergedPanes.compactMap(\.tab) {
            paneTab.$isCurrentlyAudible
                .combineLatest(paneTab.audioMutePublisher)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)

            paneTab.$hasWebContent
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)

            Publishers.CombineLatest(paneTab.$isDiscarded, paneTab.$isUnloaded)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)
        }

        layoutContent()
    }

    /// Binds one pool entry per non-host pane of a merged split (growing
    /// the pool on demand) and parks the rest: their view models drop the
    /// Combine subscriptions `configure(with:)` took on the previous tab
    /// and their views hide, so a recycled cell never shows a stale pane.
    private func configureMergedPanes(_ panes: [Tab], browserState: BrowserState?) {
        mergedPaneCount = panes.count
        while mergedPanePool.count < panes.count {
            mergedPanePool.append(makeMergedPaneViews())
        }
        for (index, pane) in mergedPanePool.enumerated() {
            guard index < panes.count else {
                pane.tab = nil
                pane.viewModel.cancelSubscriptions()
                pane.viewModel.onToggleMute = nil
                pane.viewModel.onToolTipUpdated = nil
                for view in pane.views {
                    view.isHidden = true
                }
                continue
            }
            let tab = panes[index]
            pane.tab = tab
            pane.faviconHostingView.rootView = makeThemedRootView(
                UnifiedTabFaviconView(viewModel: pane.viewModel)
            )
            pane.viewModel.configure(with: tab, in: browserState)
            pane.viewModel.onToggleMute = { [weak tab] in
                tab?.toggleAudioMuted()
            }
            pane.viewModel.onToolTipUpdated = { [weak self] in
                self?.updateTitleHostingToolTips()
            }
            pane.faviconHostingView.isHidden = false
        }
    }

    /// Exposes this cell to UI testing as a single accessibility button.
    /// The horizontal strip otherwise has no stable query surface — the
    /// sidebar reaches its rows through an `NSOutlineView`
    /// (`setAccessibilityIdentifier("sidebarTabList")`), but the strip is a
    /// pool of plain views. This is the strip-side analog so split-view UI
    /// tests can find, count, and right-click strip tabs.
    ///
    /// `visible` is false for the collapsed non-host panes of a split (they
    /// share one merged cell with the first pane) and for the transparent
    /// drag-source stand-in, so none is mistaken for a separate tab cell.
    /// Pinned and normal cells carry distinct identifiers so tests can tell
    /// a pinned split (which lives in the pinned section) from a
    /// normal-list tab.
    func configureAccessibility(identifier: String, title: String, visible: Bool, isMergedSplit: Bool) {
        setAccessibilityElement(visible)
        guard visible else {
            setAccessibilityIdentifier(nil)
            setAccessibilityValue(nil)
            return
        }
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(title)
        // A merged split cell hosts every pane behind one cell; expose that
        // so assistive tech (and UI tests) can tell it apart from a
        // single-tab cell — a split that fails to merge renders as plain
        // cells with no such marker.
        setAccessibilityValue(isMergedSplit ? TabItemView.mergedSplitAccessibilityValue : nil)
    }

    /// Identifier stamped on every visible normal-section strip tab cell.
    static let normalAccessibilityIdentifier = "tabStripTab"
    /// Identifier stamped on every visible pinned-section strip tab cell.
    static let pinnedAccessibilityIdentifier = "tabStripPinnedTab"
    /// Accessibility value stamped on a cell that merges a split of any
    /// width. The literal predates wider splits and is the token the split
    /// UI tests match on, so it stays as is.
    static let mergedSplitAccessibilityValue = "splitPair"

    private func updateTitleHostingToolTips() {
        if showsTabPreview {
            titleHostingView.toolTip = nil
            for pane in mergedPanePool {
                pane.titleHostingView.toolTip = nil
            }
            toolTip = nil
            return
        }
        titleHostingView.toolTip = viewModel.displayTitle
        guard isMergedSplitCell else {
            toolTip = viewModel.displayTitle
            for pane in mergedPanePool {
                pane.titleHostingView.toolTip = nil
            }
            return
        }
        toolTip = nil
        for pane in mergedPanes {
            pane.titleHostingView.toolTip = pane.viewModel.displayTitle
        }
    }

    private func updatePreviewEligibility() {
        showsTabPreview = isTabPreviewEligible || isSplitTabPreviewEligible
        updateTitleHostingToolTips()
        layoutContent()
    }

    private func cancelPreviewForInteraction() {
        tabPreviewRegistration.cancelForInteraction()
        splitTabPreviewRegistration.cancelForInteraction()
    }

    // MARK: - Pane ToolTips

    /// Tags for the merged cell's per-pane tooltip rects. Installed in
    /// compact/pinned modes, where the per-pane title views that normally
    /// carry the pane tooltips are hidden.
    private(set) var paneToolTipTags: [NSView.ToolTipTag] = []

    private func removePaneToolTips() {
        for tag in paneToolTipTags { removeToolTip(tag) }
        paneToolTipTags.removeAll()
    }

    private func updatePaneToolTips(mode: LayoutMode) {
        removePaneToolTips()
        guard !showsTabPreview,
              isMergedSplitCell,
              mode != .normal else { return }
        paneToolTipTags = (0..<paneCount).map { index in
            let column = paneColumn(index)
            let rect = CGRect(x: column.minX, y: 0,
                              width: column.maxX - column.minX, height: bounds.height)
            return addToolTip(rect, owner: self, userData: nil)
        }
    }

    /// `NSViewToolTipOwner` — resolves each column of a merged compact cell
    /// to its own pane's title at hover time, so the strings stay current
    /// without re-installing the rects on every title change.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        mergedPane(at: point)?.viewModel.displayTitle ?? viewModel.displayTitle
    }

    func setDragHighlighted(_ highlighted: Bool) {
        isDragHighlighted = highlighted
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        cancelPreviewForInteraction()
        // Merged split: one TabItemView hosts every pane side-by-side
        // (`sourceTab` first, then `mergedPanes` in slot order). Route to
        // the column the click landed in, matching the left-click routing
        // in `mouseUp`.
        if isMergedSplitCell {
            let point = convert(event.locationInWindow, from: nil)
            let target = mergedPane(at: point)?.tab ?? sourceTab
            target?.close()
            return
        }
        guard !isPinned else { return }
        sourceTab?.close()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelPreviewForInteraction()
        let menu = NSMenu()
        if let tab = sourceTab,
           let state = SpaceSessionControllersManager.shared.getBrowserState(for: tab.windowId),
           TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state) {
            return menu
        }
        if let representable = sourceTab as? ContextMenuRepresentable {
            sourceTab?.contextMenuAnchorView = self
            representable.makeContextMenu(on: menu)
        }
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = hoverTrackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(newTrackingArea)
        hoverTrackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        viewModel.isPressed = false
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownLocationInWindow = nil
            selectedOnMouseDown = false
        }
        viewModel.isPressed = false
        let modifierFlags = mouseDownModifierFlags ?? event.modifierFlags
        mouseDownModifierFlags = nil

        if isDraggingInternal {
            isDraggingInternal = false
            onDragEnd?()
        } else {
            super.mouseUp(with: event)
            guard !selectedOnMouseDown else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }

            // Click check for the close buttons (host + every other pane)
            if isOnCloseButton(point) {
                return
            }

            // Click check for Mute Button (Only block if active)
            if !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(point) && isActive {
                return
            }
            // A pane's mute mirrors the same rule using that pane's active
            // state — when the pane is already focused, swallow the click so
            // the SwiftUI button just toggles mute. Otherwise let the click
            // fall through to `onPaneSelect` so tapping the glyph also
            // focuses the pane.
            if let pane = mergedPaneWithMuteButton(at: point), pane.viewModel.isActive {
                return
            }

            cancelPreviewForInteraction()

            // Merged split cells route a click in another pane's column to
            // that pane's tab so each favicon acts as its own click target.
            if let paneTab = mergedPane(at: point)?.tab, onPaneSelect != nil {
                if event.clickCount == 2, let onPaneDoubleSelect {
                    onPaneDoubleSelect(paneTab, modifierFlags)
                } else {
                    onPaneSelect?(paneTab, modifierFlags)
                }
            } else if event.clickCount == 2, let onDoubleSelect {
                onDoubleSelect(modifierFlags)
            } else {
                onSelect?(modifierFlags)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownModifierFlags = event.modifierFlags
        selectedOnMouseDown = false

        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownLocationInWindow = event.locationInWindow
        isDraggingInternal = false

        let point = convert(event.locationInWindow, from: nil)

        let isOnMute = !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(point)
        let isOnClose = isOnCloseButton(point)

        // Only block press state if on functional buttons
        let isFunctionalMute = isOnMute && isActive
        if !isFunctionalMute && !isOnClose {
            viewModel.isPressed = true
        }

        // Keep mute controls on the release path: activation can change their hit behavior.
        let isOnPaneMute = mergedPaneWithMuteButton(at: point) != nil
        guard !isOnClose, !isOnMute, !isOnPaneMute,
              event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              shouldSelectOnMouseDown?() != false else { return }
        selectedOnMouseDown = true
        cancelPreviewForInteraction()
        if let paneTab = mergedPane(at: point)?.tab, let onPaneSelect {
            onPaneSelect(paneTab, event.modifierFlags)
        } else {
            onSelect?(event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint else { return }

        // Don't drag if starting from functional functional buttons
        let isOnMute = !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(startPoint)
        let isOnClose = isOnCloseButton(startPoint)

        if (isOnMute && isActive) || isOnClose {
            return
        }

        // Activation can scroll or resize the tab. Measure physical pointer travel
        // in window coordinates so layout changes cannot start a drag.
        guard let mouseDownLocationInWindow else { return }
        let currentPoint = event.locationInWindow

        if !isDraggingInternal {
            let dx = abs(currentPoint.x - mouseDownLocationInWindow.x)
            let dy = abs(currentPoint.y - mouseDownLocationInWindow.y)
            if dx > 5 || dy > 5 {
                isDraggingInternal = true
                viewModel.isPressed = false
                cancelPreviewForInteraction()
                onDragStart?(event)
            }

        }
        if isDraggingInternal {
            onDragUpdate?(event)
        }
    }
}
