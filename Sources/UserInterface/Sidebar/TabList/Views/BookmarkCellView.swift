// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// A lightweight protocol to allow the sidebar to show "virtual" bookmark items
/// while still rendering and operating on the underlying real `Bookmark`.
protocol UnderlyingBookmarkProviding {
    var underlyingBookmark: Bookmark { get }
}

/// Delegate for bookmark title edits.
protocol BookmarkCellViewDelegate: AnyObject {
    func bookmarkCellDidEndEditing(_ bookmark: Bookmark, newTitle: String)
}

@Observable
private final class BookmarkCellViewState {
    var title = ""
    var editText = ""
    var primaryPageURL: String?
    var secondaryPageURL: String?
    var primaryFaviconImage: NSImage?
    var secondaryFaviconImage: NSImage?
    var primaryFaviconRevision = 0
    var secondaryFaviconRevision = 0
    var showsSecondaryFavicon = false
    /// A Peek opened from this bookmark's bound tab is alive (visible or
    /// hidden behind another tab) — drives the trailing peek indicator.
    var showsPeek = false
    var primaryTabIsLive = false
    var secondaryTabIsLive = false
    var isFolder = false
    var isFolderExpanded = false
    var folderIcon = BookmarkFolderIcon.standard
    var usesStaticFolderSnapshotIcon = false
    var folderIconPickerRequestGeneration = 0
    var isActive = false
    var isOpened = false
    var isHovered = false
    var isPressed = false
    var isEditing = false
    var isMultiSelected = false
    var isDropTargetHighlighted = false
    var showsTabPreview = false
}

private final class VerticallyCenteredBookmarkTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(forBounds: super.drawingRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: adjustedRect(forBounds: rect),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: adjustedRect(forBounds: rect),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
    }

    private func adjustedRect(forBounds rect: NSRect) -> NSRect {
        let titleSize = cellSize(forBounds: rect)
        let delta = max(0, rect.height - titleSize.height)
        return rect.insetBy(dx: 0, dy: floor(delta / 2))
    }
}

class BookmarkCellView: SidebarCellView, TabPreviewInteractionCancelling {
    /// Identifier stamped on every sidebar bookmark row's content view.
    static let accessibilityIdentifier = "sidebarBookmark"

    private let viewState = BookmarkCellViewState()
    private let primaryTabViewModel = TabViewModel()
    private let secondaryTabViewModel = TabViewModel()
    private let peekTabViewModel = TabViewModel()
    private let hoverRegionView = SidebarTabHoverRegionView()
    private let tabPreviewRegistration = TabPreviewRegistration()
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    // Keep the rename field in AppKit instead of the SwiftUI subtree.
    // Hover-driven SwiftUI updates were rebuilding the representable path and
    // tearing down the field editor mid-rename. SwiftUI makes this much more
    // fragile than a plain NSTextField needs to be.
    private let editField = NSTextField()
    private var hostingView: ThemedHostingView!
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var secondaryFaviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private weak var configuredBookmark: Bookmark?
    private weak var configuredPrimaryTab: Tab?
    private weak var configuredSecondaryTab: Tab?
    private var usesSplitTabPreview = false
    private var isEditingActive = false

