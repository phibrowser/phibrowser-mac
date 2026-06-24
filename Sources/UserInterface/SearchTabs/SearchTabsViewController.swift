// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

enum SearchTabsPanelDisplayMode: Equatable {
    case compact
    case normal

    var panelWidth: CGFloat {
        switch self {
        case .compact:
            return 350
        case .normal:
            return 680
        }
    }
}

@MainActor
final class SearchTabsViewController: NSViewController {
    @Published private(set) var contentSize: NSSize
    var didRequestDismiss: (() -> Void)?
    var maximumContentSize: NSSize {
        NSSize(width: displayMode.panelWidth, height: baseHeight + maxResultsHeight)
    }
    var usesFullWidthLayout: Bool {
        displayMode == .normal
    }

    private var displayMode: SearchTabsPanelDisplayMode
    private let viewModel: SearchTabsViewModel
    private let actionExecutor: SearchTabsActionExecutor
    private let bookmarkMenuPresenter: SearchTabsBookmarkMenuPresenter
    private var cancellables = Set<AnyCancellable>()

    private let baseHeight: CGFloat = 57
    private let maxResultsHeight: CGFloat = 460
    private var inputWidthConstraint: Constraint?
    private var resultsHeightConstraint: Constraint?
    private var renderedSections: [SearchTabsSectionSnapshot]?
    private var renderedQuery = ""
    private var lastBookmarkRootMenuItemID: String?

    private lazy var shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = .omniboxShadow
        shadow.shadowOffset = NSSize(width: 0, height: -20)
        shadow.shadowBlurRadius = 50
        return shadow
    }()

    private lazy var backgroundContainer: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.contentOverlayBackground)
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.phiLayer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor <> NSColor.white.withAlphaComponent(0.16).cgColor
        view.clipsToBounds = true
        return view
    }()

    private lazy var inputContainer: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()

    private lazy var searchIconView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        return imageView
    }()

    private lazy var textField: SearchTabsTextField = {
        let field = SearchTabsTextField()
        field.delegate = self
        field.keyDelegate = self
        return field
    }()

    private lazy var separatorView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.separator)
        return view
    }()

    private lazy var resultsView: SearchTabsResultsView = {
        let view = SearchTabsResultsView()
        view.delegate = self
        return view
    }()

    init(browserState: BrowserState, displayMode: SearchTabsPanelDisplayMode = .normal) {
        self.displayMode = displayMode
        self.contentSize = NSSize(width: displayMode.panelWidth, height: 57)
        self.viewModel = SearchTabsViewModel(dataController: SearchTabsDataController(browserState: browserState))
        self.actionExecutor = SearchTabsActionExecutor(browserState: browserState)
        self.bookmarkMenuPresenter = SearchTabsBookmarkMenuPresenter(browserState: browserState)
        super.init(nibName: nil, bundle: nil)
        bookmarkMenuPresenter.didOpenBookmark = { [weak self] in
            self?.didRequestDismiss?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.shadow = shadow
        setupViews()
        setupBindings()
        refresh()
    }

    func refresh() {
        viewModel.reset()
        textField.stringValue = ""
        focusTextField()
    }

    func focusTextField() {
        view.window?.makeFirstResponder(textField)
    }

    func setDisplayMode(_ displayMode: SearchTabsPanelDisplayMode) {
        guard self.displayMode != displayMode else {
            return
        }
        self.displayMode = displayMode
        inputWidthConstraint?.update(offset: displayMode.panelWidth)
        contentSize = NSSize(width: displayMode.panelWidth, height: contentSize.height)
    }

    private func setupViews() {
        view.addSubview(backgroundContainer)
        backgroundContainer.addSubview(inputContainer)
        inputContainer.addSubview(searchIconView)
        inputContainer.addSubview(textField)
        backgroundContainer.addSubview(separatorView)
        backgroundContainer.addSubview(resultsView)

        backgroundContainer.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        inputContainer.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalTo(baseHeight)
            inputWidthConstraint = make.width.equalTo(displayMode.panelWidth).constraint
        }
        searchIconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        textField.snp.makeConstraints { make in
            make.leading.equalTo(searchIconView.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalTo(searchIconView)
        }
        separatorView.snp.makeConstraints { make in
            make.top.equalTo(inputContainer.snp.bottom)
            make.leading.trailing.equalToSuperview().inset(18)
            make.height.equalTo(1)
        }
        resultsView.snp.makeConstraints { make in
            make.top.equalTo(inputContainer.snp.bottom)
            make.leading.trailing.equalToSuperview()
            resultsHeightConstraint = make.height.equalTo(0).constraint
        }
    }

    private func setupBindings() {
        viewModel.$sections
            .combineLatest(viewModel.$selectedIndex)
            .combineLatest(viewModel.$inputText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sectionState, query in
                let (sections, selectedIndex) = sectionState
                self?.updateResults(sections, selectedIndex: selectedIndex, query: query)
            }
            .store(in: &cancellables)

        viewModel.$inputText
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, self.textField.stringValue != text else { return }
                self.textField.stringValue = text
            }
            .store(in: &cancellables)
    }

    private func updateResults(
        _ sections: [SearchTabsSectionSnapshot],
        selectedIndex: Int,
        query: String
    ) {
        let dataSourceChanged = renderedSections != sections || renderedQuery != query
        renderedSections = sections
        renderedQuery = query

        if dataSourceChanged {
            lastBookmarkRootMenuItemID = nil
        }

        resultsView.updateSections(
            sections,
            profileId: viewModel.snapshot.profileId,
            selectedIndex: selectedIndex,
            query: query,
            dataSourceChanged: dataSourceChanged
        )

        let fullResultsHeight = resultsView.measuredContentHeight()
        let resultsHeight = fullResultsHeight == 0
            ? 0
            : min(fullResultsHeight, maxResultsHeight)
        resultsHeightConstraint?.update(offset: resultsHeight)
        separatorView.isHidden = sections.isEmpty
        contentSize = NSSize(width: displayMode.panelWidth, height: baseHeight + resultsHeight)
        view.layoutSubtreeIfNeeded()
        resultsView.normalizeScrollPositionIfNeeded()
    }

    private func execute(_ item: SearchTabsItem) {
        switch item.action {
        case .showBookmarkMenuRoot:
            showBookmarkMenu(for: item, anchorView: resultsView.anchorView(for: item.id))
        default:
            if actionExecutor.perform(item.action) {
                didRequestDismiss?()
            }
        }
    }

    private func showBookmarkMenu(for item: SearchTabsItem, anchorView: NSView?) {
        guard let anchorView else {
            return
        }
        lastBookmarkRootMenuItemID = item.id
        DispatchQueue.main.async { [weak self, weak anchorView] in
            guard let self, let anchorView else { return }
            self.bookmarkMenuPresenter.showBookmarkRootMenu(relativeTo: anchorView)
        }
    }
}

