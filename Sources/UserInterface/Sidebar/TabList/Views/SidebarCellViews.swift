// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI

// MARK: - Base Cell View
class SidebarCellView: NSTableCellView {
    var cancellables = Set<AnyCancellable>()
    weak var item: SidebarItem?
    
    lazy var backgoundView: HoverableView = {
        let view = HoverableView()
        view.enableClickAnimation = false
        view.responseToClickAction = true
        view.shadow = selectedShadow
        return view
    }()
    
    lazy var selectedShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = CGSizeMake(0, -1)
        return shadow
    }()
    
    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        item = nil
    }
    
    func configure(with item: SidebarItem) {
        self.item = item
        configureAppearance()
    }
    
    func configureAppearance() {
        // Override in subclasses
    }
    
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let targetView = backgoundView.superview != nil ? backgoundView : self
        
        guard let snapshot = targetView.createDraggingSnapshot() else {
            return super.draggingImageComponents
        }
        
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = snapshot
        // Use the subview's actual frame in the cell's coordinate space so the snap-back
        // animation targets the correct position. When targetView is self, origin is (0,0).
        let componentOrigin = targetView === self ? CGPoint.zero : targetView.frame.origin
        component.frame = CGRect(origin: componentOrigin, size: snapshot.size)
        
        return [component]
    }
    
    func createDraggingImage() -> NSImage? {
        let targetView = backgoundView.superview != nil ? backgoundView : self
        return targetView.createDraggingSnapshot()
    }
}

// MARK: - NSView Dragging Snapshot Extension
extension NSView {
    /// Creates a rounded snapshot of the view for dragging.
    /// - Parameter cornerRadius: Corner radius applied to the snapshot.
    /// - Returns: Snapshot image with rounded corners.
    func createDraggingSnapshot(cornerRadius: CGFloat = 8) -> NSImage? {
        let targetBounds = self.bounds
        
        guard targetBounds.width > 0 && targetBounds.height > 0 else {
            return nil
        }
        
        // Rasterize the current view into a bitmap first.
        guard let bitmapRep = self.bitmapImageRepForCachingDisplay(in: targetBounds) else {
            return nil
        }
        
        self.cacheDisplay(in: targetBounds, to: bitmapRep)
        
        // Draw into a rounded image canvas.
        let image = NSImage(size: targetBounds.size)
        image.addRepresentation(bitmapRep)
        
        // Clip to the rounded path before drawing the cached bitmap.
        let roundedImage = NSImage(size: targetBounds.size)
        roundedImage.lockFocus()
        
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: targetBounds.size),
                                 xRadius: cornerRadius,
                                 yRadius: cornerRadius)
        path.addClip()
        image.draw(in: NSRect(origin: .zero, size: targetBounds.size))
        
        roundedImage.unlockFocus()
         
        return roundedImage
    }
}

// MARK: - Tab Hover Region

/// Transparent overlay that owns hover tracking for sidebar tabs.
/// NSHostingView sits underneath and does not reliably deliver parent tracking-area events,
/// so this view drives hover via its own tracking area while staying transparent to hit-testing
/// — clicks fall through to the SwiftUI buttons (close / mute) inside the hosting view.
/// Shared by ungrouped `SidebarTabCellView` and `TabGroupCellView` container hover.
final class SidebarTabHoverRegionView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        syncHoverStateForCurrentMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    private func syncHoverStateForCurrentMouseLocation() {
        guard let window else {
            onHoverChanged?(false)
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let screenRect = CGRect(x: screenPoint.x, y: screenPoint.y, width: 1, height: 1)
        let windowPoint = window.convertFromScreen(screenRect).origin
        let point = convert(windowPoint, from: nil)
        onHoverChanged?(bounds.contains(point))
    }
}

/// Clears tab hover when the cursor is in the trailing strip beside the split divider.
/// Transparent to hit-testing for the same reason as the hover region above.
private final class SidebarTabHoverDeadZoneView: NSView {
    var onEntered: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onEntered?()
    }
}