    weak var browserState: BrowserState?
    weak var editDelegate: BookmarkCellViewDelegate?

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
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        secondaryFaviconLoadHandle?.cancel()
        secondaryFaviconLoadHandle = nil
        configuredBookmark = nil
        configuredPrimaryTab = nil
        configuredSecondaryTab = nil
        isEditingActive = false
        editField.stringValue = ""
        editField.isHidden = true
        primaryTabViewModel.prepareForReuse()
        secondaryTabViewModel.prepareForReuse()
        usesSplitTabPreview = false
        tabPreviewRegistration.invalidate()
        splitTabPreviewRegistration.invalidate()
        peekTabViewModel.prepareForReuse()
        resetState()
    }

    func cancelTabPreviewForInteraction() {
        tabPreviewRegistration.cancelForInteraction()
        splitTabPreviewRegistration.cancelForInteraction()
    }

    /// Uses a paused, cache-display-safe Lottie renderer while an AppKit snapshot is rendered.
    func withStaticFolderSnapshotIcon<T>(_ body: () throws -> T) rethrows -> T {
        guard viewState.isFolder else { return try body() }
        let wasUsingStaticIcon = viewState.usesStaticFolderSnapshotIcon
        setUsesStaticFolderSnapshotIcon(true)
        defer { setUsesStaticFolderSnapshotIcon(wasUsingStaticIcon) }
        return try body()
    }

    override func createDraggingImage() -> NSImage? {
        withStaticFolderSnapshotIcon {
            super.createDraggingImage()
        }
    }

    private func setUsesStaticFolderSnapshotIcon(_ usesStaticIcon: Bool) {
        guard viewState.usesStaticFolderSnapshotIcon != usesStaticIcon else { return }
        viewState.usesStaticFolderSnapshotIcon = usesStaticIcon
        hostingView.needsLayout = true
        hostingView.needsDisplay = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        hostingView = ThemedHostingView(rootView: SidebarBookmarkCellContentView(
            state: viewState,
            primaryTabViewModel: primaryTabViewModel,
            secondaryTabViewModel: secondaryTabViewModel,
            primaryStatusModel: primaryTabViewModel.status,
            secondaryStatusModel: secondaryTabViewModel.status,
            peekTabViewModel: peekTabViewModel,
            onClose: { [weak self] in
                self?.closeButtonTapped()
            },
            onClosePeek: { [weak self] in
                guard let self, let bookmark = self.configuredBookmark,
                      let boundTabId = self.liveTabs(for: bookmark).primary?.guid else { return }
                self.resolvedBrowserState?.closePeek(forOpener: boundTabId)
            },
            onNavigatePrimaryToOriginalURL: { [weak self] separateCurrentPage in
                self?.navigatePrimaryToOriginalURL(separateCurrentPage: separateCurrentPage)
            },
            onNavigateSecondaryToOriginalURL: { [weak self] separateCurrentPage in
                self?.navigateSecondaryToOriginalURL(separateCurrentPage: separateCurrentPage)
            },
            onSelectFolderIcon: { [weak self] icon in
                self?.selectFolderIcon(icon)
            }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // The hosting view renders the display state, while AppKit owns the
        // inline editor so responder and hover changes stay decoupled.
        setupEditField()
        addSubview(editField)
        updateEditFieldLayout()

        tabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            guard self?.usesSplitTabPreview == false else { return }
            self?.viewState.showsTabPreview = isEligible
        }
        splitTabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            guard self?.usesSplitTabPreview == true else { return }
            self?.viewState.showsTabPreview = isEligible
        }

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.viewState.isHovered = isHovered
            if self?.usesSplitTabPreview == true {
                self?.splitTabPreviewRegistration.setHovering(isHovered)
            } else {
                self?.tabPreviewRegistration.setHovering(isHovered)
            }
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        setupPressAnimation()
    }

    private func setupPressAnimation() {
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 5
        press.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(press)
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            viewState.isPressed = true
        case .ended, .cancelled, .failed:
            viewState.isPressed = false
        default:
            break
        }
    }

    private func resetState() {
        viewState.title = ""
        viewState.editText = ""
        viewState.primaryPageURL = nil
        viewState.secondaryPageURL = nil
        viewState.primaryFaviconImage = nil
        viewState.secondaryFaviconImage = nil
        viewState.primaryFaviconRevision &+= 1
        viewState.secondaryFaviconRevision &+= 1
        viewState.showsSecondaryFavicon = false
        viewState.showsPeek = false
        viewState.primaryTabIsLive = false
        viewState.secondaryTabIsLive = false
        viewState.isFolder = false
        viewState.isFolderExpanded = false
        viewState.folderIcon = .standard
        viewState.usesStaticFolderSnapshotIcon = false
        viewState.folderIconPickerRequestGeneration = 0
        viewState.isActive = false
        viewState.isOpened = false
        viewState.isHovered = false
        viewState.isPressed = false
        viewState.isEditing = false
        viewState.isMultiSelected = false
        viewState.isDropTargetHighlighted = false
        viewState.showsTabPreview = false
    }

    private func setupEditField() {
        // Borderless NSTextField still draws text a little high by default, so
        // use a custom cell to keep the visible text and live editor centered.
        editField.cell = VerticallyCenteredBookmarkTextFieldCell()
        editField.font = NSFont.systemFont(ofSize: 13)
        editField.textColor = .labelColor
        editField.isEditable = true
        editField.isSelectable = true
        editField.isBordered = false
        editField.isBezeled = false
        editField.drawsBackground = false
        editField.backgroundColor = .clear
        editField.focusRingType = .none
        editField.usesSingleLineMode = true
        editField.lineBreakMode = .byClipping
        editField.cell?.isScrollable = true
        editField.cell?.wraps = false
        editField.cell?.isBordered = false
        editField.cell?.isBezeled = false
        editField.cell?.focusRingType = .none
        editField.delegate = self
        editField.isHidden = true
    }

    private func updateEditFieldLayout() {
        // Match the SwiftUI row chrome:
        // `edgesSpacing` is the outer row inset. Folder icons use a 20-point
        // slot with 4 points of leading padding, while regular bookmark
        // favicons keep their original 16-point slot with 6 points of leading
        // padding, so both icon centers stay aligned. Folders use a 6-point
        // title gap; regular bookmarks retain their original 8-point gap.
        let leadingPadding: CGFloat = viewState.isFolder ? 4 : 6
        let primaryFaviconSlotSize: CGFloat = viewState.isFolder ? 20 : 16
        let titleGap: CGFloat = viewState.isFolder ? 6 : 8
        let secondaryFaviconOffset: CGFloat = viewState.showsSecondaryFavicon ? 24 : 0
        let leadingOffset = WebContentConstant.edgesSpacing
            + leadingPadding
            + primaryFaviconSlotSize
            + titleGap
            + secondaryFaviconOffset
        editField.snp.remakeConstraints { make in
            make.leading.equalToSuperview().offset(leadingOffset)
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing + 8)
            make.centerY.equalToSuperview()
            make.height.equalTo(22)
        }
    }

    override func configureAppearance() {
        guard let bookmark = resolvedBookmark else { return }
        configuredBookmark = bookmark

        // Expose to UI testing as a button so the test reset can find and
        // delete bookmark rows. This tags the cell *content* view (not the
        // outline row), so the row-level `cells`/`selected` AX the tab tests
        // rely on is unaffected.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(BookmarkCellView.accessibilityIdentifier)
        setAccessibilityLabel(bookmark.title)

        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        secondaryFaviconLoadHandle?.cancel()
        secondaryFaviconLoadHandle = nil
        viewState.isDropTargetHighlighted = false

        viewState.isFolder = bookmark.isFolder
        viewState.isActive = bookmark.isActive
        viewState.isEditing = bookmark.isEditing
        viewState.isMultiSelected = resolvedBrowserState?.multiSelection.containsBookmark(bookmark.guid) == true
        viewState.editText = bookmark.title
        editField.stringValue = bookmark.title
        updateEditFieldLayout()

        configurePreview(for: bookmark, browserState: resolvedBrowserState)

        refreshLiveTabs(for: bookmark)
        applyTitleAndSplitState(bookmark: bookmark,
                                primaryTitle: bookmark.title,
                                secondaryUrl: bookmark.secondaryUrl,
                                secondaryTitle: bookmark.secondaryTitle)
        updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
        if bookmark.isFolder {
            updateFolderIcon(bookmark: bookmark)
        }

        Publishers.CombineLatest3(bookmark.$title,
                                  bookmark.$secondaryUrl,
                                  bookmark.$secondaryTitle)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] primaryTitle, secondaryUrl, secondaryTitle in
                guard let self, let bookmark else { return }
                self.applyTitleAndSplitState(bookmark: bookmark,
                                             primaryTitle: primaryTitle,
                                             secondaryUrl: secondaryUrl,
                                             secondaryTitle: secondaryTitle)
                self.configurePreview(for: bookmark, browserState: self.resolvedBrowserState)
            }
            .store(in: &cancellables)

        bookmark.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] url in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: url)
                self.configurePreview(for: bookmark, browserState: self.resolvedBrowserState)
            }
            .store(in: &cancellables)

        bookmark.$liveFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$cachedFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        // A Split Bookmark's second icon lives in the Profile's favicon
        // database, not on the row. The favicon backfill hands its answer for
        // that page to the repository, which names the page (see
        // `FaviconBackfill`): resolve the second icon again when it is ours.
        ProfileScopedFaviconRepository.shared.iconStored
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] stored in
                guard let self, let bookmark,
                      let secondaryUrl = bookmark.secondaryUrl, !secondaryUrl.isEmpty,
                      stored.profileId == bookmark.profileId,
                      stored.pageURLString == secondaryUrl else { return }
                self.loadSecondaryFavicon(bookmark: bookmark, pageUrl: secondaryUrl)
            }
            .store(in: &cancellables)

        // The row's stored icon changing — a visit, or the backfill writing
        // the first page's — is a cue too: the second may have reached the
        // database meanwhile. The value replayed on subscription is dropped —
        // the bind above loaded it already.
        bookmark.$cachedFaviconData
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark,
                      let secondaryUrl = bookmark.secondaryUrl, !secondaryUrl.isEmpty else { return }
                self.loadSecondaryFavicon(bookmark: bookmark, pageUrl: secondaryUrl)
            }
            .store(in: &cancellables)

        bookmark.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.viewState.isActive = isActive
            }
            .store(in: &cancellables)

        bookmark.$isOpened
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.refreshLiveTabs(for: bookmark)
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updateFolderIcon(bookmark: bookmark)
            }
            .store(in: &cancellables)

        bookmark.$folderIconName
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] iconName in
                self?.viewState.folderIcon = BookmarkFolderIcon.resolve(iconName)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .bookmarkFolderIconPickerRequested,
            object: bookmark
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak bookmark] _ in
            guard let self,
                  let bookmark,
                  bookmark.isFolder,
                  self.configuredBookmark === bookmark else { return }
            self.viewState.folderIconPickerRequestGeneration &+= 1
        }
        .store(in: &cancellables)

        bookmark.$isEditing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] isEditing in
                guard let self, let bookmark else { return }
                self.updateEditingState(isEditing, bookmark: bookmark)
            }
            .store(in: &cancellables)

        if let state = resolvedBrowserState {
            state.$multiSelection
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak bookmark] selection in
                    guard let self, let bookmark else { return }
                    self.viewState.isMultiSelected = selection.containsBookmark(bookmark.guid)
                }
                .store(in: &cancellables)

            state.peekState.$peeksByOpener
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak bookmark] peeksByOpener in
                    guard let self, let bookmark else { return }
                    self.refreshPeekIndicator(for: bookmark,
                                              peeksByOpener: peeksByOpener)
                }
                .store(in: &cancellables)
        }
    }

    /// Shows the trailing peek indicator when a live Peek belongs to this
    /// bookmark's bound tab (also while the peek is hidden behind another
    /// focused tab — the icon is what tells the user a peek is attached).
    private func refreshPeekIndicator(for bookmark: Bookmark, peeksByOpener: [Int: Tab]) {
        let peekTab = liveTabs(for: bookmark).primary.flatMap { peeksByOpener[$0.guid] }
        peekTabViewModel.prepareForReuse()
        if let peekTab {
            configure(viewModel: peekTabViewModel, with: peekTab)
        }
        viewState.showsPeek = peekTab != nil
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard viewState.isDropTargetHighlighted != highlighted else { return }
        viewState.isDropTargetHighlighted = highlighted
    }

    private var resolvedBookmark: Bookmark? {
        if let direct = item as? Bookmark {
            return direct
        }
        if let provider = item as? UnderlyingBookmarkProviding {
            return provider.underlyingBookmark
        }
        return nil
    }

    private func configurePreview(for bookmark: Bookmark, browserState: BrowserState?) {
        guard let browserState else {
            usesSplitTabPreview = false
            tabPreviewRegistration.invalidate()
            splitTabPreviewRegistration.invalidate()
            return
        }

        let anchorRectProvider: CustomTooltipAnchorRectProvider = { view in
            view.bounds.insetBy(dx: WebContentConstant.edgesSpacing, dy: 2)
        }
        if let target = SplitTabPreviewTarget.make(representing: bookmark) {
            usesSplitTabPreview = true
            tabPreviewRegistration.invalidate()
            splitTabPreviewRegistration.configure(
                anchorView: self,
                target: target,
                browserState: browserState,
                placement: .rightTopAttached,
                anchorRectProvider: anchorRectProvider
            )
        } else {
            usesSplitTabPreview = false
            splitTabPreviewRegistration.invalidate()
            tabPreviewRegistration.configure(
                anchorView: self,
                target: .bookmark(bookmark),
                browserState: browserState,
                placement: .rightTopAttached,
                anchorRectProvider: anchorRectProvider
            )
        }
    }

    private var resolvedBrowserState: BrowserState? {
        browserState ?? MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
    }

    private func refreshLiveTabs(for bookmark: Bookmark) {
        let panes = liveTabs(for: bookmark)
        configuredPrimaryTab = panes.primary
        configuredSecondaryTab = panes.secondary
        configure(viewModel: primaryTabViewModel, with: panes.primary)
        configure(viewModel: secondaryTabViewModel, with: panes.secondary)
        viewState.primaryTabIsLive = panes.primary != nil
        viewState.secondaryTabIsLive = panes.secondary != nil
        viewState.isOpened = panes.primary?.hasWebContent == true
            || panes.secondary?.hasWebContent == true
            || bookmark.webContentWrapper != nil
    }

    private func configure(viewModel: TabViewModel, with tab: Tab?) {
        viewModel.prepareForReuse()
        guard let tab else { return }
        let state = MainBrowserWindowControllersManager.shared
            .controller(for: tab.windowId)?.browserState ?? resolvedBrowserState
        viewModel.configure(with: tab, in: state)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
    }

    private func liveTabs(for bookmark: Bookmark) -> (primary: Tab?, secondary: Tab?) {
        guard let state = resolvedBrowserState else { return (nil, nil) }
        if let splitId = state.splitBookmarkBindings[bookmark.guid],
           let group = state.splits.first(where: { $0.id == splitId }) {
            let primary = state.tabs.first(where: { $0.guid == group.primaryTabId })
            let secondary = state.tabs.first(where: { $0.guid == group.secondaryTabId })
            return (primary, secondary)
        }

        guard bookmark.isOpened else { return (nil, nil) }
        if bookmark.chromiumTabGuid != -1,
           let tab = state.tabs.first(where: { $0.guid == bookmark.chromiumTabGuid }) {
            return (tab, nil)
        }
        let tab = state.tabs.first { tab in
            tab.guidInLocalDB == bookmark.guid && state.splitGroup(forTabId: tab.guid) == nil
        }
        return (tab, nil)
    }

    private func updatePrimaryFavicon(bookmark: Bookmark, pageUrl: String?) {
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        viewState.primaryPageURL = pageUrl
        viewState.primaryFaviconRevision &+= 1

        if bookmark.isFolder {
            updateFolderIcon(bookmark: bookmark)
            return
        }

        // Seed the row, then ask Chromium either way: an imported or migrated
        // bookmark arrives without bytes and has no snapshot to fall back on.
        viewState.primaryFaviconImage = storedPrimaryFaviconImage(bookmark: bookmark, pageUrl: pageUrl)

        if let liveFaviconData = bookmark.liveFaviconData,
           let image = NSImage(data: liveFaviconData) {
            viewState.primaryFaviconImage = image
            return
        }

        let request = ProfileScopedFaviconRequest(
            profileId: bookmark.profileId,
            pageURLString: pageUrl,
            snapshotData: bookmark.cachedFaviconData
        )

        faviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak bookmark] result in
            DispatchQueue.main.async {
                self?.viewState.primaryFaviconImage = result.image
                if result.source == .chromium, let data = result.data {
                    bookmark?.updateCachedFaviconData(data)
                }
            }
        }
    }

    private func storedPrimaryFaviconImage(bookmark: Bookmark, pageUrl: String?) -> NSImage {
        if let cachedFaviconData = bookmark.cachedFaviconData,
           let image = NSImage(data: cachedFaviconData) {
            return image
        }

        if let pageUrl,
           let url = URL(string: pageUrl),
           FaviconConfiguration.shouldUseDefaultFavicon(for: url) {
            return .phiDefaultFavicon
        }

        return FaviconConfiguration.default.placeholder ?? NSImage()
    }

    private func updateFolderIcon(bookmark: Bookmark) {
        guard bookmark.isFolder else { return }
        viewState.isFolderExpanded = bookmark.isExpanded
        viewState.folderIcon = BookmarkFolderIcon.resolve(bookmark.folderIconName)
    }

    private func selectFolderIcon(_ icon: BookmarkFolderIcon) {
        guard let bookmark = resolvedBookmark, bookmark.isFolder else { return }
        resolvedBrowserState?.bookmarkManager.updateFolderIcon(guid: bookmark.guid, iconName: icon.rawValue)
    }

    private func applyTitleAndSplitState(bookmark: Bookmark,
                                         primaryTitle: String,
                                         secondaryUrl: String?,
                                         secondaryTitle: String?) {
        guard !bookmark.isFolder,
              let secondaryUrl, !secondaryUrl.isEmpty else {
            viewState.showsSecondaryFavicon = false
            viewState.secondaryPageURL = nil
            viewState.secondaryFaviconImage = nil
            viewState.secondaryFaviconRevision &+= 1
            secondaryFaviconLoadHandle?.cancel()
            secondaryFaviconLoadHandle = nil
            viewState.title = primaryTitle
            viewState.editText = primaryTitle
            updateEditFieldLayout()
            return
        }

        viewState.showsSecondaryFavicon = true
        viewState.secondaryPageURL = secondaryUrl
        viewState.secondaryFaviconRevision &+= 1
        loadSecondaryFavicon(bookmark: bookmark, pageUrl: secondaryUrl)

        let resolvedSecondary = Self.displayName(forSecondaryTitle: secondaryTitle, url: secondaryUrl)
        if resolvedSecondary.isEmpty {
            viewState.title = primaryTitle
        } else {
            viewState.title = "\(primaryTitle) • \(resolvedSecondary)"
        }
        viewState.editText = primaryTitle
        updateEditFieldLayout()
    }

    private func loadSecondaryFavicon(bookmark: Bookmark, pageUrl: String) {
        secondaryFaviconLoadHandle?.cancel()
        let request = ProfileScopedFaviconRequest(
            profileId: bookmark.profileId,
            pageURLString: pageUrl,
            snapshotData: nil
        )
        secondaryFaviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self] result in
            DispatchQueue.main.async {
                self?.viewState.secondaryFaviconImage = result.image
            }
        }
    }

    private static func displayName(forSecondaryTitle title: String?, url: String) -> String {
        if let title, !title.isEmpty { return title }
        guard let parsed = URL(string: url), let host = parsed.host else { return "" }
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }

    private func closeButtonTapped() {
        guard let bookmark = configuredBookmark ?? resolvedBookmark else { return }
        cancelTabPreviewForInteraction()
        resolvedBrowserState?.closeBookmark(bookmark)
    }

    private func navigatePrimaryToOriginalURL(separateCurrentPage: Bool) {
        guard let bookmark = configuredBookmark ?? resolvedBookmark,
              let tab = configuredPrimaryTab,
              let browserState = resolvedBrowserState else {
            return
        }
        selectBookmarkIfNeeded(bookmark, browserState: browserState)
        if separateCurrentPage {
            browserState.separateBookmarkTabFromCurrentURL(tab, bookmark: bookmark)
        } else {
            browserState.navigateBookmarkTabToOriginalURL(tab, bookmark: bookmark)
        }
    }

    private func navigateSecondaryToOriginalURL(separateCurrentPage: Bool) {
        guard let bookmark = configuredBookmark ?? resolvedBookmark,
              let tab = configuredSecondaryTab,
              let browserState = resolvedBrowserState else {
            return
        }
        selectBookmarkIfNeeded(bookmark, browserState: browserState)
        if separateCurrentPage {
            browserState.separateBookmarkTabFromCurrentURL(tab, bookmark: bookmark)
        } else {
            browserState.navigateBookmarkTabToOriginalURL(tab, bookmark: bookmark)
        }
    }

    private func selectBookmarkIfNeeded(_ bookmark: Bookmark, browserState: BrowserState) {
        if browserState.multiSelection.isActive {
            browserState.clearMultiSelection()
        }
        if !bookmark.isActive {
            browserState.openBookmark(bookmark)
        }
    }

    private func updateEditingState(_ isEditing: Bool, bookmark: Bookmark) {
        viewState.isEditing = isEditing
        viewState.editText = bookmark.title
        updateEditFieldLayout()

        if isEditing {
            editField.isHidden = false
            editField.stringValue = bookmark.title
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard bookmark.isEditing else { return }
                // Wait until the field is attached and visible before asking
                // AppKit for first responder; this mirrors the older pure
                // AppKit flow and avoids losing the first activation.
                guard self.window?.makeFirstResponder(self.editField) == true else { return }
                self.editField.selectText(nil)
                self.configureFieldEditor()
                self.isEditingActive = self.editField.currentEditor() != nil
            }
        } else {
            isEditingActive = false
            editField.isHidden = true
        }
    }

    private func commitEditing(newTitle rawTitle: String) {
        guard let bookmark = configuredBookmark ?? resolvedBookmark else { return }
        let newTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingActive = false
        bookmark.isEditing = false

        guard !newTitle.isEmpty else {
            viewState.editText = bookmark.title
            editField.stringValue = bookmark.title
            return
        }

        if newTitle != bookmark.title {
            editDelegate?.bookmarkCellDidEndEditing(bookmark, newTitle: newTitle)
        }
    }

    private func cancelEditing() {
        guard let bookmark = configuredBookmark ?? resolvedBookmark else { return }
        isEditingActive = false
        bookmark.isEditing = false
        viewState.editText = bookmark.title
        editField.stringValue = bookmark.title
    }

    private func configureFieldEditor() {
        guard let editor = editField.currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.focusRingType = .none
    }
}

