// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Combine
import SwiftUI
class SideAddressBar: NSView {
    static let addressTextFieldAccessibilityIdentifier = "sidebarHeader.addressView"

    private enum LayoutMetrics {
        static let extensionButtonWidth: CGFloat = 24
        static let extensionButtonSpacing: CGFloat = 2
        static let rightStackSpacing: CGFloat = 6
        static let textFieldLeadingInset: CGFloat = 12
        static let textFieldTrailingSpacing: CGFloat = 8
        static let rightStackTrailingInset: CGFloat = 4
        static let minimumAddressTextWidth: CGFloat = 84
    }

    private var containerView: HoverableView!
    private lazy var copyURLButton: HoverableButtonNSView = {
        
        let config = HoverableButtonConfig(
            imageSize: .init(width: 12, height: 12),
            systemName: "link",
            triggeredSystemName: "checkmark",
            symbolWeight: .medium,
            triggeredImageTintColor: .textPrimary,
            imageContentTransition: .symbolEffect(.replace, options: .speed(3)),
            triggeredRevertDelay: 1,
            hoverBackgroundColor: .hover,
            cornerRadius: 4
        )
        let button = HoverableButtonNSView(config: config) { [weak self] in
            self?.copyCurrentURL()
        }
        button.toolTip = NSLocalizedString("sidebar.addressBar.copyLinkButtonTooltip", value: "Copy Link", comment: "Sidebar address bar - Copy current page URL button tooltip")
        button.setCustomTooltip {
            CommandShortcutTooltipContent(
                title: NSLocalizedString("sidebar.addressBar.copyURLShortcutTooltip", value: "Copy URL", comment: "Copy URL shortcut tooltip title"),
                command: .PHI_COPY_URL
            )
        }
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 24, height: 24))
        }
        return button
    }()

    private lazy var readerButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(
            imageSize: .init(width: 12, height: 12),
            systemName: "doc.plaintext",
            symbolWeight: .medium,
            hoverBackgroundColor: .hover,
            cornerRadius: 4
        )
        let button = HoverableButtonNSView(config: config) { [weak self] in
            self?.toggleReaderView()
        }
        button.toolTip = NSLocalizedString("sidebar.addressBar.readerViewButtonTooltip", value: "Reader View", comment: "Sidebar address bar - Reader View button tooltip")
        button.setCustomTooltip {
            CommandShortcutTooltipContent(
                title: NSLocalizedString("sidebar.addressBar.readerViewShortcutTooltip", value: "Reader View", comment: "Reader View shortcut tooltip title"),
                command: .PHI_TOGGLE_READER
            )
        }
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 24, height: 24))
        }
        button.isHidden = true
        return button
    }()

    private lazy var extensionMenuHostingView: NSHostingView<ExtensionPopoverButton> = {
        let hosting = NSHostingView(rootView: ExtensionPopoverButton(extensionManager: nil))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }()
    
    private var textField: NSTextField!
    private var rightStackView: CustomStackView!
    private var extensionIconsStackView: ExtensionReorderStackView!
    @Published var currentTab: Tab?
    
    private var cancellables = Set<AnyCancellable>()
    // The last (unfiltered) pinned set handed to updateExtensionIcons, so a
    // dynamic-icon or visibility change can rebuild and re-apply the visibility
    // filter without re-deriving the display gating.
    private var lastPinnedExtensions: [Extension] = []

    var showBackgroundWhenInactive: Bool = true {
        didSet {
            updateBackgroundAppearance()
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        
        setupContainerView()
        setupTextField()
        setupRightStackView()
        setupLayout()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupObservers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.unsafeBrowserState?.extensionManager.refreshExtensions()
        }
    }
    
    private func setupObservers() {
        guard let browserState = unsafeBrowserState else { return }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        extensionMenuHostingView.rootView = ExtensionPopoverButton(extensionManager: browserState.extensionManager)

        $currentTab
            .compactMap { $0 }
            .map { tab in
                tab.$url
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] url in
                guard browserState.isInPlaceholderMode != true else { return }
                self?.updateDisplayedURL(url)
            }
            .store(in: &cancellables)

        browserState.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard browserState.isInPlaceholderMode != true else { return }
                self?.updateDisplayedURL(self?.currentTab?.url)
            }
            .store(in: &cancellables)

        // Placeholder-mode sink: blank text on enter, restore on exit.
        // Also hide the trailing accessory buttons (copy link, extension menu)
        // and any in-bar extension icons — there's no tab context to act on.
        browserState.$isInPlaceholderMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaceholder in
                guard let self else { return }
                if isPlaceholder {
                    self.textField.stringValue = ""
                } else {
                    self.updateDisplayedURL(self.currentTab?.url)
                }
                self.copyURLButton.isHidden = isPlaceholder
                self.extensionMenuHostingView.isHidden = isPlaceholder
                self.extensionIconsStackView.isHidden = isPlaceholder
                self.updateReaderButtonVisibility()
            }
            .store(in: &cancellables)

        // The tab judges its own reader-worthiness per navigation (site rule
        // or in-page readerability heuristic — see Tab.isReaderOfferable);
        // this bar only mirrors the verdict.
        $currentTab
            .flatMap { tab -> AnyPublisher<Bool, Never> in
                guard let tab else {
                    return Just(false).eraseToAnyPublisher()
                }
                return tab.$isReaderOfferable.eraseToAnyPublisher()
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateReaderButtonVisibility()
            }
            .store(in: &cancellables)

        let widthPublisher = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: containerView)
            .map { [weak self] _ in self?.containerView.bounds.width ?? 0 }
            .prepend(containerView.bounds.width)
            .removeDuplicates()
            .eraseToAnyPublisher()
        
        browserState.extensionManager.$pinedExtensions
            .combineLatest(widthPublisher, browserState.$layoutMode)
            .map { [weak self] exts, width, layoutMode in
                guard layoutMode == .performance else { return false }
                return self?.shouldDisplayPinnedExtensionsWithinSidebar(
                    pinnedExtensionCount: exts.count,
                    containerWidth: width
                ) ?? false
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { shouldDisplay in
                browserState.extensionManager.shouldDisplayExtensionsWithinSidebar = shouldDisplay
            }
            .store(in: &cancellables)

        browserState.extensionManager.$pinedExtensions
            .combineLatest(
                browserState.extensionManager.$shouldDisplayExtensionsWithinSidebar.removeDuplicates(),
                browserState.$layoutMode.removeDuplicates(),
                browserState.$isInPlaceholderMode.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinnedExtensions, display, layoutMode, isPlaceholder in
                // Include placeholder mode so the visibility filter is re-applied
                // on placeholder exit (mirrors PinnedTabViewController); otherwise
                // a per-tab visibility flip during placeholder leaves stale icons.
                guard layoutMode == .performance, display == false, !isPlaceholder else {
                    self?.updateExtensionIcons([])
                    return
                }
                self?.updateExtensionIcons(pinnedExtensions)
            }
            .store(in: &cancellables)

        // Rebuild the shown buttons when a dynamic icon changes (the pinned set
        // is unchanged, so the subscription above won't fire). Badge *text*
        // changes are handled by the self-observing BadgeCornerOverlay host and
        // don't need a rebuild; badge *visibility* flips do (handled below).
        browserState.extensionManager.$dynamicIcons
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.extensionIconsStackView.isHidden else { return }
                self.updateExtensionIcons(self.lastPinnedExtensions)
            }
            .store(in: &cancellables)

        // Rebuild only when an extension's render state flips — a page action
        // hidden/shown (icon appears/disappears in step with the header) or an
        // action disabled/enabled (icon re-baked grayed out). Gated on the
        // render-state set so a rapid badge-text tick (e.g. a blocked-count)
        // does NOT trigger a rebuild.
        browserState.extensionManager.$badges
            .map(ExtensionManager.actionRenderStates)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.extensionIconsStackView.isHidden else { return }
                self.updateExtensionIcons(self.lastPinnedExtensions)
            }
            .store(in: &cancellables)

        // Rebuild when the engine's transient Reorder Preview order changes so
        // the icon row follows the drag live (and snaps back when it resets).
        browserState.extensionManager.pinnedExtensionOrdering.$presentationOrder
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.extensionIconsStackView.isHidden else { return }
                self.updateExtensionIcons(self.lastPinnedExtensions)
            }
            .store(in: &cancellables)
    }

    private func updateExtensionIcons(_ pinnedExtensions: [Extension]) {
        lastPinnedExtensions = pinnedExtensions
        // Hide page actions reporting visible == false on the current tab,
        // mirroring the header (spec §4.3). The badge pill self-updates via the
        // hosted overlay; whole-icon show/hide needs this rebuild.
        let manager = unsafeBrowserState?.extensionManager
        let ordered = manager?.presentedPinnedOrder(of: pinnedExtensions) ?? pinnedExtensions
        let visibleExtensions = ordered.filter {
            manager?.badges[$0.id]?.visible != false
        }
        extensionIconsStackView.arrangedSubviews.forEach { view in
            extensionIconsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for ext in visibleExtensions {
            let button = createExtensionButton(for: ext)
            extensionIconsStackView.addArrangedSubview(button)
        }
        refreshReorderSourceVisibility()
    }

    private func updateDisplayedURL(_ url: String?) {
        guard unsafeBrowserState?.groupOverviewState == nil,
              let url,
              !url.isNTP else {
            textField.stringValue = ""
            return
        }
        // A reader page stands in for its article: show the article's URL.
        let displayURL = ReaderExtensionBridge.sourceURLString(fromReaderPageURL: url) ?? url
        textField.stringValue = URLProcessor.displayName(for: displayURL)
    }

    private func shouldDisplayPinnedExtensionsWithinSidebar(
        pinnedExtensionCount: Int,
        containerWidth: CGFloat
    ) -> Bool {
        guard pinnedExtensionCount > 0 else { return false }

        let pinnedIconsWidth = CGFloat(pinnedExtensionCount) * LayoutMetrics.extensionButtonWidth
        let pinnedIconsSpacing = CGFloat(max(0, pinnedExtensionCount - 1)) * LayoutMetrics.extensionButtonSpacing
        let rightControlsWidth = pinnedIconsWidth
            + pinnedIconsSpacing
            + LayoutMetrics.rightStackSpacing
            + LayoutMetrics.extensionButtonWidth
        let reservedHorizontalInsets = LayoutMetrics.textFieldLeadingInset
            + LayoutMetrics.textFieldTrailingSpacing
            + LayoutMetrics.rightStackTrailingInset
        let remainingTextWidth = containerWidth - rightControlsWidth - reservedHorizontalInsets

        return remainingTextWidth < LayoutMetrics.minimumAddressTextWidth
    }
    
    private func createExtensionButton(for ext: Extension) -> HoverableButtonNSView {
        let iconSize = NSSize(width: 16, height: 16)
        let manager = unsafeBrowserState?.extensionManager
        // Icon only (dynamic override + fallback); the badge is a hosted overlay.
        let image = manager?.iconImage(extensionId: ext.id, staticIcon: ext.icon)
            ?? ext.icon
            ?? NSImage()

        let config = HoverableButtonConfig(image: image,
                                           imageSize: iconSize,
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           cornerRadius: 4)
        // The engine re-validates at beginDrag; this gate only decides whether
        // the button owns its left-mouse events for click-vs-drag tracking.
        // The hosted SwiftUI action stays wired in both branches so
        // accessibility activation keeps working.
        let button: HoverableButtonNSView
        if unsafeBrowserState?.isIncognito == false && !ext.isForcePinned {
            let draggable = DraggableExtensionButton(
                config: config, target: self, selector: #selector(extensionButtonClicked(_:)))
            draggable.onPrimaryClick = { [weak self, weak draggable] in
                guard let self, let draggable else { return }
                self.extensionButtonClicked(draggable)
            }
            draggable.onDragPastHysteresis = { [weak self, weak draggable] event in
                guard let self, let draggable else { return }
                self.beginExtensionReorderDrag(for: ext.id, from: draggable, with: event)
            }
            button = draggable
        } else {
            button = HoverableButtonNSView(
                config: config, target: self, selector: #selector(extensionButtonClicked(_:)))
        }
        button.toolTip = ext.name

        button.identifier = NSUserInterfaceItemIdentifier(ext.id)
        button.secondaryAction = { [weak self, weak button] in
            guard let self, let button else { return }
            guard let extensionId = button.identifier?.rawValue else { return }

            let point = ExtensionPopupAnchor.pointBelowView(button)
                ?? ExtensionPopupAnchor.mouseFallback()

            ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                withId: extensionId,
                pointInScreen: point,
                windowId: self.unsafeBrowserState?.windowId.int64Value ?? 0
            )
        }

        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 24, height: 24))
        }

        // Self-observing badge overlay, edge-pinned over the button (edges are
        // flip-agnostic; SwiftUI handles the bottom-right corner placement).
        if let manager {
            // Pass-through host: the decorative badge must not swallow the
            // button's click — the icon is a SwiftUI Button beneath it, whose
            // gesture needs the hit-test to reach its own hosting view.
            let badgeHost = BadgeHostingView(
                rootView: BadgeCornerOverlay(manager: manager,
                                             extensionId: ext.id,
                                             iconSize: iconSize.width))
            button.addSubview(badgeHost)
            badgeHost.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        return button
    }
    
    private func copyCurrentURL() {
        guard var urlString = currentTab?.url, !urlString.isEmpty else { return }
        urlString = ReaderExtensionBridge.sourceURLString(fromReaderPageURL: urlString) ?? urlString
        let branded = URLProcessor.phiBrandEnsuredUrlString(urlString)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branded, forType: .string)
    }

    private func toggleReaderView() {
        guard let tab = currentTab,
              let browserState = unsafeBrowserState else { return }
        browserState.toggleReaderView(for: tab, from: .addressBar)
    }

    private func updateReaderButtonVisibility() {
        let isPlaceholder = unsafeBrowserState?.isInPlaceholderMode ?? false
        // The tab's verdict comes from the extraction service (site rule or
        // readerability probe), not a local copy of the test, so the button
        // and the feature cannot disagree about a page. They did once: this
        // bar kept its own "is this a real web page" and went on offering the
        // reader on a PDF after extraction had begun refusing it.
        readerButton.isHidden = isPlaceholder
            || !(currentTab?.isReaderOfferable ?? false)
    }

    @objc private func extensionButtonClicked(_ sender: NSView) {
        guard let extensionId = sender.identifier?.rawValue else { return }

        // A disabled action doesn't run; fall back to the context menu like
        // Chrome (ExecuteUserAction).
        if unsafeBrowserState?.extensionManager.badges[extensionId]?.enabled == false {
            let point = ExtensionPopupAnchor.pointBelowView(sender)
                ?? ExtensionPopupAnchor.mouseFallback()
            ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                withId: extensionId,
                pointInScreen: point,
                windowId: unsafeBrowserState?.windowId.int64Value ?? 0
            )
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
            withId: extensionId,
            anchorRect: ExtensionPopupAnchor.rectOfView(sender),
            windowId: unsafeBrowserState?.windowId.int64Value ?? 0
        )
    }
   
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        unsafeBrowserWindowController?.openLocationBar(containerView)
    }
    
    private func setupContainerView() {
        containerView = HoverableView()
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.hoveredColor = .sidebarTabHoveredColorEmphasized
        containerView.postsFrameChangedNotifications = true
        addSubview(containerView)
        updateBackgroundAppearance()
    }

    private func updateBackgroundAppearance() {
        if showBackgroundWhenInactive {
            containerView?.backgroundColor = .sidebarTabHovered
        } else {
            containerView?.backgroundColor = .clear
        }
    }
    
    private func setupTextField() {
        textField = NSTextField()
        textField.isBordered = false
        textField.backgroundColor = NSColor.clear
        textField.font = NSFont.systemFont(ofSize: 13)
        
        let placeholder = NSMutableAttributedString(string: NSLocalizedString("sidebar.addressBar.placeholder", value: "Search or Enter URL", comment: "Sidebar address bar - Placeholder text prompting user to enter URL or search query"))
        placeholder.addAttributes([
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 13)
        ], range: NSRange(location: 0, length: placeholder.length))
        textField.placeholderAttributedString = placeholder
        
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.focusRingType = .none
        textField.maximumNumberOfLines = 1
        textField.isEditable = false
        textField.isSelectable = false
        textField.lineBreakMode = .byTruncatingTail
        textField.setAccessibilityIdentifier(Self.addressTextFieldAccessibilityIdentifier)
        containerView.addSubview(textField)
    }
    
    private func setupRightStackView() {
        rightStackView = CustomStackView()
        rightStackView.orientation = .horizontal
        rightStackView.spacing = 2
        rightStackView.alignment = .centerY
        rightStackView.distribution = .gravityAreas
        
        extensionIconsStackView = ExtensionReorderStackView()
        extensionIconsStackView.orientation = .horizontal
        extensionIconsStackView.spacing = 2
        extensionIconsStackView.alignment = .centerY
        extensionIconsStackView.registerForDraggedTypes([.phiPinnedExtensionReorder])
        extensionIconsStackView.onReorderUpdate = { [weak self] x in
            self?.updateExtensionReorderPreview(atX: x) ?? false
        }
        extensionIconsStackView.onReorderExited = { [weak self] in
            self?.unsafeBrowserState?.extensionManager
                .leavePinnedExtensionReorder(surface: .sidebarAddressBar)
        }
        extensionIconsStackView.onReorderDrop = { [weak self] x in
            self?.commitExtensionReorderDrop(atX: x) ?? false
        }
        
        rightStackView.addArrangedSubview(extensionIconsStackView)
        rightStackView.addArrangedSubview(readerButton)
        rightStackView.addArrangedSubview(copyURLButton)
        rightStackView.addArrangedSubview(extensionMenuHostingView)
        extensionMenuHostingView.snp.makeConstraints { make in
            make.width.height.equalTo(24)
        }
        containerView.addSubview(rightStackView)
    }
    
    private func setupLayout() {
        containerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.bottom.equalToSuperview()
        }

        rightStackView.setContentHuggingPriority(.init(1000), for: .horizontal)
        rightStackView.setContentCompressionResistancePriority(.init(1000), for: .horizontal)
        rightStackView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().inset(2)
            make.height.equalToSuperview()
        }

        textField.setContentHuggingPriority(.init(1), for: .horizontal)
        textField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        textField.snp.makeConstraints { make in
            make.leading.equalTo(containerView).offset(12)
            make.centerY.equalTo(containerView)
            make.trailing.equalTo(rightStackView.snp.leading).offset(-8)
        }
    }
    
    private func createIconButton(systemName: String? = nil, size: CGFloat, image: NSImage?) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        if let image {
            button.image = image
        } else if let systemName {
            if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
            }
        }
       
        
        button.imageScaling = .scaleProportionallyDown
        
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: size + 4, height: size + 4))
        }
        
        return button
    }
}

