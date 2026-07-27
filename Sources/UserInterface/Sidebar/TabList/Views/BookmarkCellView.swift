// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI
import SVGView

/// A lightweight protocol to allow the sidebar to show "virtual" bookmark items
/// while still rendering and operating on the underlying real `Bookmark`.
protocol UnderlyingBookmarkProviding {
    var underlyingBookmark: Bookmark { get }
}

/// Delegate for bookmark title edits.
protocol BookmarkCellViewDelegate: AnyObject {
    func bookmarkCellDidEndEditing(_ bookmark: Bookmark, newTitle: String)
}

private final class BookmarkCellViewState: ObservableObject {
    @Published var title = ""
    @Published var editText = ""
    @Published var primaryPageURL: String?
    @Published var secondaryPageURL: String?
    @Published var primaryFaviconImage: NSImage?
    @Published var secondaryFaviconImage: NSImage?
    @Published var primaryFaviconRevision = 0
    @Published var secondaryFaviconRevision = 0
    @Published var showsSecondaryFavicon = false
    @Published var primaryTabIsLive = false
    @Published var secondaryTabIsLive = false
    @Published var isFolder = false
    @Published var isFolderExpanded = false
    @Published var isActive = false
    @Published var isOpened = false
    @Published var isHovered = false
    @Published var isPressed = false
    @Published var isEditing = false
    @Published var isMultiSelected = false
    @Published var isDropTargetHighlighted = false
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

class BookmarkCellView: SidebarCellView {
    /// Identifier stamped on every sidebar bookmark row's content view.
    static let accessibilityIdentifier = "sidebarBookmark"

    private let viewState = BookmarkCellViewState()
    private let primaryTabViewModel = TabViewModel()
    private let secondaryTabViewModel = TabViewModel()
    private let hoverRegionView = SidebarTabHoverRegionView()
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
        resetState()
    }

    private func setupViews() {
        hostingView = ThemedHostingView(rootView: SidebarBookmarkCellContentView(
            state: viewState,
            primaryTabViewModel: primaryTabViewModel,
            secondaryTabViewModel: secondaryTabViewModel,
            onClose: { [weak self] in
                self?.closeButtonTapped()
            },
            onNavigatePrimaryToOriginalURL: { [weak self] separateCurrentPage in
                self?.navigatePrimaryToOriginalURL(separateCurrentPage: separateCurrentPage)
            },
            onNavigateSecondaryToOriginalURL: { [weak self] separateCurrentPage in
                self?.navigateSecondaryToOriginalURL(separateCurrentPage: separateCurrentPage)
            }
        ))
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // The hosting view renders the display state, while AppKit owns the
        // inline editor so responder and hover changes stay decoupled.
        setupEditField()
        addSubview(editField)
        updateEditFieldLayout()

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.viewState.isHovered = isHovered
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
        viewState.primaryTabIsLive = false
        viewState.secondaryTabIsLive = false
        viewState.isFolder = false
        viewState.isFolderExpanded = false
        viewState.isActive = false
        viewState.isOpened = false
        viewState.isHovered = false
        viewState.isPressed = false
        viewState.isEditing = false
        viewState.isMultiSelected = false
        viewState.isDropTargetHighlighted = false
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
            }
            .store(in: &cancellables)

        bookmark.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] url in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: url)
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
        }
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
        viewState.isOpened = panes.primary != nil || panes.secondary != nil || bookmark.isOpened
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

        guard bookmark.isOpened else {
            viewState.primaryFaviconImage = storedPrimaryFaviconImage(bookmark: bookmark, pageUrl: pageUrl)
            return
        }

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
    @ObservedObject var state: BookmarkCellViewState
    @ObservedObject var primaryTabViewModel: TabViewModel
    @ObservedObject var secondaryTabViewModel: TabViewModel
    let onClose: () -> Void
    let onNavigatePrimaryToOriginalURL: (Bool) -> Void
    let onNavigateSecondaryToOriginalURL: (Bool) -> Void

    @State private var primaryFaviconHoverAction: BookmarkFaviconHoverAction?
    @State private var secondaryFaviconHoverAction: BookmarkFaviconHoverAction?

    @Environment(\.phiAppearance) private var appearance

    private var isHighlighted: Bool {
        state.isActive || state.isDropTargetHighlighted || state.isMultiSelected
    }

    private var backgroundColor: Color {
        if state.isActive || state.isDropTargetHighlighted {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        if state.isMultiSelected {
            return Color(nsColor: NSColor(resource: .sidebarTabSubSelected))
        }
        if state.isHovered {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        return .clear
    }

    private var borderColor: Color {
        if isHighlighted && appearance == .dark {
            return .white.opacity(0.2)
        }
        return .clear
    }

    private var textColor: ThemedColor {
        state.isFolder ? .textPrimaryStrong : .textPrimary
    }

    private var showCloseButton: Bool {
        state.isOpened && state.isHovered && !state.isEditing
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
                liveTabViewModel: state.primaryTabIsLive ? primaryTabViewModel : nil,
                onNavigateToOriginalURL: onNavigatePrimaryToOriginalURL,
                onReturnHoverChanged: { primaryFaviconHoverAction = $0 }
            )

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
                    liveTabViewModel: state.secondaryTabIsLive ? secondaryTabViewModel : nil,
                    onNavigateToOriginalURL: onNavigateSecondaryToOriginalURL,
                    onReturnHoverChanged: { secondaryFaviconHoverAction = $0 }
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
                .folderTitleWeight(state.isFolder ? .medium : .regular)
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

            if showCloseButton {
                UnifiedTabCloseButton(action: onClose)
            }
        }
        .help(state.title)
        .padding(.leading, state.isFolder ? 4 : 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: isHighlighted ? 1 : 0)
        )
        .shadow(color: .black.opacity(isHighlighted ? 0.15 : 0), radius: 1, x: 0, y: 1)
        .padding(.leading, WebContentConstant.edgesSpacing)
        .padding(.trailing, WebContentConstant.edgesSpacing)
        .padding(.vertical, 2)
        .scaleEffect(state.isFolder ? 1.0 : (state.isPressed ? 0.985 : 1.0))
        .animation(.easeOut(duration: 0.08), value: state.isPressed)
    }
}