private enum BookmarkFaviconHoverAction {
    case backToSavedURL
    case separateFromBookmark

    var hintText: String {
        switch self {
        case .backToSavedURL:
            return NSLocalizedString("sidebar.bookmarkCell.favicon.returnToSavedURLHint", value: "Back to Saved URL",
                comment: "Bookmark favicon hover hint - Navigate the open bookmark tab back to its saved URL"
            )
        case .separateFromBookmark:
            return NSLocalizedString("sidebar.bookmarkCell.favicon.detachCurrentPageHint", value: "Separate From Bookmark",
                comment: "Bookmark favicon command-hover hint - Preserve the current page as a normal tab and reset the bookmark"
            )
        }
    }
}

private struct SidebarBookmarkCellContentView: View {
    let state: BookmarkCellViewState
    let primaryTabViewModel: TabViewModel
    let secondaryTabViewModel: TabViewModel
    @ObservedObject var primaryStatusModel: TabStatusModel
    @ObservedObject var secondaryStatusModel: TabStatusModel
    let peekTabViewModel: TabViewModel
    let onClose: () -> Void
    let onClosePeek: () -> Void
    let onNavigatePrimaryToOriginalURL: (Bool) -> Void
    let onNavigateSecondaryToOriginalURL: (Bool) -> Void
    let onSelectFolderIcon: (BookmarkFolderIcon) -> Void