struct ExtensionPopoverButton: View {
    @State private var isShown = false
    let extensionManager: ExtensionManager?

    @State private var anchorView: NSView?

    var body: some View {
        let isPresented = Binding(
            get: { isShown && extensionManager != nil },
            set: { isShown = $0 }
        )

        LottieMenuButtonRepresentable(isShown: $isShown)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .background(
                AddressBarAnchorView { view in
                    anchorView = view
                }
                .allowsHitTesting(false)
            )
        .popover(isPresented: isPresented, arrowEdge: .top) {
            if let manager = extensionManager {
                ExtensionList(
                    extensionManager: manager,
                    onRequestDismiss: { isShown = false },
                    triggerAnchorView: anchorView
                )
            } else {
                EmptyView()
            }
        }
    }
}

struct LottieMenuButtonRepresentable: NSViewRepresentable {
    @Binding var isShown: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isShown: $isShown)
    }

    func makeNSView(context: Context) -> LottieAnimationNSView {
        let config = LottieAnimationViewConfig(
            animationName: "extension-button",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 4,
            animationTrigger: .onHoverEnter,
            themedTintColor: .textPrimary,
            reverseOnHoverExit: true
        )
        let view = LottieAnimationNSView(config: config, target: context.coordinator, selector: #selector(Coordinator.handleClick))
        return view
    }

    func updateNSView(_ nsView: LottieAnimationNSView, context: Context) {
    }

    class Coordinator: NSObject {
        private var isShown: Binding<Bool>

        init(isShown: Binding<Bool>) {
            self.isShown = isShown
        }

        @objc func handleClick() {
            isShown.wrappedValue.toggle()
        }
    }
}

