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

private struct BookmarkExtraPaneFavicon: Identifiable {
    let id: Int
    let pageURL: String
    var image: NSImage?
    var revision = 0
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
    /// Panes after the second of a split bookmark of three or four panes.
    /// Static icons: only the first two panes show live tab controls.
    var extraPaneFavicons: [BookmarkExtraPaneFavicon] = []
    /// A Peek opened from this bookmark's bound tab is alive (visible or
    /// hidden behind another tab) — drives the trailing peek indicator.
    var showsPeek = false
    var primaryTabIsLive = false
    var secondaryTabIsLive = false
    var isFolder = false
    var isFolderExpanded = false
    var folderIcon = BookmarkFolderIcon.standard
    var usesStaticFolderSnapshotIcon = false
    var isActive = false
    var isOpened = false
    var isHovered = false
    /// A touch revealed the row's hover-only controls (touch has no hover).
    var isTouchRevealed = false
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
    private let folderPreview = BookmarkFolderPreview()
    private var touchPressObserver: TouchPressObserver?
    private let tabPreviewRegistration = TabPreviewRegistration()
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    private let editField = NSTextField()
    private var rowView: SidebarBookmarkRowContentView!
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var secondaryFaviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var extraFaviconLoadHandles: [ProfileScopedFaviconLoadHandle] = []
    private weak var configuredBookmark: Bookmark?
    private weak var configuredPrimaryTab: Tab?
    private weak var configuredSecondaryTab: Tab?
    private var usesSplitTabPreview = false
    private var isEditingActive = false
    private var isPointerHovered = false