// MARK: - Tab Cell View (reused from existing)
class SidebarTabCellView: SidebarCellView {
    private var hostingView: ThemedHostingView!
    private let hoverRegionView = SidebarTabHoverRegionView()
    private let hoverDeadZoneView = SidebarTabHoverDeadZoneView()
    private let viewModel = TabViewModel()
    private weak var configuredTab: Tab?
    private var activeSuppressed = false
    weak var delegate: TabCellDelegate?


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        // Only cancel subscriptions and reset interaction state.
        // Visual state (title, favicon, etc.) is preserved until configure()
        // overwrites it, avoiding a blank-frame flicker between prepareForReuse
        // and the next SwiftUI render cycle.
        viewModel.cancelSubscriptions()
        viewModel.setHoverSuppressed(false)
        viewModel.setActiveSuppressed(false, activeValue: false)
        viewModel.setHovered(false)
        viewModel.isPressed = false
        configuredTab = nil
        activeSuppressed = false
    }

    /// Cancel Combine subscriptions without resetting visual state.
    /// Used before reloadData to prevent orphan events while keeping
    /// the current frame on screen (avoids blank-frame flicker).
    func invalidateSubscriptions() {
        viewModel.cancelSubscriptions()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        viewModel.setHoverSuppressed(suppressed)
    }

    func setHovered(_ hovered: Bool) {
        viewModel.setHovered(hovered)
    }

    func setActiveSuppressed(_ suppressed: Bool) {
        activeSuppressed = suppressed
        viewModel.setActiveSuppressed(suppressed, activeValue: configuredTab?.isActive ?? false)
    }
    
    private func setupViews() {
        hostingView = ThemedHostingView(rootView: SideTabView(model: viewModel) { [weak self] in
            self?.closeButtonTapped()
        })
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.viewModel.isHovered = isHovered
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalToSuperview().inset(SideTabView.trailingHoverDeadZoneWidth)
        }

        hoverDeadZoneView.onEntered = { [weak self] in
            self?.viewModel.isHovered = false
        }
        addSubview(hoverDeadZoneView)
        hoverDeadZoneView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.width.equalTo(SideTabView.trailingHoverDeadZoneWidth)
        }

        setupPressAnimation()
    }
    
    // MARK: - Press Animation
    
    private func setupPressAnimation() {
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 5
        // Don't delay events — let them reach NSHostingView's SwiftUI Button simultaneously
        press.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(press)
    }
    
    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            viewModel.isPressed = true
        case .ended, .cancelled, .failed:
            viewModel.isPressed = false
        default:
            break
        }
    }

    private func closeButtonTapped() {
        guard let tab = item as? Tab else { return }
        delegate?.tabCellDidRequestClose(tab)
    }

    override func configureAppearance() {
        guard let tab = item as? Tab else { return }
        configuredTab = tab
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        let state = MainBrowserWindowControllersManager.shared
            .controller(for: tab.windowId)?.browserState
        viewModel.configure(with: tab, in: state)
        viewModel.setActiveSuppressed(activeSuppressed, activeValue: tab.isActive)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
    }
}