extension SideAddressBar {
    class CustomStackView: NSStackView {
        override func mouseDown(with event: NSEvent) {
        }
    }
}

// MARK: - Pinned extension reordering (Pinned Extension Surface: sidebar address bar)

extension SideAddressBar {
    struct ExtensionReorderSlot: Equatable {
        let id: String
        let midX: CGFloat
    }

    /// Maps a pointer x (in the icon row's coordinates) to the Anchored Reorder
    /// intent for the shared ordering engine: the nearest visible action is the
    /// target, and the pointer's side of its midpoint picks the placement.
    /// Pointers ahead of the first or past the last action clamp to the ends.
    static func extensionReorderAnchor(
        atX x: CGFloat,
        slots: [ExtensionReorderSlot]
    ) -> (targetId: String, placement: PinnedExtensionAnchorPlacement)? {
        guard let nearest = slots.min(by: { abs($0.midX - x) < abs($1.midX - x) }) else {
            return nil
        }
        return (nearest.id, x < nearest.midX ? .before : .after)
    }

    private func beginExtensionReorderDrag(
        for extensionId: String,
        from button: NSView,
        with event: NSEvent
    ) {
        guard let manager = unsafeBrowserState?.extensionManager else { return }
        let visibleProjection = extensionIconsStackView.arrangedSubviews.compactMap {
            $0.identifier?.rawValue
        }
        guard manager.beginPinnedExtensionReorder(
            extensionId: extensionId,
            visibleProjection: visibleProjection,
            surface: .sidebarAddressBar
        ) else {
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(extensionId, forType: .phiPinnedExtensionReorder)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // Snapshot the live button so the drag image keeps the current dynamic
        // icon and badge state.
        let frameInRow = extensionIconsStackView.convert(button.bounds, from: button)
        if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let image = NSImage(size: button.bounds.size)
            image.addRepresentation(bitmap)
            draggingItem.setDraggingFrame(frameInRow, contents: image)
        } else {
            draggingItem.setDraggingFrame(frameInRow, contents: nil)
        }
        // The session starts from the icon row, not the button: preview
        // rebuilds replace the buttons mid-drag and the session must
        // outlive them.
        extensionIconsStackView.beginDraggingSession(
            with: [draggingItem], event: event, source: self)
        refreshReorderSourceVisibility()
    }