    /// Standalone management surfaces must not resolve actions through another Space.
    var usesActiveBrowserStateFallback = true
    var onSelectFolderIcon: ((Bookmark, BookmarkFolderIcon) -> Void)?
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
        folderPreview.invalidate()
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
        rowView.closeFolderIconPicker()
        resetState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { folderPreview.invalidate() }
    }

    func cancelTabPreviewForInteraction() {
        folderPreview.invalidate()
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
        rowView.needsLayout = true
        rowView.layoutSubtreeIfNeeded()
        rowView.displayIfNeeded()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        rowView = SidebarBookmarkRowContentView(
            state: viewState,
            primaryTabViewModel: primaryTabViewModel,
            secondaryTabViewModel: secondaryTabViewModel,
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
        )
        rowView.frame = bounds
        rowView.autoresizingMask = [.width, .height]
        addSubview(rowView)

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

        folderPreview.onPresentationChange = { [weak self] _ in
            self?.updateHoverAppearance()
        }
        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.isPointerHovered = isHovered
            self?.updateHoverAppearance()
            if let self, let bookmark = self.configuredBookmark,
               let browserState = self.browserState, self.usesActiveBrowserStateFallback {
                self.folderPreview.setHovering(isHovered, source: .folder(bookmark), anchor: self,
                                               anchorInsets: Self.rowBackgroundInsets, browserState: browserState)
            }
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

    /// Insets of the row background inside the cell.
    private static let rowBackgroundInsets = NSEdgeInsets(top: 2, left: WebContentConstant.edgesSpacing,
                                                          bottom: 2, right: WebContentConstant.edgesSpacing)

    /// The folder row stays highlighted while its preview is open, even after
    /// the pointer moves into the preview.
    private func updateHoverAppearance() {
        viewState.isHovered = isPointerHovered || folderPreview.isPresented
    }

    private func setupPressAnimation() {
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 5
        press.delaysPrimaryMouseButtonEvents = false
        // macOS 27 defaults to direct touches; a zero-duration press would claim
        // touch-down ahead of the row's click emulation and sidebar scrolling.
        press.allowedTouchTypes = []
        addGestureRecognizer(press)
        touchPressObserver = TouchPressObserver(view: self) { [weak self] pressed in
            if pressed {
                self?.folderPreview.invalidate()
            }
            self?.viewState.isPressed = pressed
        }
    }

    override func setTouchRevealed(_ revealed: Bool) {
        viewState.isTouchRevealed = revealed
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            folderPreview.invalidate()
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
        viewState.extraPaneFavicons = []
        extraFaviconLoadHandles.forEach { $0.cancel() }
        extraFaviconLoadHandles = []
        viewState.showsPeek = false
        viewState.primaryTabIsLive = false
        viewState.secondaryTabIsLive = false
        viewState.isFolder = false
        viewState.isFolderExpanded = false
        viewState.folderIcon = .standard
        viewState.usesStaticFolderSnapshotIcon = false
        viewState.isActive = false
        viewState.isOpened = false
        isPointerHovered = false
        viewState.isHovered = false
        viewState.isTouchRevealed = false
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
        // Match the row chrome:
        // `edgesSpacing` is the outer row inset. Folder icons use a 20-point
        // slot with 4 points of leading padding, while regular bookmark
        // favicons keep their original 16-point slot with 6 points of leading
        // padding, so both icon centers stay aligned. Folders use a 6-point
        // title gap; regular bookmarks retain their original 8-point gap.
        let leadingPadding: CGFloat = viewState.isFolder ? 4 : 6
        let primaryFaviconSlotSize: CGFloat = viewState.isFolder ? 20 : 16
        let titleGap: CGFloat = viewState.isFolder ? 6 : 8
        let secondaryFaviconOffset: CGFloat = viewState.showsSecondaryFavicon
            ? 24 * CGFloat(1 + viewState.extraPaneFavicons.count)
            : 0
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
        folderPreview.invalidate()
        if configuredBookmark !== bookmark {
            rowView.showFolderStateWithoutAnimation()
        }
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

        // The initial state was applied above. Skip publisher replays before
        // scheduling on main so reuse does not queue duplicate image/layout work.
        Publishers.CombineLatest3(bookmark.$title,
                                  bookmark.$secondaryUrl,
                                  bookmark.$secondaryTitle)
            .dropFirst()
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
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] url in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: url)
                self.configurePreview(for: bookmark, browserState: self.resolvedBrowserState)
            }
            .store(in: &cancellables)

        bookmark.$liveFaviconData
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$cachedFaviconData
            .removeDuplicates()
            .dropFirst()
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
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.refreshLiveTabs(for: bookmark)
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        // Applied synchronously: the outline posts its expand/collapse
        // notification before it builds the child rows, so the folder icon
        // starts in the same frame as the rows instead of a main-queue hop later.
        // `@Published` emits before the property is stored, so use the value.
        bookmark.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isExpanded in
                self?.viewState.isFolderExpanded = isExpanded
                if isExpanded { self?.folderPreview.invalidate() }
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
            self.rowView.showFolderIconPicker()
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

    /// Management outlines own selection independently from the window's tab selection.
    func setManagementSelected(_ selected: Bool) {
        viewState.isMultiSelected = selected
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
        browserState ?? (usesActiveBrowserStateFallback ? SpaceSessionControllersManager.shared.activeWindowController?.browserState : nil)
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
        let state = SpaceSessionControllersManager.shared
            .controller(for: tab.windowId)?.browserState ?? resolvedBrowserState
        viewModel.configure(with: tab, in: state)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.toggleAudioMuted()
        }
    }

    private func liveTabs(for bookmark: Bookmark) -> (primary: Tab?, secondary: Tab?) {
        guard let state = resolvedBrowserState else { return (nil, nil) }
        if let splitId = state.splitBookmarkBindings[bookmark.guid],
           let group = state.splits.first(where: { $0.id == splitId }) {
            let primary = state.tabs.first(where: { $0.guid == group.tabIds[0] })
            let secondary = state.tabs.first(where: { $0.guid == group.tabIds[1] })
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
            // The repository delivers on main and checks cancellation before
            // asynchronous results. Do not enqueue another write past cell reuse.
            self?.viewState.primaryFaviconImage = result.image
            if result.source == .chromium, let data = result.data {
                bookmark?.updateCachedFaviconData(data)
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
        if let onSelectFolderIcon { onSelectFolderIcon(bookmark, icon) }
        else { resolvedBrowserState?.bookmarkManager.updateFolderIcon(guid: bookmark.guid, iconName: icon.rawValue) }
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
            viewState.extraPaneFavicons = []
            extraFaviconLoadHandles.forEach { $0.cancel() }
            extraFaviconLoadHandles = []
            viewState.title = primaryTitle
            viewState.editText = primaryTitle
            updateEditFieldLayout()
            return
        }

        viewState.showsSecondaryFavicon = true
        viewState.secondaryPageURL = secondaryUrl
        viewState.secondaryFaviconRevision &+= 1
        loadSecondaryFavicon(bookmark: bookmark, pageUrl: secondaryUrl)
        loadExtraPaneFavicons(bookmark: bookmark)

        let resolvedSecondary = Self.displayName(forSecondaryTitle: secondaryTitle, url: secondaryUrl)
        let extraNames = bookmark.splitExtraPanes
            .map { Self.displayName(forSecondaryTitle: $0.title, url: $0.url) }
            .filter { !$0.isEmpty }
        if resolvedSecondary.isEmpty && extraNames.isEmpty {
            viewState.title = primaryTitle
        } else {
            viewState.title = ([primaryTitle, resolvedSecondary] + extraNames)
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
        }
        viewState.editText = primaryTitle
        updateEditFieldLayout()
    }

    private func loadExtraPaneFavicons(bookmark: Bookmark) {
        extraFaviconLoadHandles.forEach { $0.cancel() }
        viewState.extraPaneFavicons = bookmark.splitExtraPanes.enumerated().map { index, pane in
            BookmarkExtraPaneFavicon(id: index, pageURL: pane.url)
        }
        extraFaviconLoadHandles = bookmark.splitExtraPanes.enumerated().compactMap { index, pane in
            let request = ProfileScopedFaviconRequest(
                profileId: bookmark.profileId,
                pageURLString: pane.url,
                snapshotData: nil
            )
            return ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self] result in
                guard let self, index < self.viewState.extraPaneFavicons.count else { return }
                self.viewState.extraPaneFavicons[index].image = result.image
                self.viewState.extraPaneFavicons[index].revision &+= 1
            }
        }
    }

    private func loadSecondaryFavicon(bookmark: Bookmark, pageUrl: String) {
        secondaryFaviconLoadHandle?.cancel()
        let request = ProfileScopedFaviconRequest(
            profileId: bookmark.profileId,
            pageURLString: pageUrl,
            snapshotData: nil
        )
        secondaryFaviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self] result in
            self?.viewState.secondaryFaviconImage = result.image
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

