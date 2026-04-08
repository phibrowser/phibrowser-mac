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

    var onSelect: (() -> Void)?
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
    private var isPinned = false
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

    private lazy var titleHostingView: HitTransparentHostingView<AnyView> = {
        let view = HitTransparentHostingView(rootView: makeTitleRootView())
        view.layer?.backgroundColor = .clear
        return view
    }()

    // Interactive Components (Must be interactive)
    private lazy var muteButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeMuteButtonRootView())
        view.layer?.backgroundColor = .clear
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

    // MARK: - Computed Properties

    private var layoutMode: LayoutMode {
        if isPinned { return .pinned }
        if bounds.width < TabStripMetrics.Content.compactModeThreshold { return .compact }
        return .normal
    }

    private var shouldShowCloseButton: Bool {
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
        updateThemeObserver()
        wantsLayer = true
        layer?.masksToBounds = false
        backgroundLayer.sourceView = self
        layer?.insertSublayer(backgroundLayer, at: 0)

        addSubview(faviconHostingView)
        addSubview(muteButtonHostingView)
        addSubview(recordingIconHostingView)
        addSubview(titleHostingView)
        addSubview(closeButtonHostingView)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeObserver()
        faviconHostingView.rootView = makeFaviconRootView()
        titleHostingView.rootView = makeTitleRootView()
        muteButtonHostingView.rootView = makeMuteButtonRootView()
        recordingIconHostingView.rootView = makeRecordingIconRootView()
        closeButtonHostingView.rootView = makeCloseButtonRootView()
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

        switch mode {
        case .pinned, .compact:
            if showRecording {
                recordingIconHostingView.isHidden = false
                recordingIconHostingView.frame = centeredFrame(for: recordingIconSize)
                faviconHostingView.isHidden = true
                muteButtonHostingView.isHidden = true
            } else if showMute {
                muteButtonHostingView.isHidden = false
                muteButtonHostingView.frame = centeredFrame(for: muteButtonSize)
                faviconHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            } else {
                faviconHostingView.isHidden = false
                faviconHostingView.frame = centeredFrame(for: metrics.faviconSize)
                muteButtonHostingView.isHidden = true
                recordingIconHostingView.isHidden = true
            }
            return 0

        case .normal:
            faviconHostingView.isHidden = false
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
        let metrics = TabStripMetrics.Content.self
        let mode = layoutMode
        viewModel.isHorizontalCompactMode = (mode == .compact || mode == .pinned)
        
        let titleStartX = layoutFaviconAndMedia(mode: mode)

        switch mode {
        case .pinned, .compact:
            titleHostingView.isHidden = true
            closeButtonHostingView.isHidden = true
            
        case .normal:
            // 1. Close Button
            closeButtonHostingView.isHidden = !shouldShowCloseButton
            closeButtonHostingView.frame = CGRect(
                x: bounds.width - metrics.closeButtonTrailing - metrics.closeButtonSize.width,
                y: (bounds.height - metrics.closeButtonSize.height) / 2,
                width: metrics.closeButtonSize.width,
                height: metrics.closeButtonSize.height
            )
            
            // 2. Title
            titleHostingView.isHidden = false
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

    // MARK: - Appearance

    private func updateAppearance() {
        backgroundLayer.isPinned = isPinned

        switch (isActive, isHovered || isDragHighlighted) {
        case (true, _):
            backgroundLayer.tabState = .active
            layer?.zPosition = 10
        case (false, true):
            backgroundLayer.tabState = .hovered
            layer?.zPosition = 5
        case (false, false):
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
    
    private func updateThemeObserver() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
    }
    
    private func makeFaviconRootView() -> AnyView {
        AnyView(UnifiedTabFaviconView(viewModel: viewModel).phiThemeObserver(themeObserver))
    }
    
    private func makeTitleRootView() -> AnyView {
        AnyView(UnifiedTabTitleView(viewModel: viewModel).phiThemeObserver(themeObserver))
    }
    
    private func makeMuteButtonRootView() -> AnyView {
        AnyView(UnifiedTabMuteButton(viewModel: viewModel).phiThemeObserver(themeObserver))
    }
    
    private func makeRecordingIconRootView() -> AnyView {
        AnyView(UnifiedTabRecordingIcon().phiThemeObserver(themeObserver))
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
        isPinned = data.isPinned

        updateAppearance()
        
        if let tab = data.sourceTab {
            sourceTab = tab
            viewModel.configure(with: tab)
            viewModel.onToggleMute = { [weak tab] in
                guard let tab else { return }
                tab.setAudioMuted(!tab.isAudioMuted)
            }
            
            viewModel.onToolTipUpdated = { [weak self] in
                self?.toolTip = self?.viewModel.displayTitle
            }
            
            self.toolTip = viewModel.displayTitle

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
        
        layoutContent()
    }

    func setDragHighlighted(_ highlighted: Bool) {
        isDragHighlighted = highlighted
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        guard !isPinned else { return }
        sourceTab?.close()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
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

            // Click check for Close Button
            if !closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(point) {
                return
            }
            
            // Click check for Mute Button (Only block if active)
            if !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(point) && isActive {
                return
            }
            
            onSelect?()
        }
        mouseDownPoint = nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDraggingInternal = false
        
        let point = convert(event.locationInWindow, from: nil)
        
        let isOnMute = !muteButtonHostingView.isHidden && muteButtonHostingView.frame.contains(point)
        let isOnClose = !closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(point)
        
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
        let isOnClose = !closeButtonHostingView.isHidden && closeButtonHostingView.frame.contains(startPoint)

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