    @State private var primaryFaviconHoverAction: BookmarkFaviconHoverAction?
    @State private var secondaryFaviconHoverAction: BookmarkFaviconHoverAction?

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private var isHighlighted: Bool {
        state.isActive || state.isDropTargetHighlighted || state.isMultiSelected
    }

    private var backgroundColor: Color {
        if state.isActive || state.isDropTargetHighlighted {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        if state.isMultiSelected {
            return ThemedColor.tabSubSelectionBackground.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
        }
        if state.isHovered {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        return .clear
    }

    private var borderColor: Color {
        if showsSelectionBorder && appearance == .dark {
            return .white.opacity(0.2)
        }
        return .clear
    }

    private var showsSelectionBorder: Bool {
        !state.isActive && (state.isDropTargetHighlighted || state.isMultiSelected)
    }

    private var borderStrokeStyle: StrokeStyle {
        return StrokeStyle(
            lineWidth: showsSelectionBorder ? 1 : 0,
            lineCap: .round
        )
    }

    private var showsOpenIndicator: Bool {
        !state.isFolder && TabFaviconPresentation.showsOpenIndicator(
            isOpened: state.isOpened,
            isActive: state.isActive
        )
    }

    private var openIndicatorOpacity: CGFloat {
        TabFaviconPresentation.opacity(
            isDiscarded: primaryStatusModel.isDiscarded || secondaryStatusModel.isDiscarded,
            isUnloaded: primaryStatusModel.isUnloaded || secondaryStatusModel.isUnloaded
        )
    }

    private var textColor: ThemedColor {
        state.isFolder ? .textPrimaryStrong : .textPrimary
    }

    private var showCloseButton: Bool {
        // While a peek is attached, the row's only close affordance is the
        // peek indicator's "minus" — hide the tab close button so hover
        // doesn't show two close controls side by side.
        state.isOpened && state.isHovered && !state.isEditing && !state.showsPeek
    }

    private var faviconHoverAction: BookmarkFaviconHoverAction? {
        primaryFaviconHoverAction ?? secondaryFaviconHoverAction
    }

    private var showBookmarkFaviconHint: Bool {
        faviconHoverAction != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: state.isFolder ? 6 : 8) {
            BookmarkFaviconView(
                image: state.primaryFaviconImage,
                pageURL: state.primaryPageURL,
                revision: state.primaryFaviconRevision,
                isFolder: state.isFolder,
                isFolderExpanded: state.isFolderExpanded,
                folderIcon: state.folderIcon,
                usesStaticFolderSnapshotIcon: state.usesStaticFolderSnapshotIcon,
                folderIconPickerRequestGeneration: state.folderIconPickerRequestGeneration,
                liveTabViewModel: state.primaryTabIsLive ? primaryTabViewModel : nil,
                onNavigateToOriginalURL: onNavigatePrimaryToOriginalURL,
                onReturnHoverChanged: { primaryFaviconHoverAction = $0 },
                onSelectFolderIcon: onSelectFolderIcon
            )
            .overlay(alignment: .leading) {
                if !state.isFolder {
                    // Keep the indicator decorative so selection changes do
                    // not alter the row's measured width.
                    TabOpenIndicatorView()
                        .offset(x: -(
                            TabOpenIndicatorMetrics.diameter
                                + TabOpenIndicatorMetrics.bookmarkSpacing
                        ))
                        .opacity(showsOpenIndicator ? openIndicatorOpacity : 0)
                }
            }

            if !state.isEditing,
               state.primaryTabIsLive,
               primaryTabViewModel.isCurrentlyAudible || primaryTabViewModel.isAudioMuted {
                UnifiedTabMuteButton(viewModel: primaryTabViewModel)
            }

            if state.showsSecondaryFavicon {
                BookmarkFaviconView(
                    image: state.secondaryFaviconImage,
                    pageURL: state.secondaryPageURL,
                    revision: state.secondaryFaviconRevision,
                    isFolder: false,
                    isFolderExpanded: false,
                    folderIcon: .standard,
                    usesStaticFolderSnapshotIcon: false,
                    folderIconPickerRequestGeneration: 0,
                    liveTabViewModel: state.secondaryTabIsLive ? secondaryTabViewModel : nil,
                    onNavigateToOriginalURL: onNavigateSecondaryToOriginalURL,
                    onReturnHoverChanged: { secondaryFaviconHoverAction = $0 },
                    onSelectFolderIcon: { _ in }
                )

                if !state.isEditing,
                   state.secondaryTabIsLive,
                   secondaryTabViewModel.isCurrentlyAudible || secondaryTabViewModel.isAudioMuted {
                    UnifiedTabMuteButton(viewModel: secondaryTabViewModel)
                }
            }

            ZStack(alignment: .leading) {
                UnifiedTabTitleTextView(
                    displayTitle: state.title,
                    isShimmering: false,
                    isPressed: state.isFolder ? false : state.isPressed
                )
                .themedForeground(textColor)
                .fontWeight(state.isFolder ? .medium : .regular)
                .frame(height: 16, alignment: .center)
                .offset(y: showBookmarkFaviconHint ? -7 : 0)

                Text(faviconHoverAction?.hintText ?? "")
                .font(.system(size: 9))
                .lineLimit(1)
                .themedForeground(.textTertiary)
                .offset(y: 8)
                .opacity(showBookmarkFaviconHint ? 1 : 0)
            }
            .opacity(state.isEditing ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .animation(.easeOut(duration: 0.1), value: showBookmarkFaviconHint)

            if state.showsPeek, !state.isEditing {
                SidebarPeekIndicatorView(viewModel: peekTabViewModel,
                                         onClose: onClosePeek)
            }

            if showCloseButton {
                UnifiedTabCloseButton(action: onClose)
            }
        }
        .help(state.showsTabPreview ? "" : state.title)
        .padding(.leading, state.isFolder ? 4 : 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, style: borderStrokeStyle)
        )
        .shadow(color: .black.opacity(isHighlighted ? 0.15 : 0), radius: 1, x: 0, y: 1)
        .overlay(alignment: .topTrailing) {
            if !state.isFolder {
                MergedTabCornerBadgeView(
                    primaryModel: primaryTabViewModel.status,
                    secondaryModel: secondaryTabViewModel.status,
                    isSuppressed: state.showsPeek
                )
                .offset(
                    x: TabCornerBadgeMetrics.overhang,
                    y: -TabCornerBadgeMetrics.overhang
                )
            }
        }
        .padding(.leading, WebContentConstant.edgesSpacing)
        .padding(.trailing, WebContentConstant.edgesSpacing)
        .padding(.vertical, 2)
        .scaleEffect(state.isFolder ? 1.0 : (state.isPressed ? 0.985 : 1.0))
        .animation(.easeOut(duration: 0.08), value: state.isPressed)
    }
}

/// Trailing indicator for a Peek attached to a sidebar row's tab (bookmark
/// or normal): shows the peeked page's favicon, and turns into a "minus"
/// close button on hover (mirrors UnifiedTabCloseButton's styling).
struct SidebarPeekIndicatorView: View {
    let viewModel: TabViewModel
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onClose) {
            ZStack {
                // On hover the favicon stays visible, dimmed, behind the
                // minus glyph — the icon still says which page the peek is.
                UnifiedTabFaviconView(viewModel: viewModel)
                    .opacity(isHovered ? 0.25 : 1)
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isHovered ? 1 : 0)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .themedFill(.hover)
                .opacity(isHovered ? 1 : 0)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .help(NSLocalizedString(
            "peek.bookmarkCell.closePeekTooltip",
            value: "Close Peek",
            comment: "Bookmark sidebar row - Tooltip of the minus button that closes the floating page preview opened from this bookmark"
        ))
        .ignoresSafeArea()
    }
}