/// The sidebar bookmark row, in AppKit for the same reason as `SideTabView`.
/// `layout()` reads the cell's state and the live tabs' view models inside
/// `withObservationTracking`, and a change to anything it read asks for the
/// next layout.
final class SidebarBookmarkRowContentView: NSView {
    private static let cornerRadius: CGFloat = 8
    private static let buttonSize: CGFloat = 24
    private static let faviconSlotSize: CGFloat = 16
    private static let folderIconSize: CGFloat = 20
    private static let trailingInset: CGFloat = 8
    private static let titleAreaHeight: CGFloat = 30
    /// How far the title rises, and the hint sits below center, while the
    /// favicon's hover hint shows.
    private static let titleHintLift: CGFloat = 7
    private static let hintDrop: CGFloat = 8
    private static let separatorInset: CGFloat = 6
    /// The row already leaves 9 points after the favicon image (8-point
    /// spacing plus the slot's 1-point inset); shift back by half to center.
    private static let separatorOffset: CGFloat = -4.5

    private let state: BookmarkCellViewState
    private let primaryTabViewModel: TabViewModel
    private let secondaryTabViewModel: TabViewModel
    private let peekTabViewModel: TabViewModel
    private let onClose: () -> Void
    private let onClosePeek: () -> Void
    private let onSelectFolderIcon: (BookmarkFolderIcon) -> Void

    /// Scaled as a whole while the row is pressed.
    private let contentView = SideTabContainerView()
    private let backgroundView = SideTabPassthroughView()
    private let openIndicatorView = SideTabPassthroughView()
    private let folderIconView = BookmarkFolderIconView()
    private let primaryFaviconButton = BookmarkFaviconButton()
    private let primaryMuteButton = SideTabIconButton()
    private let secondaryFaviconButton = BookmarkFaviconButton()
    private let secondaryMuteButton = SideTabIconButton()
    private var extraFaviconViews: [SideTabFaviconView] = []
    private let titleAreaView = BookmarkTitleAreaView()
    private let titleView = SideTabTitleView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let separatorView = NavigatedAwaySeparatorView()
    private let peekButton = SideTabPeekButton()
    private let closeButton = SideTabIconButton()
    private let badgeView = SideTabCornerBadgeView()

    private var theme: Theme?
    private var phiAppearance: Appearance = .light
    private var dimmingEnabled = PhiPreferences.GeneralSettings.showUnloadedTabIndicators.loadValue()
    private var showsOpenIndicators = PhiPreferences.GeneralSettings.showOpenTabIndicators.loadValue()
    private var cancellables = Set<AnyCancellable>()
    private var pressedScale = SideTabPressedScale()
    private var primaryHoverAction: BookmarkFaviconHoverAction?
    private var secondaryHoverAction: BookmarkFaviconHoverAction?
    private var isHintShown = false
    private var folderIconPopover: NSPopover?
    private var folderIconPicker: NSHostingController<BookmarkFolderIconPicker>?
    private var pickerSelection: BookmarkFolderIcon?

