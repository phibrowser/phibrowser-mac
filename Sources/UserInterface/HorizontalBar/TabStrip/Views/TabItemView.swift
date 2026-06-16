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

final class TabItemView: NSView {
    // MARK: - Types

    private enum LayoutMode {
        case pinned
        case compact
        case normal
    }

    func resetHoverState() {
        if isHovered {
            isHovered = false
        }
        viewModel.isPressed = false
    }

    // MARK: - Public Properties

    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    /// Fires for split-merged cells when the click falls on the right half
    /// (the partner pane's favicon). Standalone tabs leave this nil and
    /// every click routes through `onSelect`.
    var onSecondarySelect: (() -> Void)?
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
    private var cancellables = Set<AnyCancellable>()
    private var themeObservation: AnyObject?
    private var themeObserver = ThemeObserver.shared

    private let backgroundLayer = TabBackgroundLayer()
    
    // Unified Data Layer
    private let viewModel = TabViewModel()

    // MARK: - Drag Gesture State
    private var isDraggingInternal = false
    private var mouseDownPoint: CGPoint?

    // MARK: - Tracking Area
    private var hoverTrackingArea: NSTrackingArea?

    // MARK: - State

    private var isActive = false
    private var isMultiSelected = false
    private var isPinned = false
    /// Backing for the second pane of a pinned split. When non-nil this cell
    /// renders two favicons side-by-side; the secondary view model carries
    /// the partner's bindings so favicon updates flow independently.
    private weak var pinnedSplitPartner: Tab?
    private var isDragHighlighted = false {
        didSet {
            guard oldValue != isDragHighlighted else { return }
            updateAppearance()
        }
    }
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
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