    private func updateExtensionReorderPreview(atX x: CGFloat) -> Bool {
        guard let manager = unsafeBrowserState?.extensionManager else { return false }
        // A preview rebuild may still be pending layout when the next drag
        // update arrives; settle frames before hit-testing them.
        extensionIconsStackView.layoutSubtreeIfNeeded()
        let slots = extensionIconsStackView.arrangedSubviews.compactMap { view -> ExtensionReorderSlot? in
            guard let id = view.identifier?.rawValue else { return nil }
            return ExtensionReorderSlot(id: id, midX: view.frame.midX)
        }
        guard let anchor = Self.extensionReorderAnchor(atX: x, slots: slots) else {
            return false
        }
        return manager.updatePinnedExtensionReorder(
            targetExtensionId: anchor.targetId,
            placement: anchor.placement,
            surface: .sidebarAddressBar
        )
    }

    private func commitExtensionReorderDrop(atX x: CGFloat) -> Bool {
        guard let manager = unsafeBrowserState?.extensionManager,
              updateExtensionReorderPreview(atX: x),
              manager.commitPinnedExtensionReorder(surface: .sidebarAddressBar) else {
            unsafeBrowserState?.extensionManager
                .cancelPinnedExtensionReorder(surface: .sidebarAddressBar)
            return false
        }
        return true
    }

