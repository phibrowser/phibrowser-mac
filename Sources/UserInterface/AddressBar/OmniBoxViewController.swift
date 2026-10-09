// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

class OmniBoxViewController: NSViewController {
    private let viewModel: OmniBoxViewModel
    private var cancellables = Set<AnyCancellable>()
    
    weak var actionDelegate: OmniBoxActionDelegate?
    
    // Published property for content size changes
    @Published var contentSize: NSSize = NSSize(width: boxWidth, height: 57)
    static let boxWidth = 680.0
    // MARK: - UI Components
    
    private lazy var backgroundContainer: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.contentOverlayBackground)
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.phiLayer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor <> NSColor.white.withAlphaComponent(0.2).cgColor
        view.clipsToBounds = true
        return view
    }()
    
    private lazy var shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = .omniboxShadow
        shadow.shadowOffset = NSSize(width: 0, height: -20)
        shadow.shadowBlurRadius = 50
        return shadow
    }()
    
    private lazy var inputeAreaContainer: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()
    
    private lazy var separatorView: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.separator)
        return view
    }()
    
    private lazy var iconImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: NSLocalizedString("addressBar.searchIcon.initialAccessibilityLabel", value: "Search", comment: "Address bar - Initial accessibility description for the search icon"))
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = NSColor.secondaryLabelColor
        return imageView
    }()
    
    private lazy var textField: OmniBoxTextField = {
        let field = OmniBoxTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.omniBoxDelegate = self
        return field
    }()
    
    private lazy var suggestionView: OmniBoxSuggestionView = {
        let view = OmniBoxSuggestionView()
        view.showsSwitchToTabHint = showsSwitchToTabHint
        view.translatesAutoresizingMaskIntoConstraints = false
        view.delegate = self
        view.isHidden = true
        view.wantsLayer = true
        return view
    }()

    private let searchEngineBadge = NSView()
    private let searchEngineLabel = NSTextField(labelWithString: "")
    private let keywordHintLabel = NSTextField(labelWithString: "")
    
    private var suggestionViewHeightConstraint: NSLayoutConstraint?
    
    private let baseHeight: CGFloat = 57
    private let suggestionRowHeight: CGFloat = 44
    private let maxVisibleSuggestions: Int = 5
    private let maxSuggestionHeight: CGFloat = 226
    
    var openningFromCurrenTab: Bool { viewModel.opennedFromCurrentTab }
    var showsSwitchToTabHintForTesting: Bool { showsSwitchToTabHint }
    
    private weak var browserState: BrowserState?
    private let showsSwitchToTabHint: Bool
    // MARK: - Initialization
    init(viewModel: OmniBoxViewModel, state: BrowserState?) {
        self.viewModel = viewModel
        showsSwitchToTabHint = state?.isKioskWindow != true
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func loadView() {
        view = NSView()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.wantsLayer = true
        view.shadow = shadow
        setupViews()
        setupBindings()
        
        viewModel.delegate = actionDelegate
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        if let window = view.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification,
                object: window
            )
        }
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
        viewModel.reset()
        NotificationCenter.default.removeObserver(self)
        browserState?.stopAutoCompletion()
    }
    
    // MARK: - Setup
    
    private func setupViews() {
        view.addSubview(backgroundContainer)
        
        backgroundContainer.addSubview(inputeAreaContainer)
        inputeAreaContainer.addSubview(iconImageView)
        inputeAreaContainer.addSubview(textField)
        inputeAreaContainer.addSubview(searchEngineBadge)
        searchEngineBadge.addSubview(searchEngineLabel)
        inputeAreaContainer.addSubview(keywordHintLabel)
        searchEngineBadge.wantsLayer = true
        searchEngineBadge.clipsToBounds = false
        searchEngineBadge.layer?.cornerRadius = 12
        searchEngineBadge.layer?.shadowOffset = .zero
        searchEngineBadge.layer?.shadowRadius = 7
        searchEngineBadge.layer?.shadowOpacity = 0.2
        searchEngineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        searchEngineLabel.textColor = .white
        searchEngineLabel.lineBreakMode = .byTruncatingTail
        searchEngineLabel.maximumNumberOfLines = 1
        keywordHintLabel.font = .systemFont(ofSize: 11)
        keywordHintLabel.textColor = .secondaryLabelColor
        keywordHintLabel.lineBreakMode = .byTruncatingTail
        searchEngineBadge.isHidden = true
        keywordHintLabel.isHidden = true
        backgroundContainer.addSubview(suggestionView)
        backgroundContainer.addSubview(separatorView)
        setupConstraints()
    }
    
    private func setupConstraints() {
        backgroundContainer.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        inputeAreaContainer.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(baseHeight)
            // High, not required: the natural width sizes the freestanding
            // Cmd+L panel (which frames this view at `contentSize`), but the
            // native NTP embeds the box in surfaces narrower than 680 — a
            // splitview pane — and frames it to fit (see
            // `NewTabViewController.updateContentLayout`). There the required
            // leading/trailing pins must win and compress the box instead of
            // fighting the frame.
            make.width.equalTo(Self.boxWidth).priority(.high)
        }
        
        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        
        textField.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalTo(iconImageView)
        }

        searchEngineBadge.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(8)
            make.centerY.equalTo(iconImageView)
            make.height.equalTo(24)
            make.width.lessThanOrEqualTo(160)
        }
        searchEngineLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(10)
            make.centerY.equalToSuperview()
        }
        keywordHintLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.centerY.equalTo(iconImageView)
            make.width.lessThanOrEqualTo(200)
        }
        
        suggestionView.snp.makeConstraints { make in
            make.top.equalTo(inputeAreaContainer.snp.bottom)
            make.leading.trailing.equalTo(inputeAreaContainer)
        }
        
        suggestionViewHeightConstraint = suggestionView.heightAnchor.constraint(equalToConstant: 0)
        suggestionViewHeightConstraint?.isActive = true
        
        separatorView.snp.makeConstraints { make in
            make.top.equalTo(inputeAreaContainer.snp.bottom)
            make.leading.trailing.equalToSuperview().inset(18)
            make.height.equalTo(1)
        }
    }
    
    private func setupBindings() {
        viewModel.$selectedSearchEngine.combineLatest(
            viewModel.$keywordSearchHint,
            viewModel.state.$selectedIndex.combineLatest(viewModel.state.$suggestions),
            viewModel.$isSearchEngineSpaceShortcutEnabled
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] engine, hint, _, _ in
                self?.updateKeywordSearchUI(engine: engine, hint: hint)
            }
            .store(in: &cancellables)
        viewModel.state.$inputText
            .sink { [weak self] text in
                if self?.textField.stringValue != text {
                    self?.textField.updateDisplayText(text)
                }
            }
            .store(in: &cancellables)
        
        viewModel.state.$selectedIndex
            .combineLatest(viewModel.$canUseTemporaryText.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selectedIndex, canUseTemporaryText in
                self?.updateSelectIndex(selectedIndex, canUseTempString: canUseTemporaryText)
            }
            .store(in: &cancellables)
        
        viewModel.state.$suggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestions in
                guard let self else { return }
                self.updateSuggestions(suggestions)
            }
            .store(in: &cancellables)
        
        viewModel.state.$suggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestions in
                self?.updateSuggestionViewHeight(for: suggestions.count)
            }
            .store(in: &cancellables)
        
        viewModel.state.$isShowingSuggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShowing in
                self?.suggestionView.isHidden = !isShowing
                if isShowing {
                    let count = self?.viewModel.state.suggestions.count ?? 0
                    self?.logOpenTrace(stage: "suggestions-visible", details: "count=\(count)", once: true)
                }
            }
            .store(in: &cancellables)
    }
    
    func requestAtonce(source: OmniBoxSearchRequestSource = .manualRefresh) {
        if viewModel.state.inputText.isEmpty {
            contentSize = { contentSize }()
        } else {
            viewModel.performSearchAtonce(source: source)
        }
    }
    
    // MARK: - Public Methods

    func prepareForPresentation() {
        viewModel.refreshSearchEngineSpaceShortcut()
    }

    func handleKeywordSearchSpaceKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49, event.characters == " ",
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let window = textField.window, event.window === window,
              let editor = textField.textFiled.currentEditor() as? NSTextView,
              window.firstResponder === editor,
              !editor.hasMarkedText(),
              editor.selectedRange.length == 0,
              editor.selectedRange.location == (editor.string as NSString).length,
              viewModel.acceptKeywordSearchWithSpace() else { return false }
        textField.updateDisplayText(viewModel.state.inputText)
        textField.selectToEnd()
        return true
    }
    
    func setActionDelegate(_ delegate: OmniBoxActionDelegate) {
        self.actionDelegate = delegate
        viewModel.delegate = delegate
    }
    
    func focusTextField() {
        view.window?.makeFirstResponder(textField)
    }
    
    func reset() {
        viewModel.reset()
    }

    func updateStatus(with tab: Tab) {
        viewModel.updateStatus(with: tab)
    }

    func updateStatusForGroupOverview() {
        viewModel.updateStatusForGroupOverview()
    }

    func setCurrentTabForNavigation(_ tab: Tab?) {
        viewModel.setCurrentTab(tab)
    }

    func beginOpenTrace(trigger: String, addressViewPresent: Bool) {
        viewModel.beginOpenTrace(trigger: trigger, addressViewPresent: addressViewPresent)
    }

    func logOpenTrace(stage: String, details: String? = nil, once: Bool = false) {
        viewModel.logOpenTrace(stage: stage, details: details, once: once)
    }

    func updateStatus(with tab: Tab, suppressAutomaticSearch: Bool) {
        viewModel.updateStatus(with: tab, suppressAutomaticSearch: suppressAutomaticSearch)
    }

    func confirmSelection(commandKeyPressed: Bool = false) {
        viewModel.handleEnterPressed(commandKeyPressed: commandKeyPressed)
    }
    
    // MARK: - Private Methods

    private func updateKeywordSearchUI(engine: OmniBoxKeywordSearchEngine?, hint: OmniBoxKeywordSearchEngine?) {
        textField.updateSearchPlaceholder(engineName: engine?.name)
        if engine != nil {
            iconImageView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        }
        searchEngineLabel.stringValue = engine?.name ?? ""
        let accent = engine?.accentColor ?? .themeColor
        searchEngineBadge.phiLayer?.setBackgroundColor(accent)
        searchEngineBadge.phiLayer?.shadowColor = accent.cgColorMapperOptional
        searchEngineBadge.isHidden = engine == nil
        keywordHintLabel.stringValue = hint.map {
            if viewModel.canAcceptKeywordSearchWithSpace {
                return String(format: NSLocalizedString("addressBar.keywordSearch.tabOrSpaceHint", value: "Tab or Space to search %@", comment: "Address bar - Hint shown when Tab or Space can select the highlighted search engine; %@ is the engine name"), $0.name)
            }
            return String(format: NSLocalizedString("addressBar.keywordSearch.tabHint", value: "Tab to search %@", comment: "Address bar - Hint to press Tab to search with the named search engine"), $0.name)
        } ?? ""
        keywordHintLabel.isHidden = hint == nil || engine != nil
        textField.snp.remakeConstraints { make in
            make.leading.equalTo(engine == nil ? iconImageView.snp.trailing : searchEngineBadge.snp.trailing).offset(8)
            if !keywordHintLabel.isHidden {
                make.trailing.equalTo(keywordHintLabel.snp.leading).offset(-8)
            } else {
                make.trailing.equalToSuperview().inset(12)
            }
            make.centerY.equalTo(iconImageView)
        }
    }
    
    private func updateSuggestions(_ suggestions: [OmniBoxSuggestion]) {
        suggestionView.updateSuggestions(suggestions, selectedIndex: viewModel.state.selectedIndex, dataSourceChanged: true)
    }
    
    private func updateSelectIndex(_ selectedIndex: Int, canUseTempString: Bool = false) {
        guard viewModel.selectedSearchEngine == nil else { return }
        let suggestions = viewModel.state.suggestions
        suggestionView.updateSuggestions(suggestions, selectedIndex: selectedIndex, dataSourceChanged: false)
        if selectedIndex >= 0, selectedIndex < suggestions.count {
            let suggestion = suggestions[selectedIndex]
            AppLogDebug("Auto-completed: \(suggestion)")
            var canUseTempString = canUseTempString
            if selectedIndex == 0, suggestion.allowedToBeDefault {
                canUseTempString = false
            }
            textField.updateSelection(inlineCompletString: suggestion.inlineCompletionString,
                                      fillString: suggestion.fillIntoEdit,
                                      canUseTempString: canUseTempString,
                                      inlineCompletionEnabled: !viewModel.preventInlineCompletion && viewModel.keywordSearchHint == nil)
            
            OmniSuggestionIconProvier.updateImage(for: iconImageView,
                                                  with: suggestion,
                                                  defaultImage:  NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: NSLocalizedString("addressBar.searchIcon.suggestionFallbackAccessibilityLabel", value: "Search", comment: "Address bar - Accessibility description for the fallback search icon shown with suggestions")))
        } else {
            iconImageView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        }
    }
    
    @objc private func windowDidResize() {
        suggestionView.needsUpdateConstraints = true
    }
    
    // MARK: - Dynamic Height Management
    
    private func updateSuggestionViewHeight(for suggestionCount: Int) {
        let newHeight = calculateSuggestionViewHeight(for: suggestionCount)
        
        suggestionViewHeightConstraint?.constant = newHeight
        
        notifyContentSizeChange()
    }
    
    private func calculateSuggestionViewHeight(for suggestionCount: Int) -> CGFloat {
        if suggestionCount == 0 {
            return 0
        } else if suggestionCount <= maxVisibleSuggestions {
            return CGFloat(suggestionCount) * suggestionRowHeight + OmniBoxSuggestionView.topPadding + OmniBoxSuggestionView.bottomPadding
        } else {
            return maxSuggestionHeight
        }
    }
    
    private func notifyContentSizeChange() {
        let totalHeight = baseHeight + (suggestionViewHeightConstraint?.constant ?? 0)
        let newContentSize = NSSize(width: Self.boxWidth, height: totalHeight)
        
        if contentSize != newContentSize {
            contentSize = newContentSize
        }
    }
    
    func getContentSize() -> NSSize {
        let totalHeight = baseHeight + (suggestionViewHeightConstraint?.constant ?? 0) + 1
        return NSSize(width: Self.boxWidth, height: totalHeight)
    }
}