    /// Secondary favicon used only for the `.first` pane of a pinned split,
    /// where the cell needs to show both panes' favicons side-by-side.
    /// Hidden when `pinnedSplitPartner` is nil. Driven by its own view model
    /// so its Combine subscriptions don't trample the primary tab's bindings.
    private let secondaryFaviconViewModel = TabViewModel()
    private lazy var secondaryFaviconHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(rootView: makeSecondaryFaviconRootView())
        view.layer?.backgroundColor = .clear
        view.isHidden = true
        return view
    }()

    private lazy var titleHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(rootView: makeTitleRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    /// Right-pane title shown only when this cell renders a split-merged
    /// pair in the normal-zone strip. Bound to `secondaryFaviconViewModel`
    /// so its text follows the partner pane's `Tab.title` independently.
    private lazy var secondaryTitleHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(rootView: makeSecondaryTitleRootView())
        view.layer?.backgroundColor = .clear
        view.isHidden = true
        return view
    }()

    /// Thin vertical line between the two halves of a split-merged cell.
    /// Hidden when `pinnedSplitPartner` is nil.
    ///
    /// Sizing + color mirror the tab↔tab separator (`TabStripMetrics.Content.separator*`)
    /// so the divider inside a merged cell reads as the same affordance as
    /// the divider between any two normal tabs.
    private lazy var splitDividerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(TabStripMetrics.Content.separatorColor)
        view.isHidden = true
        return view
    }()

    // Interactive Components (Must be interactive)
    private lazy var muteButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeMuteButtonRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    /// Right-pane mute toggle for a split-merged cell. Bound to
    /// `secondaryFaviconViewModel` so its icon and tap target track the
    /// partner pane's audio state independently of the left pane's.
    private lazy var secondaryMuteButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeSecondaryMuteButtonRootView())
        view.layer?.backgroundColor = .clear
        view.isHidden = true
        return view
    }()

    private lazy var recordingIconHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeRecordingIconRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    private lazy var closeButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeCloseButtonRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    /// Per-pane close button for the right half of a split-merged cell.
    /// Calls `pinnedSplitPartner.close()` instead of `sourceTab.close()`
    /// so each side acts on its own pane.
    private lazy var secondaryCloseButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeSecondaryCloseButtonRootView())
        view.layer?.backgroundColor = .clear
        view.isHidden = true
        return view
    }()

    // MARK: - Computed Properties

    private var layoutMode: LayoutMode {
        if isPinned { return .pinned }
        let compactThreshold = pinnedSplitPartner == nil
            ? TabStripMetrics.Content.compactModeThreshold
            : TabStripMetrics.Content.splitCompactModeThreshold
        if bounds.width < compactThreshold { return .compact }
        return .normal
    }

    private var shouldShowCloseButton: Bool {
        // Split-merged cells expose one close button per pane; both fade
        // in on hover. See the dedicated `secondaryCloseButtonHostingView`
        // for the right-pane close routed to `pinnedSplitPartner.close()`.
        layoutMode == .normal && isHovered
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

        addSubview(faviconHostingView)
        addSubview(secondaryFaviconHostingView)
        addSubview(muteButtonHostingView)
        addSubview(secondaryMuteButtonHostingView)
        addSubview(recordingIconHostingView)
        addSubview(titleHostingView)
        addSubview(secondaryTitleHostingView)
        addSubview(splitDividerView)
        addSubview(closeButtonHostingView)
        addSubview(secondaryCloseButtonHostingView)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        themeObserver.rebind(to: themeStateProvider)
    }

    // MARK: - Constants

    private let muteButtonSize = CGSize(width: 16, height: 16)
    private let recordingIconSize = CGSize(width: 14, height: 14)

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
        let showMute = viewModel.isCurrentlyAudible || viewModel.isAudioMuted
        let centerY = bounds.height / 2

        // Right-pane mute only renders inside split-merged cells; reset to
        // hidden up front so recycled cells transitioning into non-split
        // modes never leak the partner's mute icon.
        secondaryMuteButtonHostingView.isHidden = true

        switch mode {
        case .pinned, .compact:
            // Pinned/compact cells never carry the divider; reset so a
            // recycled view that previously rendered a normal-mode split
            // doesn't leak its center decoration.
            splitDividerView.isHidden = true
            // Merged cells surface EITHER pane's audio state as ONE centered
            // glyph for the whole cell. Per-pane glyphs were tried and read
            // wrong: [favicon][speaker] mimics a normal tab's "favicon + its
            // indicator" row, misattributing the partner's sound to the left
            // pane. The glyph and its mute toggle bind to whichever pane
            // carries the state, primary first when both do. Primary
            // recording still outranks audio (single-tab precedence). While
            // a centered glyph is up, the favicons — and the per-pane
            // recording corner badges they carry — are hidden, so a narrow
            // cell shows at most one state at a time by design.
            let showSecondaryMute = pinnedSplitPartner != nil
                && (secondaryFaviconViewModel.isCurrentlyAudible
                    || secondaryFaviconViewModel.isAudioMuted)
            if showRecording {
                recordingIconHostingView.isHidden = false
                recordingIconHostingView.frame = centeredFrame(for: recordingIconSize)
                faviconHostingView.isHidden = true
                secondaryFaviconHostingView.isHidden = true
                muteButtonHostingView.isHidden = true
            } else if showMute {
                muteButtonHostingView.isHidden = false
                muteButtonHostingView.frame = centeredFrame(for: muteButtonSize)
                faviconHostingView.isHidden = true
                secondaryFaviconHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            } else if showSecondaryMute {
                secondaryMuteButtonHostingView.isHidden = false
                secondaryMuteButtonHostingView.frame = centeredFrame(for: muteButtonSize)
                faviconHostingView.isHidden = true
                secondaryFaviconHostingView.isHidden = true
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            } else if pinnedSplitPartner != nil {
                // Two favicons inside one pinned/compact cell. Stack them
                // horizontally around the cell's center so the cell still
                // occupies a single slot in the strip's layout.
                let centerY = bounds.height / 2
                let iconSize = metrics.faviconSize
                let gap: CGFloat = 2
                let pairWidth = iconSize.width * 2 + gap
                let leftX = (bounds.width - pairWidth) / 2
                faviconHostingView.isHidden = false
                faviconHostingView.frame = CGRect(
                    x: leftX,
                    y: centerY - iconSize.height / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
                secondaryFaviconHostingView.isHidden = false
                secondaryFaviconHostingView.frame = CGRect(
                    x: leftX + iconSize.width + gap,
                    y: centerY - iconSize.height / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            } else {
                faviconHostingView.isHidden = false
                faviconHostingView.frame = centeredFrame(for: metrics.faviconSize)
                secondaryFaviconHostingView.isHidden = true
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            }
            return 0

        case .normal:
            // Split-merged cell: render two halves (favicon + title each)
            // separated by a vertical divider. Each pane carries its own mute
            // toggle so audible state stays addressable per-pane; recording
            // also shows per-pane, as the corner badge UnifiedTabFaviconView
            // overlays on each favicon — only the dedicated centered
            // recording icon is dropped here.
            if let _ = pinnedSplitPartner {
                let half = bounds.width / 2
                faviconHostingView.isHidden = false
                faviconHostingView.frame = CGRect(
                    x: metrics.faviconLeading,
                    y: centerY - metrics.faviconSize.height / 2,
                    width: metrics.faviconSize.width,
                    height: metrics.faviconSize.height
                )
                secondaryFaviconHostingView.isHidden = false
                secondaryFaviconHostingView.frame = CGRect(
                    x: half + metrics.faviconLeading,
                    y: centerY - metrics.faviconSize.height / 2,
                    width: metrics.faviconSize.width,
                    height: metrics.faviconSize.height
                )
                splitDividerView.isHidden = false
                let sepSize = TabStripMetrics.Content.separatorSize
                splitDividerView.frame = CGRect(
                    x: half - sepSize.width / 2,
                    y: (bounds.height - sepSize.height) / 2,
                    width: sepSize.width,
                    height: sepSize.height
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
                let showSecondaryMute = secondaryFaviconViewModel.isCurrentlyAudible
                    || secondaryFaviconViewModel.isAudioMuted
                secondaryMuteButtonHostingView.isHidden = !showSecondaryMute
                if showSecondaryMute {
                    secondaryMuteButtonHostingView.frame = CGRect(
                        x: secondaryFaviconHostingView.frame.maxX + metrics.titleToFavicon,
                        y: centerY - muteButtonSize.height / 2,
                        width: muteButtonSize.width,
                        height: muteButtonSize.height
                    )
                }
                recordingIconHostingView.isHidden = true
                return faviconHostingView.frame.maxX + metrics.titleToFavicon
            }

            faviconHostingView.isHidden = false
            secondaryFaviconHostingView.isHidden = true
            secondaryTitleHostingView.isHidden = true
            splitDividerView.isHidden = true
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
        // Mirror onto the partner pane's view model: its mute button shares
        // the same "non-interactive in compact unless focused" gate, and it
        // can render centered in a compact merged cell.
        secondaryFaviconViewModel.isHorizontalCompactMode = viewModel.isHorizontalCompactMode
        
        let titleStartX = layoutFaviconAndMedia(mode: mode)

        switch mode {
        case .pinned, .compact:
            // Reset the right-pane title/close as well: a split-merged cell
            // shrinking out of normal mode would otherwise keep their stale
            // frames and paint the partner's title over neighboring tabs.
            titleHostingView.isHidden = true
            secondaryTitleHostingView.isHidden = true
            closeButtonHostingView.isHidden = true
            secondaryCloseButtonHostingView.isHidden = true

        case .normal:
            // Close buttons: one per pane for a split-merged cell (both
            // visible on hover), single button for a regular tab.
            if pinnedSplitPartner != nil {
                let half = bounds.width / 2
                let closeY = (bounds.height - metrics.closeButtonSize.height) / 2
                let leftCloseFrame = CGRect(
                    x: half - metrics.closeButtonTrailing - metrics.closeButtonSize.width,
                    y: closeY,
                    width: metrics.closeButtonSize.width,
                    height: metrics.closeButtonSize.height
                )
                let rightCloseFrame = CGRect(
                    x: bounds.width - metrics.closeButtonTrailing - metrics.closeButtonSize.width,
                    y: closeY,
                    width: metrics.closeButtonSize.width,
                    height: metrics.closeButtonSize.height
                )
                // A pane too narrow for both controls drops its close
                // button in favor of the mute toggle — stacked on top of
                // the speaker glyph, a "mute" click would close the pane.
                let showLeftClose = shouldShowCloseButton
                    && (muteButtonHostingView.isHidden
                        || leftCloseFrame.minX >= muteButtonHostingView.frame.maxX)
                let showRightClose = shouldShowCloseButton
                    && (secondaryMuteButtonHostingView.isHidden
                        || rightCloseFrame.minX >= secondaryMuteButtonHostingView.frame.maxX)
                closeButtonHostingView.isHidden = !showLeftClose
                closeButtonHostingView.frame = leftCloseFrame
                secondaryCloseButtonHostingView.isHidden = !showRightClose
                secondaryCloseButtonHostingView.frame = rightCloseFrame

                // Titles: each pane's title is clipped against its own
                // close button when hovered. When a pane carries a mute
                // icon, the title shifts right past it so the speaker
                // glyph and the page name don't overlap.
                let leftTitleStart: CGFloat = muteButtonHostingView.isHidden
                    ? faviconHostingView.frame.maxX + metrics.titleToFavicon
                    : muteButtonHostingView.frame.maxX + metrics.titleToFavicon
                let leftTitleMax: CGFloat = showLeftClose
                    ? leftCloseFrame.minX - metrics.titleToCloseButton
                    : half - metrics.titleTrailing
                titleHostingView.isHidden = false
                titleHostingView.frame = CGRect(
                    x: leftTitleStart,
                    y: (bounds.height - metrics.titleHeight) / 2,
                    width: max(0, leftTitleMax - leftTitleStart),
                    height: metrics.titleHeight
                )
                let rightTitleStart: CGFloat = secondaryMuteButtonHostingView.isHidden
                    ? secondaryFaviconHostingView.frame.maxX + metrics.titleToFavicon
                    : secondaryMuteButtonHostingView.frame.maxX + metrics.titleToFavicon
                let rightTitleMax: CGFloat = showRightClose
                    ? rightCloseFrame.minX - metrics.titleToCloseButton
                    : bounds.width - metrics.titleTrailing
                secondaryTitleHostingView.isHidden = false
                secondaryTitleHostingView.frame = CGRect(
                    x: rightTitleStart,
                    y: (bounds.height - metrics.titleHeight) / 2,
                    width: max(0, rightTitleMax - rightTitleStart),
                    height: metrics.titleHeight
                )
            } else {
                closeButtonHostingView.isHidden = !shouldShowCloseButton
                closeButtonHostingView.frame = CGRect(
                    x: bounds.width - metrics.closeButtonTrailing - metrics.closeButtonSize.width,
                    y: (bounds.height - metrics.closeButtonSize.height) / 2,
                    width: metrics.closeButtonSize.width,
                    height: metrics.closeButtonSize.height
                )
                secondaryCloseButtonHostingView.isHidden = true
                titleHostingView.isHidden = false
                secondaryTitleHostingView.isHidden = true
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

        updatePaneToolTips(mode: mode)
    }

    private func hideContentForEmptyBounds() {
        for view in [
            faviconHostingView,
            secondaryFaviconHostingView,
            muteButtonHostingView,
            secondaryMuteButtonHostingView,
            recordingIconHostingView,
            titleHostingView,
            secondaryTitleHostingView,
            splitDividerView,
            closeButtonHostingView,
            secondaryCloseButtonHostingView,
        ] {
            view.isHidden = true
            view.frame = .zero
        }
        removePaneToolTips()
    }

    // MARK: - Appearance

    private func updateAppearance() {
        backgroundLayer.isPinned = isPinned

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
    
    private func bindTheme() {
        themeObservation = subscribe { [weak self] _, _ in
            self?.backgroundLayer.refreshAppearance()
        }
    }
    
    private func makeFaviconRootView() -> AnyView {
        AnyView(UnifiedTabFaviconView(viewModel: viewModel).phiThemeObserver(themeObserver))
    }

    private func makeSecondaryFaviconRootView() -> AnyView {
        AnyView(UnifiedTabFaviconView(viewModel: secondaryFaviconViewModel).phiThemeObserver(themeObserver))
    }
    
    private func makeTitleRootView() -> AnyView {
        AnyView(UnifiedTabTitleView(viewModel: viewModel).phiThemeObserver(themeObserver))
    }

    private func makeSecondaryTitleRootView() -> AnyView {
        AnyView(UnifiedTabTitleView(viewModel: secondaryFaviconViewModel).phiThemeObserver(themeObserver))
    }
    
    private func makeMuteButtonRootView() -> AnyView {
        AnyView(UnifiedTabMuteButton(viewModel: viewModel).phiThemeObserver(themeObserver))
    }

    private func makeSecondaryMuteButtonRootView() -> AnyView {
        AnyView(UnifiedTabMuteButton(viewModel: secondaryFaviconViewModel).phiThemeObserver(themeObserver))
    }
    
    private func makeRecordingIconRootView() -> AnyView {
        AnyView(UnifiedTabRecordingIcon().phiThemeObserver(themeObserver))
    }
    
    private func makeSecondaryCloseButtonRootView() -> AnyView {
        AnyView(
            UnifiedTabCloseButton { [weak self] in
                self?.pinnedSplitPartner?.close()
            }
            .phiThemeObserver(themeObserver)
        )
    }

    private func makeCloseButtonRootView() -> AnyView {
        AnyView(
            UnifiedTabCloseButton { [weak self] in
                self?.sourceTab?.close()
            }
            .phiThemeObserver(themeObserver)
        )
    }

    // MARK: - Configuration

    func configure(with data: TabRenderData) {
        currentTabId = data.id
        isActive = data.isActive
        isMultiSelected = data.isMultiSelected
        isPinned = data.isPinned
        backgroundLayer.splitPairPosition = data.splitPairPosition
        backgroundLayer.isSplitGroupActive = data.isSplitGroupActive

        // Pinned-split first pane: bind the secondary view model so the right
        // favicon renders the partner. The configure() call subscribes to the
        // partner tab's Combine publishers; clearing back to nil drops them.
        pinnedSplitPartner = data.pinnedSplitPartner
        if let partner = data.pinnedSplitPartner {
            secondaryFaviconViewModel.configure(with: partner)
            secondaryFaviconViewModel.onToggleMute = { [weak partner] in
                guard let partner else { return }
                partner.setAudioMuted(!partner.isAudioMuted)
            }
            secondaryFaviconViewModel.onToolTipUpdated = { [weak self] in
                self?.updateTitleHostingToolTips()
            }
            secondaryFaviconHostingView.isHidden = false
        } else {
            secondaryFaviconViewModel.cancelSubscriptions()
            secondaryFaviconViewModel.onToggleMute = nil
            secondaryFaviconViewModel.onToolTipUpdated = nil
            secondaryFaviconHostingView.isHidden = true
            secondaryMuteButtonHostingView.isHidden = true
        }

        updateAppearance()
        
        if let tab = data.sourceTab {
            sourceTab = tab
            viewModel.configure(with: tab)
            viewModel.onToggleMute = { [weak tab] in
                guard let tab else { return }
                tab.setAudioMuted(!tab.isAudioMuted)
            }
            
            viewModel.onToolTipUpdated = { [weak self] in
                self?.updateTitleHostingToolTips()
            }
            
            updateTitleHostingToolTips()

            // Listen for state changes to trigger re-layout
            cancellables.removeAll()
            Publishers.CombineLatest3(tab.$isCapturingAudio, tab.$isCapturingVideo, tab.$isSharingScreen)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)
            
            tab.$isCurrentlyAudible
                .combineLatest(tab.$isAudioMuted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)
        }

        // Same re-layout trigger for the partner pane so the right-side
        // mute icon appears / disappears in sync with the partner tab's
        // audio state, matching the left pane's behavior above.
        if let partner = data.pinnedSplitPartner {
            partner.$isCurrentlyAudible
                .combineLatest(partner.$isAudioMuted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.layoutContent()
                }
                .store(in: &cancellables)
        }

        layoutContent()
    }

    /// Exposes this cell to UI testing as a single accessibility button.
    /// The horizontal strip otherwise has no stable query surface — the
    /// sidebar reaches its rows through an `NSOutlineView`
    /// (`setAccessibilityIdentifier("sidebarTabList")`), but the strip is a
    /// pool of plain views. This is the strip-side analog so split-view UI
    /// tests can find, count, and right-click strip tabs.
    ///
    /// `visible` is false for the collapsed second pane of a split (it shares
    /// one merged cell with its partner) and for the transparent drag-source
    /// stand-in, so neither is mistaken for a separate tab cell. Pinned and
    /// normal cells carry distinct identifiers so tests can tell a pinned
    /// split (which lives in the pinned section) from a normal-list tab.
    func configureAccessibility(identifier: String, title: String, visible: Bool, isSplitPair: Bool) {
        setAccessibilityElement(visible)
        guard visible else {
            setAccessibilityIdentifier(nil)
            setAccessibilityValue(nil)
            return
        }
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(title)
        // A merged split-pair cell hosts two panes behind one cell; expose
        // that so assistive tech (and UI tests) can tell it apart from a
        // single-tab cell — a split that fails to merge renders as two plain
        // cells with no such marker.
        setAccessibilityValue(isSplitPair ? TabItemView.splitPairAccessibilityValue : nil)
    }

    /// Identifier stamped on every visible normal-section strip tab cell.
    static let normalAccessibilityIdentifier = "tabStripTab"
    /// Identifier stamped on every visible pinned-section strip tab cell.
    static let pinnedAccessibilityIdentifier = "tabStripPinnedTab"
    /// Accessibility value stamped on a cell that merges a split pair.
    static let splitPairAccessibilityValue = "splitPair"

    private func updateTitleHostingToolTips() {
        titleHostingView.toolTip = viewModel.displayTitle
        guard pinnedSplitPartner != nil else {
            toolTip = viewModel.displayTitle
            secondaryTitleHostingView.toolTip = nil
            return
        }
        toolTip = nil
        secondaryTitleHostingView.toolTip = secondaryFaviconViewModel.displayTitle
    }

    // MARK: - Pane ToolTips

    /// Tags for the merged cell's per-half tooltip rects. Installed in
    /// compact/pinned modes, where the per-pane title views that normally
    /// carry the pane tooltips are hidden.
    private(set) var paneToolTipTags: [NSView.ToolTipTag] = []

    private func removePaneToolTips() {
        for tag in paneToolTipTags { removeToolTip(tag) }
        paneToolTipTags.removeAll()
    }

    private func updatePaneToolTips(mode: LayoutMode) {
        removePaneToolTips()
        guard pinnedSplitPartner != nil, mode != .normal else { return }
        let leftHalf = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        let rightHalf = CGRect(x: leftHalf.maxX, y: 0,
                               width: bounds.width - leftHalf.width, height: bounds.height)
        paneToolTipTags = [
            addToolTip(leftHalf, owner: self, userData: nil),
            addToolTip(rightHalf, owner: self, userData: nil),
        ]
    }

    /// `NSViewToolTipOwner` — resolves each half of a merged compact cell
    /// to its own pane's title at hover time, so the strings stay current
    /// without re-installing the rects on every title change.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        point.x > bounds.midX
            ? secondaryFaviconViewModel.displayTitle
            : viewModel.displayTitle
    }

    func setDragHighlighted(_ highlighted: Bool) {
        isDragHighlighted = highlighted
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        // Pinned-merged split: one TabItemView hosts two panes side-by-side
        // (`sourceTab` left, `pinnedSplitPartner` right). Route to the half
        // the click landed in, matching the left-click split in `mouseUp`.
        if let partner = pinnedSplitPartner {
            let point = convert(event.locationInWindow, from: nil)
            let target = point.x > bounds.midX ? partner : sourceTab
            target?.close()
            return
        }
        guard !isPinned else { return }
        sourceTab?.close()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let tab = sourceTab,
           let state = MainBrowserWindowControllersManager.shared.getBrowserState(for: tab.windowId),
           TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state) {
            return menu
        }
        if let representable = sourceTab as? ContextMenuRepresentable {
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
        viewModel.isPressed = false
        
        if isDraggingInternal {
            isDraggingInternal = false
            onDragEnd?()
        } else {
            super.mouseUp(with: event)
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }

            // Click check for Close Button (primary + secondary)
            if !closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(point) {
                return
            }
            if !secondaryCloseButtonHostingView.isHidden && secondaryCloseButtonHostingView.frame.contains(point) {
                return
            }

            // Click check for Mute Button (Only block if active)
            if !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(point) && isActive {
                return
            }
            // Right-pane mute mirrors the same rule using the partner pane's
            // active state — when the partner is already focused, swallow the
            // click so the SwiftUI button just toggles mute. Otherwise let
            // the click fall through to `onSecondarySelect` so tapping the
            // glyph also focuses the right pane.
            if !secondaryMuteButtonHostingView.isHidden
                && secondaryMuteButtonHostingView.frame.contains(point)
                && secondaryFaviconViewModel.isActive {
                return
            }

            // Split-merged cells route the right-half click to the partner
            // pane's tab so each favicon acts as its own click target.
            if pinnedSplitPartner != nil, point.x > bounds.midX, onSecondarySelect != nil {
                onSecondarySelect?()
            } else {
                onSelect?(event.modifierFlags)
            }
        }
        mouseDownPoint = nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDraggingInternal = false

        let point = convert(event.locationInWindow, from: nil)

        let isOnMute = !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(point)
        let isOnClose = (!closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(point))
            || (!secondaryCloseButtonHostingView.isHidden && secondaryCloseButtonHostingView.frame.contains(point))

        // Only block press state if on functional buttons
        let isFunctionalMute = isOnMute && isActive
        if !isFunctionalMute && !isOnClose {
            viewModel.isPressed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint else { return }

        // Don't drag if starting from functional functional buttons
        let isOnMute = !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(startPoint)
        let isOnClose = (!closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(startPoint))
            || (!secondaryCloseButtonHostingView.isHidden && secondaryCloseButtonHostingView.frame.contains(startPoint))

        if (isOnMute && isActive) || isOnClose {
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)

        if !isDraggingInternal {
            let dx = abs(currentPoint.x - startPoint.x)
            let dy = abs(currentPoint.y - startPoint.y)
            if dx > 5 || dy > 5 {
                isDraggingInternal = true
                viewModel.isPressed = false
                onDragStart?(event)
            }

        }
        if isDraggingInternal {
            onDragUpdate?(event)
        }
    }
}