// MARK: - Split Pair Cell View
/// Sidebar row representing a non-pinned split as a single merged cell.
/// Two halves stand side-by-side inside one rounded background; each
/// half shows its favicon, title, and an x close button that appears on
/// cell hover. The pane whose tab is focused gets a solid white pill,
/// the other half stays at the cell-level hover tint.
class SidebarSplitPairCellView: SidebarCellView {
    private let outerBackground = HoverableView()
    private let leftPane = HoverableView()
    private let rightPane = HoverableView()
    private let leftIconView = NSImageView()
    private let rightIconView = NSImageView()
    private let leftTitleLabel = NSTextField(labelWithString: "")
    private let rightTitleLabel = NSTextField(labelWithString: "")
    private var leftCloseHost: ZeroSafeAreaHostingView<AnyView>!
    private var rightCloseHost: ZeroSafeAreaHostingView<AnyView>!
    private var leftMuteHost: ZeroSafeAreaHostingView<AnyView>!
    private var rightMuteHost: ZeroSafeAreaHostingView<AnyView>!
    private var leftMuteWidth: Constraint?
    private var rightMuteWidth: Constraint?
    private let dividerView = NSView()
    private var leftFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var rightFaviconHandle: ProfileScopedFaviconLoadHandle?
    private weak var configuredLeftTab: Tab?
    private weak var configuredRightTab: Tab?
    private var configuredSplitId: String?
    /// Owning window's BrowserState. Lets the cell re-resolve which pane
    /// is "left" after Chromium reorders the strip (e.g. via the
    /// "Reverse Panes" context-menu action or a drag) — the
    /// `SplitPairSidebarItem.id` is keyed on the SplitGroup alone so the
    /// diff path treats a strip swap as a no-op, but the underlying
    /// `normalTabs` adjacency tells us which guid is now first.
    weak var browserState: BrowserState?
    private var hoverTrackingArea: NSTrackingArea?
    private var isCellHovered = false {
        didSet {
            guard oldValue != isCellHovered else { return }
            updateHoverChrome()
        }
    }
    /// Controller that owns the outline view. Routed through so a click
    /// on either half triggers the same selection flow as a normal tab
    /// click (clears group overview, updates lastSelectedItem, etc.).
    weak var owner: SidebarTabListItemOwner?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        leftFaviconHandle?.cancel()
        leftFaviconHandle = nil
        rightFaviconHandle?.cancel()
        rightFaviconHandle = nil
        leftIconView.image = nil
        rightIconView.image = nil
        leftTitleLabel.stringValue = ""
        rightTitleLabel.stringValue = ""
        configuredLeftTab = nil
        configuredRightTab = nil
        configuredSplitId = nil
        outerBackground.isSelected = false
        isCellHovered = false
        leftMuteHost.isHidden = true
        rightMuteHost.isHidden = true
        leftMuteWidth?.update(offset: 0)
        rightMuteWidth?.update(offset: 0)
    }

    private func setupViews() {
        outerBackground.backgroundColor = .clear
        outerBackground.hoveredColor = NSColor(resource: .sidebarTabHovered)
        outerBackground.selectedColor = NSColor(resource: .sidebarTabSelected)
        outerBackground.enableClickAnimation = false
        outerBackground.responseToClickAction = false
        outerBackground.layer?.cornerRadius = 8
        outerBackground.layer?.cornerCurve = .continuous
        addSubview(outerBackground)
        outerBackground.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(
                top: 2, left: WebContentConstant.edgesSpacing, bottom: 2, right: WebContentConstant.edgesSpacing))
        }

        // Match normal-tab close buttons (24x24 with rounded hover fill) by
        // reusing `UnifiedTabCloseButton`. Hosted inside each pane so the
        // SwiftUI button receives its own hover events independently.
        leftCloseHost = ZeroSafeAreaHostingView(rootView: AnyView(
            UnifiedTabCloseButton { [weak self] in self?.leftCloseTapped() }
        ))
        rightCloseHost = ZeroSafeAreaHostingView(rootView: AnyView(
            UnifiedTabCloseButton { [weak self] in self?.rightCloseTapped() }
        ))
        leftCloseHost.isHidden = true
        rightCloseHost.isHidden = true

        // Per-pane mute toggles. Hidden + zero width by default so the
        // title fills the same space as before when no audio is present;
        // shown with 20pt width when the pane's tab is audible or muted.
        leftMuteHost = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
        rightMuteHost = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
        leftMuteHost.isHidden = true
        rightMuteHost.isHidden = true

        leftMuteWidth = configurePane(leftPane,
                                       icon: leftIconView,
                                       title: leftTitleLabel,
                                       mute: leftMuteHost,
                                       close: leftCloseHost)
        rightMuteWidth = configurePane(rightPane,
                                        icon: rightIconView,
                                        title: rightTitleLabel,
                                        mute: rightMuteHost,
                                        close: rightCloseHost)
        outerBackground.addSubview(leftPane)
        outerBackground.addSubview(rightPane)

        leftPane.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview().inset(2)
            make.width.equalTo(rightPane)
        }
        rightPane.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview().inset(2)
            make.leading.equalTo(leftPane.snp.trailing).offset(2)
        }
        // Long titles must defer to the pane's geometric width — without
        // lowering compression resistance, NSTextField's intrinsic width
        // pulls the pane past `centerX` and the right pane shifts out
        // of the cell entirely.
        leftTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        leftPane.clickAction = { [weak self] in
            guard let self, let tab = self.configuredLeftTab else { return }
            tab.performAction(with: self.owner)
        }
        rightPane.clickAction = { [weak self] in
            guard let self, let tab = self.configuredRightTab else { return }
            tab.performAction(with: self.owner)
        }

        // Vertical seam in the gap between the two panes so the pair
        // always reads as two grouped tabs. Mirrors `splitDividerView`
        // in the horizontal strip.
        dividerView.wantsLayer = true
        dividerView.phiLayer?.setBackgroundColor(ThemedColor.separator)
        outerBackground.addSubview(dividerView)
        dividerView.snp.makeConstraints { make in
            make.centerX.equalTo(outerBackground.snp.centerX)
            make.centerY.equalToSuperview()
            make.width.equalTo(1)
            make.height.equalTo(16)
        }
    }

    @discardableResult
    private func configurePane(_ pane: HoverableView,
                               icon: NSImageView,
                               title: NSTextField,
                               mute: NSView,
                               close: NSView) -> Constraint? {
        // Selection is owned by the outer background — the whole cell
        // becomes the white pill when either pane is active, not just
        // the active half. Leave the pane's own background tints clear
        // so the outer chrome shows through.
        pane.backgroundColor = .clear
        pane.hoveredColor = .clear
        pane.selectedColor = .clear
        pane.enableClickAnimation = false
        pane.responseToClickAction = true
        pane.layer?.cornerRadius = 6
        pane.layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        pane.addSubview(icon)
        icon.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalToSuperview().offset(8)
            make.size.equalTo(CGSize(width: 16, height: 16))
        }

        title.font = NSFont.systemFont(ofSize: 13)
        title.phi.setTextColor(.textPrimary)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.truncatesLastVisibleLine = true
        pane.addSubview(title)

        pane.addSubview(close)
        close.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().offset(-2)
            make.size.equalTo(CGSize(width: 24, height: 24))
        }

        // Mute sits between favicon and title. Width is driven dynamically
        // by the cell so it collapses to 0 when the pane is silent; the
        // 2 / 4 offsets sum to the original 6pt icon→title gap, keeping
        // the silent layout pixel-identical to before.
        pane.addSubview(mute)
        var muteWidthConstraint: Constraint?
        mute.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(icon.snp.trailing).offset(2)
            make.height.equalTo(20)
            muteWidthConstraint = make.width.equalTo(0).constraint
        }

        title.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(mute.snp.trailing).offset(4)
            make.trailing.lessThanOrEqualTo(close.snp.leading).offset(-2)
        }

        return muteWidthConstraint
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isCellHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isCellHovered = false
    }

    private func leftCloseTapped() {
        configuredLeftTab?.close()
    }

    private func rightCloseTapped() {
        configuredRightTab?.close()
    }

    private func updateHoverChrome() {
        leftCloseHost.isHidden = !isCellHovered
        rightCloseHost.isHidden = !isCellHovered
    }

    override func configureAppearance() {
        guard let pair = item as? SplitPairSidebarItem else { return }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        configuredLeftTab = pair.leftTab
        configuredRightTab = pair.rightTab
        configuredSplitId = pair.groupId

        refreshFavicon(into: leftIconView, for: pair.leftTab, handle: &leftFaviconHandle)
        refreshFavicon(into: rightIconView, for: pair.rightTab, handle: &rightFaviconHandle)
        leftTitleLabel.stringValue = pair.leftTab.title
        rightTitleLabel.stringValue = pair.rightTab.title
        toolTip = pair.title
        updateSelected()
        updateHoverChrome()
        updateMute(isLeft: true,
                   audible: pair.leftTab.isCurrentlyAudible,
                   muted: pair.leftTab.isAudioMuted)
        updateMute(isLeft: false,
                   audible: pair.rightTab.isCurrentlyAudible,
                   muted: pair.rightTab.isAudioMuted)

        // Subscribe to each tab's audio state and route by tab identity so a
        // post-swap event lands in the correct pane — the configured left/right
        // mapping changes via `reresolvePairOrderIfNeeded` without re-creating
        // these subscriptions. Same pattern as the title binding above.
        for tab in [pair.leftTab, pair.rightTab] {
            tab.$isCurrentlyAudible
                .combineLatest(tab.$isAudioMuted)
                .removeDuplicates { $0 == $1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] audible, muted in
                    guard let self, let tab else { return }
                    if tab === self.configuredLeftTab {
                        self.updateMute(isLeft: true, audible: audible, muted: muted)
                    } else if tab === self.configuredRightTab {
                        self.updateMute(isLeft: false, audible: audible, muted: muted)
                    }
                }
                .store(in: &cancellables)
        }

        Publishers.CombineLatest(pair.leftTab.$isActive, pair.rightTab.$isActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateSelected() }
            .store(in: &cancellables)

        // Re-resolve left/right when the strip order changes (swap button,
        // drag-to-reorder, etc). The SplitPairSidebarItem keeps the same id
        // across a swap so the outline-view diff skips this row; we rebind
        // ourselves instead of waiting for an item-level reload.
        if let state = browserState {
            state.$normalTabs
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reresolvePairOrderIfNeeded()
                }
                .store(in: &cancellables)
        }

        for tab in [pair.leftTab, pair.rightTab] {
            tab.$liveFaviconData
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.refreshFaviconForTab(tab)
                }
                .store(in: &cancellables)
            tab.$cachedFaviconData
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.refreshFaviconForTab(tab)
                }
                .store(in: &cancellables)
            tab.$url
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.refreshFaviconForTab(tab)
                }
                .store(in: &cancellables)
            tab.$title
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] newTitle in
                    guard let self, let tab else { return }
                    if tab === self.configuredLeftTab {
                        self.leftTitleLabel.stringValue = newTitle
                    } else if tab === self.configuredRightTab {
                        self.rightTitleLabel.stringValue = newTitle
                    }
                }
                .store(in: &cancellables)
            tab.$url
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, let pair = self.item as? SplitPairSidebarItem else { return }
                    self.toolTip = pair.title
                }
                .store(in: &cancellables)
        }
    }

    private func refreshFaviconForTab(_ tab: Tab) {
        if tab === configuredLeftTab {
            refreshFavicon(into: leftIconView, for: tab, handle: &leftFaviconHandle)
        } else if tab === configuredRightTab {
            refreshFavicon(into: rightIconView, for: tab, handle: &rightFaviconHandle)
        }
    }

    private func refreshFavicon(into imageView: NSImageView,
                                for tab: Tab,
                                handle: inout ProfileScopedFaviconLoadHandle?) {
        handle?.cancel()
        handle = nil
        if let live = tab.liveFaviconData, let image = NSImage(data: live) {
            imageView.image = image
            return
        }
        let pageURLString = tab.isOpenned ? (tab.url ?? tab.pinnedUrl) : (tab.pinnedUrl ?? tab.url)
        let request = ProfileScopedFaviconRequest(
            profileId: tab.profileId,
            pageURLString: pageURLString,
            snapshotData: tab.cachedFaviconData
        )
        handle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak imageView, weak tab] result in
            imageView?.image = result.image
            if result.source == .chromium, let data = result.data {
                tab?.updateCachedFaviconData(data)
            }
        }
    }

    /// Show or hide a pane's mute toggle based on its tab's audio state.
    /// Mirrors the audible-or-muted condition `SideTabView` uses for the
    /// regular sidebar row so split panes match unsplit panes visually.
    private func updateMute(isLeft: Bool, audible: Bool, muted: Bool) {
        let hasAudio = audible || muted
        let host = isLeft ? leftMuteHost : rightMuteHost
        let widthConstraint = isLeft ? leftMuteWidth : rightMuteWidth
        host?.isHidden = !hasAudio
        widthConstraint?.update(offset: hasAudio ? 20 : 0)
        guard hasAudio else { return }
        host?.rootView = AnyView(
            SplitPaneMuteButton(isMuted: muted) { [weak self] in
                guard let self else { return }
                let tab = isLeft ? self.configuredLeftTab : self.configuredRightTab
                guard let tab else { return }
                tab.setAudioMuted(!tab.isAudioMuted)
            }
        )
    }

    private func updateSelected() {
        guard let pair = item as? SplitPairSidebarItem else { return }
        // Whole cell flips to the selected pill when *either* pane is the
        // focusing tab. The HoverableView prioritizes its `selectedColor`
        // over its hover tint, so the cell-level NSTrackingArea-driven
        // hover background underneath cleanly yields to the active fill.
        outerBackground.isSelected = pair.leftTab.isActive || pair.rightTab.isActive
    }

    /// If Chromium reordered the pair (swap button / drag), reflect the new
    /// order in the cell. The SplitGroup's primary/secondary updates first;
    /// the strip's `normalTabs` then re-sequences. We compare the cell's
    /// current left/right against the live `normalTabs` order and swap if
    /// the visible mapping is stale.
    private func reresolvePairOrderIfNeeded() {
        guard let pair = item as? SplitPairSidebarItem,
              let state = browserState,
              let leftIdx = state.normalTabs.firstIndex(where: { $0.guid == pair.leftTab.guid }),
              let rightIdx = state.normalTabs.firstIndex(where: { $0.guid == pair.rightTab.guid }) else {
            return
        }
        if leftIdx > rightIdx {
            let oldLeft = pair.leftTab
            pair.leftTab = pair.rightTab
            pair.rightTab = oldLeft
            configuredLeftTab = pair.leftTab
            configuredRightTab = pair.rightTab
            leftTitleLabel.stringValue = pair.leftTab.title
            rightTitleLabel.stringValue = pair.rightTab.title
            refreshFavicon(into: leftIconView, for: pair.leftTab, handle: &leftFaviconHandle)
            refreshFavicon(into: rightIconView, for: pair.rightTab, handle: &rightFaviconHandle)
            toolTip = pair.title
            updateSelected()
            updateMute(isLeft: true,
                       audible: pair.leftTab.isCurrentlyAudible,
                       muted: pair.leftTab.isAudioMuted)
            updateMute(isLeft: false,
                       audible: pair.rightTab.isCurrentlyAudible,
                       muted: pair.rightTab.isAudioMuted)
        }
    }
}