private struct BookmarkFaviconView: View {
    let image: NSImage?
    let pageURL: String?
    let revision: Int
    let isFolder: Bool
    let isFolderExpanded: Bool
    let folderIcon: BookmarkFolderIcon
    let usesStaticFolderSnapshotIcon: Bool
    let folderIconPickerRequestGeneration: Int
    let liveTabViewModel: TabViewModel?
    let onNavigateToOriginalURL: (Bool) -> Void
    let onReturnHoverChanged: (BookmarkFaviconHoverAction?) -> Void
    let onSelectFolderIcon: (BookmarkFolderIcon) -> Void

    @State private var isReturnButtonHovered = false
    @State private var isCommandKeyPressed = false
    @State private var modifierFlagsMonitor: Any?
    @State private var showsFolderIconPicker = false

    private static let faviconSlotSize: CGFloat = 16
    private static let faviconSize: CGFloat = 14
    private static let folderSize: CGFloat = 20
    private static let faviconCornerRadius: CGFloat = 3
    private static let returnButtonSize: CGFloat = 24

    private var slotSize: CGFloat {
        isFolder ? Self.folderSize : Self.faviconSlotSize
    }

    private var canNavigateToOriginalURL: Bool {
        guard !isFolder,
              let originalURL = pageURL,
              !originalURL.isEmpty,
              let currentURL = liveTabViewModel?.url,
              !currentURL.isEmpty else {
            return false
        }
        return !URLProcessor.areEquivalentForOriginNavigation(currentURL, originalURL)
    }