// MARK: - OmniBoxTextFieldDelegate

extension OmniBoxViewController: OmniBoxTextFieldDelegate {
    func omniBoxTextFieldDidReceiveTabEvent(_ textField: OmniBoxTextField) -> Bool {
        guard viewModel.acceptKeywordSearch() else { return false }
        textField.updateDisplayText(viewModel.state.inputText)
        textField.selectToEnd()
        return true
    }

    func omniBoxTextFieldDidReceiveEmptyBackspaceEvent(_ textField: OmniBoxTextField) -> Bool {
        guard viewModel.exitKeywordSearchIfEmpty() else { return false }
        textField.updateDisplayText(viewModel.state.inputText)
        textField.selectToEnd()
        return true
    }

    func omniBoxTextFieldDidReceiveMoveDownEvent(_ textField: OmniBoxTextField) -> Bool {
        viewModel.selectNextSuggestion()
        return true
    }
    
    func omniBoxTextFieldDidReceiveMoveUpEvent(_ textField: OmniBoxTextField) -> Bool {
        viewModel.selectPreviousSuggestion()
        return true
    }
    
    func omniBoxTextFieldDidReceiveEnterEvent(_ textField: OmniBoxTextField, commandKeyPressed: Bool) -> Bool {
        viewModel.handleEnterPressed(commandKeyPressed: commandKeyPressed)
        return true
    }
    
    
    func omniBoxTextFieldDidChange(_ textField: OmniBoxTextField, suppressAutoComplete: Bool) {
        viewModel.updateInputText(textField.stringValue, suppressAutoComplete: suppressAutoComplete)
    }
    
    func omniBoxTextFieldDidBeginEditing(_ textField: OmniBoxTextField) {
        viewModel.setFocused(true)
    }
    
    func omniBoxTextFieldDidEndEditing(_ textField: OmniBoxTextField) {
        viewModel.setFocused(false)
    }
}

// MARK: - OmniBoxSuggestionViewDelegate

extension OmniBoxViewController: OmniBoxSuggestionViewDelegate {
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didClickSuggestion suggestion: OmniBoxSuggestion, at index: Int) {
        viewModel.clickSuggestionAtIndex(index)
        if suggestion.keywordSearchEngine != nil, viewModel.selectedSearchEngine != nil {
            focusTextField()
        }
    }
    
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didDeleteSuggestion suggestion: OmniBoxSuggestion, at index: Int) {
        viewModel.deleteSuggestion(at: index)
    }
}