private struct BookmarkFaviconView: View {
    let image: NSImage?
    let pageURL: String?
    let revision: Int
    let isFolder: Bool
    let isFolderExpanded: Bool
    let liveTabViewModel: TabViewModel?
    let onNavigateToOriginalURL: (Bool) -> Void
    let onReturnHoverChanged: (BookmarkFaviconHoverAction?) -> Void

    @State private var isReturnButtonHovered = false
    @State private var isCommandKeyPressed = false
    @State private var modifierFlagsMonitor: Any?

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
        .onChange(of: canNavigateToOriginalURL) { canNavigate in
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
        .frame(width: slotSize, height: slotSize)
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
        if isFolder {
            BookmarkFolderIconView(isExpanded: isFolderExpanded)
                .frame(width: Self.folderSize, height: Self.folderSize)
        } else if let liveTabViewModel {
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

private struct BookmarkFolderIconView: View {
    let isExpanded: Bool

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private var resourceName: String {
        isExpanded ? "bookmark-folder-open" : "bookmark-folder-closed"
    }

    var body: some View {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "svg") {
            let svgView = tintedSVGView(from: url)

            svgView
                .aspectRatio(1, contentMode: .fit)
        } else {
            Image(isExpanded ? .folderOpen : .folderClose)
                .resizable()
                .scaledToFit()
        }
    }

    private func tintedSVGView(from url: URL) -> SVGView {
        let svgView = SVGView(contentsOf: url)
        applyPalette(to: svgView)
        return svgView
    }

    private func applyPalette(to svgView: SVGView) {
        let palette = BookmarkFolderIconPalette(theme: theme, appearance: appearance)
        setShape(
            id: "folder-back-silhouette",
            in: svgView,
            fill: palette.backFill,
            stroke: nil
        )
        setShape(
            id: "folder-back-body",
            in: svgView,
            fill: palette.backFill,
            stroke: palette.stroke
        )
        setShape(
            id: "folder-front-panel",
            in: svgView,
            fill: palette.frontFill,
            stroke: palette.stroke
        )
    }

    private func setShape(id: String, in svgView: SVGView, fill: NSColor, stroke: NSColor?) {
        guard let shape = svgView.getNode(byId: id) as? SVGShape else { return }

        shape.fill = fill.svgViewColor
        if let stroke {
            shape.stroke = SVGStroke(fill: stroke.svgViewColor, width: 1)
        } else {
            shape.stroke = nil
        }
    }
}

private struct BookmarkFolderIconPalette {
    let backFill: NSColor
    let frontFill: NSColor
    let stroke: NSColor

    init(theme: Theme, appearance: Appearance) {
        let accent = theme.color(for: .themeColor, appearance: appearance)
        let hsb = accent.toHSBComponents()

        if appearance.isDark {
            backFill = theme.color(for: .windowBackground, appearance: appearance)
            frontFill = Self.makeColor(
                hue: hsb.h,
                saturation: hsb.s + 0.07,
                brightness: hsb.b - 0.24
            )
            stroke = .white
        } else {
            backFill = Self.makeColor(
                hue: hsb.h,
                saturation: 0.65,
                brightness: hsb.b - 0.15
            )
            frontFill = Self.makeColor(hue: hsb.h, saturation: 0.20, brightness: 1.00)
            stroke = Self.makeColor(hue: hsb.h, saturation: 0.65, brightness: 0.30)
        }
    }

    private static func makeColor(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> NSColor {
        NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation, 0), 1),
            brightness: min(max(brightness, 0), 1),
            alpha: 1
        )
    }
}

private extension NSColor {
    var svgViewColor: SVGColor {
        let color = usingColorSpace(.sRGB) ?? self
        return SVGColor(
            r: Int(round(color.redComponent * 255)),
            g: Int(round(color.greenComponent * 255)),
            b: Int(round(color.blueComponent * 255)),
            opacity: Double(color.alphaComponent)
        )
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

private extension View {
    /// `View.fontWeight` requires macOS 13; macOS 12 renders folder titles at
    /// regular weight (visual-only degradation).
    @ViewBuilder
    func folderTitleWeight(_ weight: Font.Weight) -> some View {
        if #available(macOS 13.0, *) {
            self.fontWeight(weight)
        } else {
            self
        }
    }
}