    private var hoverAction: BookmarkFaviconHoverAction {
        isCommandKeyPressed ? .separateFromBookmark : .backToSavedURL
    }

    var body: some View {
        Group {
            if isFolder {
                folderIconContent
            } else {
                bookmarkFaviconButton
            }
        }
        .frame(width: slotSize, height: slotSize)
    }

    private var bookmarkFaviconButton: some View {
        Button(action: handleReturnButtonClick) {
            faviconContent
                .frame(width: Self.returnButtonSize, height: Self.returnButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .themedFill(.hover)
                .opacity(canNavigateToOriginalURL && isReturnButtonHovered ? 1 : 0)
        )
        .onHover(perform: updateReturnButtonHover)
        .onChange(of: canNavigateToOriginalURL) { _, canNavigate in
            if !canNavigate {
                updateReturnButtonHover(false)
            }
        }
        .onDisappear {
            stopModifierFlagsMonitor()
            onReturnHoverChanged(nil)
        }
        .allowsHitTesting(canNavigateToOriginalURL)
        .accessibilityHidden(!canNavigateToOriginalURL)
        .accessibilityLabel(
            Text(
                isCommandKeyPressed
                    ? BookmarkFaviconHoverAction.separateFromBookmark.hintText
                    : NSLocalizedString("sidebar.bookmarkCell.favicon.returnToSavedURLAccessibilityLabel", value: "Return to Bookmark URL",
                        comment: "Bookmark favicon button - Navigate the open bookmark tab back to its saved URL"
                    )
            )
        )
    }

    private var folderIconContent: some View {
        BookmarkFolderIconView(
            icon: folderIcon,
            isExpanded: isFolderExpanded,
            usesStaticSnapshotIcon: usesStaticFolderSnapshotIcon
        )
            .frame(width: Self.folderSize, height: Self.folderSize)
            .allowsHitTesting(false)
            .popover(isPresented: $showsFolderIconPicker, arrowEdge: .bottom) {
                BookmarkFolderIconPicker(selected: folderIcon) { selection in
                    onSelectFolderIcon(selection)
                }
            }
            .onChange(of: folderIconPickerRequestGeneration) { oldValue, newValue in
                guard newValue > oldValue else {
                    showsFolderIconPicker = false
                    return
                }
                showFolderIconPicker()
            }
    }

    private func showFolderIconPicker() {
        guard isFolder else { return }
        showsFolderIconPicker = true
    }

    private func updateReturnButtonHover(_ hovering: Bool) {
        let isHovered = canNavigateToOriginalURL && hovering
        guard isReturnButtonHovered != isHovered else { return }
        isReturnButtonHovered = isHovered
        if isHovered {
            isCommandKeyPressed = NSEvent.modifierFlags.contains(.command)
            startModifierFlagsMonitor()
            onReturnHoverChanged(hoverAction)
        } else {
            stopModifierFlagsMonitor()
            isCommandKeyPressed = false
            onReturnHoverChanged(nil)
        }
    }

    private func handleReturnButtonClick() {
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        onNavigateToOriginalURL(modifierFlags.contains(.command))
    }

    private func startModifierFlagsMonitor() {
        guard modifierFlagsMonitor == nil else { return }
        modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let commandKeyPressed = event.modifierFlags.contains(.command)
            if isCommandKeyPressed != commandKeyPressed {
                isCommandKeyPressed = commandKeyPressed
                if isReturnButtonHovered {
                    onReturnHoverChanged(hoverAction)
                }
            }
            return event
        }
    }