extension SearchTabsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        viewModel.updateInputText(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === textField else {
            return false
        }

        switch commandSelector {
        case #selector(NSTextView.moveDown(_:)):
            return searchTabsTextFieldDidMoveDown(textField)
        case #selector(NSTextView.moveUp(_:)):
            return searchTabsTextFieldDidMoveUp(textField)
        case #selector(NSTextView.insertNewline(_:)),
             #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)):
            return searchTabsTextFieldDidConfirm(textField)
        case #selector(NSResponder.cancelOperation(_:)):
            return searchTabsTextFieldDidCancel(textField)
        default:
            return false
        }
    }
}

extension SearchTabsViewController: SearchTabsTextFieldKeyDelegate {
    func searchTabsTextFieldDidMoveDown(_ textField: SearchTabsTextField) -> Bool {
        viewModel.selectNextItem()
        return true
    }

    func searchTabsTextFieldDidMoveUp(_ textField: SearchTabsTextField) -> Bool {
        viewModel.selectPreviousItem()
        return true
    }

    func searchTabsTextFieldDidConfirm(_ textField: SearchTabsTextField) -> Bool {
        guard let selectedItem = viewModel.selectedItem else {
            return true
        }
        execute(selectedItem)
        return true
    }

    func searchTabsTextFieldDidCancel(_ textField: SearchTabsTextField) -> Bool {
        didRequestDismiss?()
        return true
    }
}

extension SearchTabsViewController: SearchTabsResultsViewDelegate {
    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didSelect item: SearchTabsItem) {
        viewModel.selectItem(at: viewModel.items.firstIndex(where: { $0.id == item.id }) ?? -1)
        execute(item)
    }

    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didRequestClose item: SearchTabsItem) {
        guard actionExecutor.close(item) else {
            return
        }

        viewModel.removeItem(withID: item.id)
        focusTextField()
    }

    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didToggleSection section: SearchTabsSectionKind) {
        viewModel.toggleSection(section)
    }

    func searchTabsResultsView(_ resultsView: SearchTabsResultsView, didHoverBookmarkRoot item: SearchTabsItem, anchorView: NSView) {
        guard lastBookmarkRootMenuItemID != item.id else {
            return
        }
        showBookmarkMenu(for: item, anchorView: anchorView)
    }
}