    /// Hides the drag's source icon (alpha 0, still arranged) so the drag
    /// image is the only visible copy; the empty slot the row keeps open
    /// marks the landing spot. Recomputed from the engine so drag end (or a
    /// reset) restores every icon.
    private func refreshReorderSourceVisibility() {
        let draggedId = unsafeBrowserState?.extensionManager
            .pinnedExtensionOrdering.draggedExtensionId
        for view in extensionIconsStackView.arrangedSubviews {
            view.alphaValue = (draggedId != nil && view.identifier?.rawValue == draggedId)
                ? 0 : 1
        }
    }
}

extension SideAddressBar: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Surface-Local Reorder: the payload never leaves the application.
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // A successful drop already advanced the engine to Pending Reorder
        // Confirmation, which makes this cancel a no-op; every other outcome
        // (Escape, drop outside the row, rejected drop) abandons the drag.
        unsafeBrowserState?.extensionManager
            .cancelPinnedExtensionReorder(surface: .sidebarAddressBar)
        refreshReorderSourceVisibility()
    }
}

/// Extension icon button that arms an AppKit reorder drag. The hosted SwiftUI
/// button consumes left-mouse events, so this subclass claims them at
/// hit-test time (right-clicks, hover tracking, and accessibility activation
/// are untouched) and re-implements click-vs-drag: a release inside the
/// bounds is the click, movement past standard hysteresis asks the surface to
/// begin a dragging session.
private final class DraggableExtensionButton: HoverableButtonNSView {
    var onPrimaryClick: (() -> Void)?
    /// Invoked once per gesture when the pointer crosses drag hysteresis; the
    /// surface decides whether a dragging session starts.
    var onDragPastHysteresis: ((NSEvent) -> Void)?