    private lazy var highlightShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    fileprivate init(state: BookmarkCellViewState,
         primaryTabViewModel: TabViewModel,
         secondaryTabViewModel: TabViewModel,
         peekTabViewModel: TabViewModel,
         onClose: @escaping () -> Void,
         onClosePeek: @escaping () -> Void,
         onNavigatePrimaryToOriginalURL: @escaping (Bool) -> Void,
         onNavigateSecondaryToOriginalURL: @escaping (Bool) -> Void,
         onSelectFolderIcon: @escaping (BookmarkFolderIcon) -> Void) {
        self.state = state
        self.primaryTabViewModel = primaryTabViewModel
        self.secondaryTabViewModel = secondaryTabViewModel
        self.peekTabViewModel = peekTabViewModel
        self.onClose = onClose
        self.onClosePeek = onClosePeek
        self.onSelectFolderIcon = onSelectFolderIcon
        super.init(frame: .zero)
        primaryFaviconButton.onNavigate = onNavigatePrimaryToOriginalURL
        secondaryFaviconButton.onNavigate = onNavigateSecondaryToOriginalURL
        setupViews()
        setupSubscriptions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// The folder icon shows the next state without a stroke, for a row
    /// that now shows another bookmark.
    func showFolderStateWithoutAnimation() {
        folderIconView.showNextStateWithoutAnimation()
    }

    func showFolderIconPicker() {
        guard state.isFolder, window != nil else { return }
        let popover = folderIconPopover ?? makeFolderIconPopover()
        updateFolderIconPicker()
        popover.show(relativeTo: folderIconView.bounds, of: folderIconView, preferredEdge: .minY)
    }

    func closeFolderIconPicker() {
        folderIconPopover?.close()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        addSubview(contentView)

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = Self.cornerRadius
        backgroundView.layer?.cornerCurve = .continuous
        contentView.addSubview(backgroundView)

        openIndicatorView.wantsLayer = true
        openIndicatorView.layer?.cornerRadius = TabOpenIndicatorMetrics.diameter / 2
        contentView.addSubview(openIndicatorView)

        contentView.addSubview(folderIconView)

        titleAreaView.wantsLayer = true
        titleAreaView.layer?.masksToBounds = false
        titleAreaView.addSubview(titleView)
        hintLabel.font = NSFont.systemFont(ofSize: 9)
        hintLabel.lineBreakMode = .byClipping
        hintLabel.maximumNumberOfLines = 1
        hintLabel.phi.setTextColor(.textTertiary)
        hintLabel.alphaValue = 0
        titleAreaView.addSubview(hintLabel)
        titleAreaView.addSubview(separatorView)
        contentView.addSubview(titleAreaView)

        primaryFaviconButton.onHoverActionChanged = { [weak self] action in
            self?.primaryHoverAction = action
            self?.needsLayout = true
        }
        secondaryFaviconButton.onHoverActionChanged = { [weak self] action in
            self?.secondaryHoverAction = action
            self?.needsLayout = true
        }
        primaryMuteButton.onClick = { [weak self] in self?.primaryTabViewModel.onToggleMute?() }
        secondaryMuteButton.onClick = { [weak self] in self?.secondaryTabViewModel.onToggleMute?() }
        for view in [primaryFaviconButton, primaryMuteButton, secondaryFaviconButton, secondaryMuteButton] {
            contentView.addSubview(view)
        }

        peekButton.onClick = { [weak self] in self?.onClosePeek() }
        peekButton.toolTip = NSLocalizedString(
            "peek.bookmarkCell.closePeekTooltip",
            value: "Close Peek",
            comment: "Bookmark sidebar row - Tooltip of the minus button that closes the floating page preview opened from this bookmark"
        )
        contentView.addSubview(peekButton)

        closeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.onClick = { [weak self] in self?.onClose() }
        contentView.addSubview(closeButton)

        contentView.addSubview(badgeView)
    }

    private func setupSubscriptions() {
        _ = phi.subscribe { [weak self] theme, appearance in
            self?.theme = theme
            self?.phiAppearance = appearance
            self?.needsLayout = true
        }
        // The status models are `ObservableObject`s, outside Observation.
        for status in [primaryTabViewModel.status, secondaryTabViewModel.status, peekTabViewModel.status] {
            status.objectWillChange
                .sink { [weak self] _ in self?.needsLayout = true }
                .store(in: &cancellables)
        }
        TabFaviconPresentation.dimmingEnabledPublisher
            .dropFirst()
            .sink { [weak self] enabled in
                self?.dimmingEnabled = enabled
                self?.needsLayout = true
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in PhiPreferences.GeneralSettings.showOpenTabIndicators.loadValue() }
            .removeDuplicates()
            .sink { [weak self] shows in
                guard let self, self.showsOpenIndicators != shows else { return }
                self.showsOpenIndicators = shows
                self.needsLayout = true
            }
            .store(in: &cancellables)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.needsLayout = true
            }
        }
    }

    // MARK: Rendering

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let titleRect = renderRow()
        CATransaction.commit()
        renderTitleArea(in: titleRect)
    }

    /// Lays out and renders everything but the title area, and returns the
    /// title area's frame.
    private func renderRow() -> NSRect {
        let bounds = self.bounds
        let isFolder = state.isFolder
        let isEditing = state.isEditing
        contentView.frame = bounds
        pressedScale.apply(!isFolder && state.isPressed, to: contentView.layer, in: bounds)

        let inset = WebContentConstant.edgesSpacing
        let rowRect = NSRect(
            x: inset,
            y: 2,
            width: max(0, bounds.width - inset * 2),
            height: max(0, bounds.height - 4)
        )
        renderBackground(in: rowRect)

        let hoverFill = theme.map { ThemedColor.hover.resolve(theme: $0, appearance: phiAppearance) } ?? .clear
        let spacing: CGFloat = isFolder ? 6 : 8
        let midY = rowRect.midY

        let slotSize = isFolder ? Self.folderIconSize : Self.faviconSlotSize
        let slotRect = NSRect(
            x: rowRect.minX + (isFolder ? 4 : 6),
            y: midY - slotSize / 2,
            width: slotSize,
            height: slotSize
        )
        folderIconView.isHidden = !isFolder
        primaryFaviconButton.isHidden = isFolder
        if isFolder {
            folderIconView.frame = slotRect
            folderIconView.render(
                icon: state.folderIcon,
                isExpanded: state.isFolderExpanded,
                usesStaticSnapshotIcon: state.usesStaticFolderSnapshotIcon,
                theme: theme,
                appearance: phiAppearance
            )
            if folderIconPopover?.isShown == true {
                updateFolderIconPicker()
            }
        } else {
            renderFavicon(primaryFaviconButton, in: slotRect,
                          image: state.primaryFaviconImage,
                          pageURL: state.primaryPageURL,
                          revision: state.primaryFaviconRevision,
                          liveModel: state.primaryTabIsLive ? primaryTabViewModel : nil,
                          hoverFill: hoverFill)
        }
        renderOpenIndicator(besides: slotRect)
        var x = slotRect.maxX + spacing

        x = layoutMuteButton(primaryMuteButton, model: primaryTabViewModel,
                             isLive: state.primaryTabIsLive, x: x, midY: midY, spacing: spacing)

        let showsSecondary = state.showsSecondaryFavicon
        secondaryFaviconButton.isHidden = !showsSecondary
        if showsSecondary {
            let rect = faviconSlot(x: x, midY: midY)
            renderFavicon(secondaryFaviconButton, in: rect,
                          image: state.secondaryFaviconImage,
                          pageURL: state.secondaryPageURL,
                          revision: state.secondaryFaviconRevision,
                          liveModel: state.secondaryTabIsLive ? secondaryTabViewModel : nil,
                          hoverFill: hoverFill)
            x = rect.maxX + spacing
            x = layoutMuteButton(secondaryMuteButton, model: secondaryTabViewModel,
                                 isLive: state.secondaryTabIsLive, x: x, midY: midY, spacing: spacing)
        } else {
            secondaryMuteButton.isHidden = true
        }
        x = layoutExtraFavicons(showsSecondary ? state.extraPaneFavicons : [], x: x, midY: midY, spacing: spacing)

        var titleMaxX = rowRect.maxX - Self.trailingInset
        // While a peek is attached, the row's only close affordance is the
        // peek indicator's minus, so hover doesn't show two close controls.
        let showsClose = state.isOpened && (state.isHovered || state.isTouchRevealed)
            && !isEditing && !state.showsPeek
        closeButton.isHidden = !showsClose
        if showsClose {
            closeButton.frame = buttonFrame(x: titleMaxX - Self.buttonSize, midY: midY)
            titleMaxX -= Self.buttonSize + spacing
        }
        let showsPeek = state.showsPeek && !isEditing
        peekButton.isHidden = !showsPeek
        if showsPeek {
            peekButton.frame = buttonFrame(x: titleMaxX - Self.buttonSize, midY: midY)
            peekButton.render(model: peekTabViewModel, isTouchRevealed: state.isTouchRevealed,
                              dimmingEnabled: dimmingEnabled, theme: theme, appearance: phiAppearance)
            titleMaxX -= Self.buttonSize + spacing
        }
        for button in [primaryMuteButton, secondaryMuteButton, peekButton, closeButton] as [SideTabIconButton] {
            button.hoverFillColor = hoverFill
        }

        badgeView.isHidden = isFolder
        if !isFolder {
            let badgeSize = TabCornerBadgeMetrics.visualSize
            badgeView.frame = NSRect(
                x: rowRect.maxX - badgeSize + TabCornerBadgeMetrics.overhang,
                y: rowRect.minY - TabCornerBadgeMetrics.overhang,
                width: badgeSize,
                height: badgeSize
            )
            let status = state.showsPeek ? nil : TabCornerBadgeStatus.highestPriority([
                primaryTabViewModel.status.cornerBadgeStatus,
                secondaryTabViewModel.status.cornerBadgeStatus
            ])
            badgeView.render(status: status, theme: theme, appearance: phiAppearance)
        }

        let toolTip = state.showsTabPreview ? nil : state.title
        if self.toolTip != toolTip {
            self.toolTip = toolTip
        }

        return NSRect(
            x: x,
            y: midY - Self.titleAreaHeight / 2,
            width: max(0, titleMaxX - x),
            height: Self.titleAreaHeight
        )
    }

    private func renderBackground(in rect: NSRect) {
        backgroundView.frame = rect
        let isActive = state.isActive
        let isDropTarget = state.isDropTargetHighlighted
        let isMultiSelected = state.isMultiSelected
        let fill: NSColor
        if isActive || isDropTarget {
            fill = NSColor(resource: .sidebarTabSelected)
        } else if isMultiSelected, let theme {
            fill = ThemedColor.tabSubSelectionBackground.resolve(theme: theme, appearance: phiAppearance)
        } else if state.isHovered {
            fill = NSColor(resource: .sidebarTabHovered)
        } else {
            fill = .clear
        }
        guard let layer = backgroundView.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill.cgColor
        }
        let showsBorder = !isActive && (isDropTarget || isMultiSelected) && phiAppearance == .dark
        layer.borderWidth = showsBorder ? 1 : 0
        layer.borderColor = showsBorder ? NSColor.white.withAlphaComponent(0.2).cgColor : nil
        let shadow = isActive || isDropTarget || isMultiSelected ? highlightShadow : nil
        if backgroundView.shadow !== shadow {
            backgroundView.shadow = shadow
        }
    }

    private func renderFavicon(_ button: BookmarkFaviconButton,
                               in slotRect: NSRect,
                               image: NSImage?,
                               pageURL: String?,
                               revision: Int,
                               liveModel: TabViewModel?,
                               hoverFill: NSColor) {
        let outset = (Self.buttonSize - slotRect.width) / 2
        button.frame = slotRect.insetBy(dx: -outset, dy: -outset)
        button.render(image: image, pageURL: pageURL, revision: revision, liveModel: liveModel,
                      dimmingEnabled: dimmingEnabled, theme: theme, appearance: phiAppearance)
        button.hoverFillColor = button.canNavigate ? hoverFill : .clear
    }

    /// The dot beside an open bookmark that isn't the active one.
    private func renderOpenIndicator(besides slotRect: NSRect) {
        openIndicatorView.isHidden = state.isFolder
        guard !state.isFolder else { return }
        let diameter = TabOpenIndicatorMetrics.diameter
        openIndicatorView.frame = NSRect(
            x: slotRect.minX - diameter - TabOpenIndicatorMetrics.bookmarkSpacing,
            y: slotRect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let primary = primaryTabViewModel.status
        let secondary = secondaryTabViewModel.status
        let showsIndicator = showsOpenIndicators
            && TabFaviconPresentation.showsOpenIndicator(isOpened: state.isOpened, isActive: state.isActive)
        openIndicatorView.alphaValue = showsIndicator
            ? TabFaviconPresentation.opacity(
                isDiscarded: primary.isDiscarded || secondary.isDiscarded,
                isUnloaded: primary.isUnloaded || secondary.isUnloaded,
                dimmingEnabled: dimmingEnabled
            )
            : 0
        openIndicatorView.layer?.backgroundColor = (phiAppearance.isLight ? NSColor.black : NSColor.white).cgColor
    }

    private func layoutMuteButton(_ button: SideTabIconButton,
                                  model: TabViewModel,
                                  isLive: Bool,
                                  x: CGFloat,
                                  midY: CGFloat,
                                  spacing: CGFloat) -> CGFloat {
        let showsButton = !state.isEditing && isLive && (model.isCurrentlyAudible || model.isMuted)
        button.isHidden = !showsButton
        guard showsButton else { return x }
        button.image = NSImage(resource: model.isMuted ? .speakerMute : .speakerWave)
        button.frame = buttonFrame(x: x, midY: midY)
        return x + Self.buttonSize + spacing
    }

    /// Panes after the second of a split bookmark of three or four panes.
    private func layoutExtraFavicons(_ panes: [BookmarkExtraPaneFavicon],
                                     x: CGFloat,
                                     midY: CGFloat,
                                     spacing: CGFloat) -> CGFloat {
        while extraFaviconViews.count < panes.count {
            let view = SideTabFaviconView()
            contentView.addSubview(view, positioned: .below, relativeTo: titleAreaView)
            extraFaviconViews.append(view)
        }
        var x = x
        for (index, view) in extraFaviconViews.enumerated() {
            guard index < panes.count else {
                view.isHidden = true
                continue
            }
            let pane = panes[index]
            let rect = faviconSlot(x: x, midY: midY)
            view.isHidden = false
            view.frame = rect
            view.render(image: pane.image, pageURL: pane.pageURL, revision: pane.revision)
            x = rect.maxX + spacing
        }
        return x
    }

    private func renderTitleArea(in rect: NSRect) {
        let showsSeparator = !state.isFolder
            && !state.showsSecondaryFavicon
            && !state.isEditing
            && state.primaryTabIsLive
            && BookmarkFaviconButton.hasNavigatedAway(originalURL: state.primaryPageURL,
                                                      currentURL: primaryTabViewModel.url)
        let leading = showsSeparator ? Self.separatorInset : 0
        let hintAction = primaryHoverAction ?? secondaryHoverAction
        let showsHint = hintAction != nil
        let midY = rect.height / 2
        let titleHeight = SideTabTitleView.titleHeight
        let titleFrame = NSRect(
            x: leading,
            y: midY - titleHeight / 2 - (showsHint ? Self.titleHintLift : 0),
            width: max(0, rect.width - leading),
            height: titleHeight
        )
        if let hintAction {
            hintLabel.stringValue = hintAction.hintText
        }
        let hintHeight = ceil(hintLabel.intrinsicContentSize.height)
        let hintFrame = NSRect(
            x: leading,
            y: midY + Self.hintDrop - hintHeight / 2,
            width: max(0, rect.width - leading),
            height: hintHeight
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleAreaView.frame = rect
        titleAreaView.alphaValue = state.isEditing ? 0 : 1
        separatorView.isHidden = !showsSeparator
        separatorView.frame = NSRect(x: Self.separatorOffset, y: 0,
                                     width: Self.separatorInset, height: rect.height)
        separatorView.color = theme.map { ThemedColor.textTertiary.resolve(theme: $0, appearance: phiAppearance) }
            ?? .tertiaryLabelColor
        titleView.setEmphasized(state.isFolder)
        if titleView.frame.size != titleFrame.size {
            titleView.frame = titleFrame
        }
        titleView.render(title: state.title, isShimmering: false)
        CATransaction.commit()

        let applyMotion = {
            self.titleView.frame = titleFrame
            self.hintLabel.frame = hintFrame
            self.hintLabel.alphaValue = showsHint ? 1 : 0
            self.separatorView.alphaValue = self.primaryHoverAction == nil ? 1 : 0
        }
        if showsHint != isHintShown {
            isHintShown = showsHint
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                applyMotion()
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyMotion()
            CATransaction.commit()
        }
    }

    private func faviconSlot(x: CGFloat, midY: CGFloat) -> NSRect {
        NSRect(x: x, y: midY - Self.faviconSlotSize / 2,
               width: Self.faviconSlotSize, height: Self.faviconSlotSize)
    }

    private func buttonFrame(x: CGFloat, midY: CGFloat) -> NSRect {
        NSRect(x: x, y: midY - Self.buttonSize / 2, width: Self.buttonSize, height: Self.buttonSize)
    }

    // MARK: Folder icon picker

    private func makeFolderIconPopover() -> NSPopover {
        let picker = NSHostingController(rootView: makeFolderIconPickerContent())
        picker.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        folderIconPicker = picker
        folderIconPopover = popover
        return popover
    }

    private func updateFolderIconPicker() {
        guard pickerSelection != state.folderIcon else { return }
        folderIconPicker?.rootView = makeFolderIconPickerContent()
    }

    private func makeFolderIconPickerContent() -> BookmarkFolderIconPicker {
        pickerSelection = state.folderIcon
        return BookmarkFolderIconPicker(selected: state.folderIcon) { [weak self] icon in
            self?.onSelectFolderIcon(icon)
        }
    }
}

/// A bookmark pane's favicon. While the pane's live tab has navigated away
/// from the saved URL it becomes a button that goes back, or with Command
/// separates the current page from the bookmark.
private final class BookmarkFaviconButton: SideTabIconButton {
    private static let faviconSlotSize: CGFloat = 16

    private let faviconView = SideTabFaviconView()
    private(set) var canNavigate = false
    private var isCommandKeyPressed = false
    private var modifierFlagsMonitor: Any?
    private var hoverAction: BookmarkFaviconHoverAction?

    var onHoverActionChanged: ((BookmarkFaviconHoverAction?) -> Void)?
    var onNavigate: ((Bool) -> Void)?

    override init() {
        super.init()
        addSubview(faviconView)
        onClick = { [weak self] in
            let modifierFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            self?.onNavigate?(modifierFlags.contains(.command))
        }
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func hasNavigatedAway(originalURL: String?, currentURL: String?) -> Bool {
        guard let originalURL, !originalURL.isEmpty,
              let currentURL, !currentURL.isEmpty else {
            return false
        }
        return !URLProcessor.areEquivalentForOriginNavigation(currentURL, originalURL)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        canNavigate ? super.hitTest(point) : nil
    }

    /// - Parameter liveModel: The pane's live tab, or nil to show the saved
    ///   page's icon.
    func render(image: NSImage?,
                pageURL: String?,
                revision: Int,
                liveModel: TabViewModel?,
                dimmingEnabled: Bool,
                theme: Theme?,
                appearance: Appearance) {
        let size = Self.faviconSlotSize
        faviconView.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2,
                                   width: size, height: size)
        if let liveModel {
            faviconView.render(model: liveModel, dimmingEnabled: dimmingEnabled,
                               theme: theme, appearance: appearance)
        } else {
            faviconView.render(image: image, pageURL: pageURL, revision: revision)
        }
        let canNavigate = liveModel.map { Self.hasNavigatedAway(originalURL: pageURL, currentURL: $0.url) } ?? false
        if canNavigate != self.canNavigate {
            self.canNavigate = canNavigate
            updateHoverAction()
            updateAccessibility()
        }
    }

    override func pointerInsideChanged() {
        super.pointerInsideChanged()
        updateHoverAction()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHoverAction()
    }

    private func updateHoverAction() {
        let isHovered = isPointerInside && canNavigate && window != nil
        if isHovered {
            startModifierFlagsMonitor()
        } else {
            stopModifierFlagsMonitor()
            isCommandKeyPressed = false
        }
        let action: BookmarkFaviconHoverAction? = isHovered
            ? (isCommandKeyPressed ? .separateFromBookmark : .backToSavedURL)
            : nil
        guard action != hoverAction else { return }
        hoverAction = action
        updateAccessibility()
        onHoverActionChanged?(action)
    }

    private func startModifierFlagsMonitor() {
        guard modifierFlagsMonitor == nil else { return }
        isCommandKeyPressed = NSEvent.modifierFlags.contains(.command)
        modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let isPressed = event.modifierFlags.contains(.command)
            if self.isCommandKeyPressed != isPressed {
                self.isCommandKeyPressed = isPressed
                self.updateHoverAction()
            }
            return event
        }
    }

    private func stopModifierFlagsMonitor() {
        guard let modifierFlagsMonitor else { return }
        NSEvent.removeMonitor(modifierFlagsMonitor)
        self.modifierFlagsMonitor = nil
    }

    private func updateAccessibility() {
        setAccessibilityElement(canNavigate)
        setAccessibilityLabel(
            isCommandKeyPressed
                ? BookmarkFaviconHoverAction.separateFromBookmark.hintText
                : NSLocalizedString("sidebar.bookmarkCell.favicon.returnToSavedURLAccessibilityLabel", value: "Return to Bookmark URL",
                    comment: "Bookmark favicon button - Navigate the open bookmark tab back to its saved URL"
                )
        )
    }
}

/// Marks an open bookmark whose tab has navigated away from the saved URL.
/// Top-down, so the title rises and the favicon's hover hint sits below it.
private final class BookmarkTitleAreaView: SideTabPassthroughView {
    override var isFlipped: Bool { true }
}

private final class NavigatedAwaySeparatorView: SideTabPassthroughView {
    var color: NSColor = .clear {
        didSet {
            if color != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: NSRect(x: -1, y: -7, width: 2, height: 14), xRadius: 1, yRadius: 1)
        var transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        transform.rotate(byDegrees: 15)
        path.transform(using: transform)
        color.setFill()
        path.fill()
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
