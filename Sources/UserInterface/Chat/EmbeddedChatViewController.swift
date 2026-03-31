// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

/// Embedded AI Chat controller hosted inside `WebContentViewController`.
class EmbeddedChatViewController: NSViewController {
    private lazy var contentView = NSView()
    private lazy var cancellables = Set<AnyCancellable>()
    private weak var browserState: BrowserState?
    private var isSetup = false
    
    /// The associated Tab for this embedded chat
    private(set) weak var associatedTab: Tab?
    
    /// The current AI Chat Tab being displayed
    private weak var currentAIChatTab: Tab?
    
    /// The identifier for the associated tab (used for AI Chat tab lookup)
    private var tabIdentifier: String?
    
    init(with browserState: BrowserState, tab: Tab? = nil) {
        self.browserState = browserState
        self.associatedTab = tab
        super.init(nibName: nil, bundle: nil)
        _ = self.view
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        self.view = NSView()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(contentView)
        contentView.wantsLayer = true
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.cornerRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        contentView.phiLayer?.backgroundColor = NSColor.white <> NSColor.black
       
        contentView.layer?.borderWidth = 1
        contentView.phiLayer?.setBorderColor(.border)
        
        contentView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview().inset(WebContentConstant.contentEdgeSpacing)
            make.leading.equalToSuperview()
        }
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        setupIfNeeded()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        reattachAIChatViewIfNeeded()
    }
    
    // MARK: - Focus Management
    
    /// Moves focus into the embedded AI Chat content.
    func focusAIChat() {
        guard let wrapper = currentAIChatTab?.webContentWrapper else { return }
        DispatchQueue.main.async { [weak self] in
            if let nativeView = self?.currentAIChatTab?.webContentView {
                self?.view.window?.makeFirstResponder(nativeView)
            }
            if wrapper.responds(to: #selector(WebContentWrapper.focus)) {
                wrapper.restoreFocus()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Updates the primary tab associated with this chat pane.
    func updateAssociatedTab(_ tab: Tab) {
        guard tab !== associatedTab else { return }
        
        self.associatedTab = tab
        
        if let state = browserState {
            let newIdentifier = state.getTabIdentifier(for: tab)
            if newIdentifier != tabIdentifier {
                tabIdentifier = newIdentifier
                loadAIChatForCurrentTab()
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupIfNeeded() {
        guard !isSetup, let state = browserState, state.isIncognito == false else {
            return
        }
        isSetup = true
        
        if let tab = associatedTab {
            tabIdentifier = state.getTabIdentifier(for: tab)
        }
        
        state.$aiChatTabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                self?.handleAIChatTabsChanged(tabs)
            }
            .store(in: &cancellables)
        
        loadAIChatForCurrentTab()
    }
    
    /// Handles changes to the `aiChatTabs` lookup.
    private func handleAIChatTabsChanged(_ tabs: [String: Tab]) {
        guard let identifier = tabIdentifier else { return }
        
        if let aiChatTab = tabs[identifier], aiChatTab !== currentAIChatTab {
            switchToAIChatTab(aiChatTab, isNewlyCreated: true)
        } else if tabs[identifier] == nil, currentAIChatTab != nil {
            clearCurrentAIChatTab()
        }
    }
    
    private func clearCurrentAIChatTab() {
        currentAIChatTab?.webContentView?.removeFromSuperview()
        currentAIChatTab?.onFocusGained = nil
        currentAIChatTab = nil
        contentView.subviews.forEach { $0.removeFromSuperview() }
    }
    
    /// Loads or creates the AI Chat tab for the associated browser tab.
    private func loadAIChatForCurrentTab() {
        guard let state = browserState, let identifier = tabIdentifier, let tab = associatedTab else { return }

        if let existingTab = state.aiChatTabs[identifier] {
            switchToAIChatTab(existingTab, isNewlyCreated: false)
        } else {
            let chromeTabId = tab.guid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak state] in
                guard let self, let state else { return }
                if state.aiChatTabs[identifier] == nil {
                    state.createAIChatTab(for: identifier, chromeTabId: chromeTabId)
                }
            }
        }
    }
    
    /// Switch to display the specified AI Chat tab
    /// - Parameters:
    ///   - tab: AI Chat Tab to switch to
    ///   - isNewlyCreated: Whether to focus the chat after the content loads.
    private func switchToAIChatTab(_ tab: Tab, isNewlyCreated: Bool) {
        if currentAIChatTab !== tab {
            currentAIChatTab?.webContentView?.removeFromSuperview()
            currentAIChatTab?.onFocusGained = nil
        }
        
        currentAIChatTab = tab
        
        setupFocusCallbackForAIChatTab(tab)
        
        if let native = tab.webContentView {
            addWebContent(native)
            if isNewlyCreated {
                focusAIChat()
            }
        } else {
            observeWebContentReady(for: tab, focusWhenReady: isNewlyCreated)
        }
    }
    
    /// Updates the primary tab focus target when the AI Chat gains focus.
    private func setupFocusCallbackForAIChatTab(_ aiChatTab: Tab) {
        aiChatTab.onFocusGained = { [weak self] in
            self?.associatedTab?.updateFocusTarget(.aiChat)
        }
        
        if aiChatTab.webContentWrapper?.isFocused == true {
            associatedTab?.updateFocusTarget(.aiChat)
        }
    }
    
    /// Waits for the native web view to become available.
    private func observeWebContentReady(for tab: Tab, focusWhenReady: Bool = false) {
        var checkCount = 0
        let maxChecks = 20
        
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak tab] timer in
            checkCount += 1
            
            guard let self, let tab else {
                timer.invalidate()
                return
            }
            
            guard tab === self.currentAIChatTab else {
                timer.invalidate()
                return
            }
            
            if let native = tab.webContentView {
                timer.invalidate()
                self.addWebContent(native)
                if focusWhenReady {
                    self.focusAIChat()
                }
            } else if checkCount >= maxChecks {
                timer.invalidate()
            }
        }
    }
    
    private func addWebContent(_ native: NSView) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        
        contentView.addSubview(native)
        native.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    /// Reattaches the AI Chat view if another container moved it away,
    /// or creates a new AI Chat tab if the previous one was cleaned up.
    private func reattachAIChatViewIfNeeded() {
        if currentAIChatTab == nil {
            loadAIChatForCurrentTab()
            return
        }
        guard let native = currentAIChatTab?.webContentView else { return }
        if native.superview === contentView { return }
        addWebContent(native)
    }
}