    private var mouseDownPoint: CGPoint?
    private var hasCrossedHysteresis = false
    private let dragThreshold: CGFloat = 5

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let result = super.hitTest(point) else { return nil }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return self
        default:
            return result
        }
    }

    override func mouseDown(with event: NSEvent) {
        // No super: NSView would forward up the responder chain and
        // SideAddressBar.mouseDown opens the location bar.
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasCrossedHysteresis = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint, !hasCrossedHysteresis else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard abs(currentPoint.x - startPoint.x) > dragThreshold
                || abs(currentPoint.y - startPoint.y) > dragThreshold else { return }
        // Crossing hysteresis consumes the gesture whether or not a session
        // starts: a rejected reorder attempt must not fall back to a click,
        // because extension actions stay suppressed once a reorder begins.
        hasCrossedHysteresis = true
        onDragPastHysteresis?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if !hasCrossedHysteresis,
           bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPrimaryClick?()
        }
        mouseDownPoint = nil
        hasCrossedHysteresis = false
    }
}

/// The pinned extension icon row: the drop side of the sidebar address bar's
/// Surface-Local Reorder. Drops anywhere else in the address bar or sidebar
/// never reach a registered destination and cancel through the source's
/// session-ended callback.
private final class ExtensionReorderStackView: SideAddressBar.CustomStackView {
    var onReorderUpdate: ((CGFloat) -> Bool)?
    var onReorderExited: (() -> Void)?
    var onReorderDrop: ((CGFloat) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        reorderOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        reorderOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onReorderExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onReorderDrop?(convert(sender.draggingLocation, from: nil).x) ?? false
    }

    private func reorderOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        (onReorderUpdate?(convert(sender.draggingLocation, from: nil).x) ?? false)
            ? .move : []
    }
}