// MARK: - New Tab Button Cell View
class NewTabButtonCellView: SidebarCellView {
    var clickAction: (() -> Void)?

    private lazy var iconView: LottieAnimationNSView = {
        let config = LottieAnimationViewConfig(
            animationName: "new-tab",
            reverseAnimationName: "new-tab-reverse",
            size: CGSize(width: 16, height: 16),
            animationTrigger: .manual,
            themedTintColor: .textTertiary,
            reverseOnHoverExit: true
        )
        return LottieAnimationNSView(config: config)
    }()
    
    private var titleLabel: NSTextField = {
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("New Tab", comment: "side bar new tab button text"))
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.phi.setTextColor(.textTertiary)
        return titleLabel
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard clickAction != nil, bounds.contains(point) else {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        guard let clickAction else {
            super.mouseUp(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        clickAction()
    }
    
    private func setupViews() {
        addSubview(backgoundView)
        backgoundView.shadow = nil
        backgoundView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.bottom.equalToSuperview().inset(2)
        }
        backgoundView.enableClickAnimation = false
        backgoundView.layer?.cornerRadius = 8
        backgoundView.layer?.cornerCurve = .continuous
        backgoundView.backgroundColor = .clear
        backgoundView.hoveredColor = NSColor(resource: .sidebarTabHovered)
        backgoundView.hoverStateChanged = { [weak self] hovered in
            guard let self else { return }
            AppLogDebug("hover changed: \(hovered) - \(self.backgoundView.responseToHoverAnimation)")
            guard self.backgoundView.responseToHoverAnimation else {
                return
            }
            if hovered {
                self.iconView.triggerAnimation()
            } else {
                self.iconView.triggerReverseAnimation()
            }
        }
       
        backgoundView.addSubview(iconView)
        backgoundView.addSubview(titleLabel)
        
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
        }
    }
}

// MARK: - Separator Cell View
class SeparatorCellView: SidebarCellView {
    private var separatorView: NSView!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        separatorView = NSView()
        separatorView.wantsLayer = true
        separatorView.phiLayer?.setBackgroundColor(.separator)
        addSubview(separatorView)

        separatorView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.centerY.equalToSuperview()
            make.height.equalTo(1)
        }
    }
}

protocol TabCellDelegate: AnyObject {
    func tabCellDidRequestClose(_ tab: Tab)
}