    private func stopModifierFlagsMonitor() {
        guard let modifierFlagsMonitor else { return }
        NSEvent.removeMonitor(modifierFlagsMonitor)
        self.modifierFlagsMonitor = nil
    }

    @ViewBuilder
    private var faviconContent: some View {
        if let liveTabViewModel {
            UnifiedTabFaviconView(viewModel: liveTabViewModel)
        } else if let image {
            faviconImage(image)
        } else {
            Image.favicon(for: pageURL, configuration: .init(cornerRadius: Self.faviconCornerRadius))
                .id(revision)
                .frame(width: Self.faviconSize, height: Self.faviconSize)
        }
    }

    @ViewBuilder
    private func faviconImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: Self.faviconSize, height: Self.faviconSize)
            .clipShape(RoundedRectangle(cornerRadius: Self.faviconCornerRadius, style: .continuous))
    }
}

extension BookmarkCellView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditingActive = true
        configureFieldEditor()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        viewState.editText = field.stringValue
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditingActive else { return }
        guard let field = obj.object as? NSTextField else { return }
        if let movement = obj.userInfo?["NSTextMovement"] as? Int,
           movement == NSTextMovement.cancel.rawValue {
            cancelEditing()
            return
        }
        commitEditing(newTitle: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEditing(newTitle: textView.string)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }
}
