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
        imageView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: NSLocalizedString("Search", comment: "Omnibox - Accessibility description for search icon"))
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
        view.translatesAutoresizingMaskIntoConstraints = false
        view.delegate = self
        view.isHidden = true
        view.wantsLayer = true
        return view
    }()
    
    private var suggestionViewHeightConstraint: NSLayoutConstraint?
    
    private let baseHeight: CGFloat = 57
    private let suggestionRowHeight: CGFloat = 44
    private let maxVisibleSuggestions: Int = 5
    private let maxSuggestionHeight: CGFloat = 226
    
    var openningFromCurrenTab: Bool { viewModel.opennedFromCurrentTab }
    
    private weak var browserState: BrowserState?
    // MARK: - Initialization
    init(viewModel: OmniBoxViewModel, state: BrowserState?) {
        self.viewModel = viewModel
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
            make.width.equalTo(Self.boxWidth)
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
    
    // MARK: - Private Methods
    
    private func updateSuggestions(_ suggestions: [OmniBoxSuggestion]) {
        suggestionView.updateSuggestions(suggestions, selectedIndex: viewModel.state.selectedIndex, dataSourceChanged: true)
    }
    
    private func updateSelectIndex(_ selectedIndex: Int, canUseTempString: Bool = false) {
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
                                      inlineCompletionEnabled: !viewModel.preventInlineCompletion)
            
            OmniSuggestionIconProvier.updateImage(for: iconImageView,
                                                  with: suggestion,
                                                  defaultImage:  NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: NSLocalizedString("Search", comment: "Omnibox - Accessibility description for search icon")))
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
        
        contentSize = newContentSize
    }
    
    func getContentSize() -> NSSize {
        let totalHeight = baseHeight + (suggestionViewHeightConstraint?.constant ?? 0) + 1
        return NSSize(width: Self.boxWidth, height: totalHeight)
    }
}

// MARK: - OmniBoxTextFieldDelegate

extension OmniBoxViewController: OmniBoxTextFieldDelegate {
    func omniBoxTextFieldDidReceiveMoveDownEvent(_ textField: OmniBoxTextField) -> Bool {
        viewModel.selectNextSuggestion()
        return true
    }
    
    func omniBoxTextFieldDidReceiveMoveUpEvent(_ textField: OmniBoxTextField) -> Bool {
        viewModel.selectPreviousSuggestion()
        return true
    }
    
    func omniBoxTextFieldDidReceiveEnterEvent(_ textField: OmniBoxTextField) -> Bool {
        viewModel.handleEnterPressed()
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
    }
    
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didDeleteSuggestion suggestion: OmniBoxSuggestion, at index: Int) {
        viewModel.deleteSuggestion(at: index)
    }
}
