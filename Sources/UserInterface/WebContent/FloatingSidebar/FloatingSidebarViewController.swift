// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import AppKit
import SnapKit
/// Floating sidebar shown when the primary sidebar is collapsed in non-comfortable layouts.
/// This is a lightweight mapping of SidebarViewController without notification/message/bottom areas.
class FloatingSidebarViewController: NSViewController {
    private static let defaultFavoriteHeight: CGFloat = 10

    /// Main vertical stack
    private lazy var mainStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 0
        stackView.distribution = .fill
        return stackView
    }()

    private var state: BrowserState
    private lazy var headerView = SidebarHeaderView(state: state, isFloating: true)
    private lazy var pinnedTabViewController = PinnedTabViewController(state: state)
    private lazy var tabList = SidebarTabListViewController(state: state)

    private lazy var pinnedTabsContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    private var cancellables = Set<AnyCancellable>()
    private var contentCancellables = Set<AnyCancellable>()
    private var headerHeightConstraint: Constraint?
    private var pinnedHeightConstraint: Constraint?
    private var hasSetupObservers = false
    private var isContentActive = false

    init(browserState: BrowserState) {
        self.state = browserState
        super.init(nibName: nil, bundle: nil)
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view: NSView
        if #available(macOS 26, *) {
            view = NSView()
            view.wantsLayer = true
            view.phiLayer?.setBackgroundColor(.windowOverlayBackground)
            
        } else {
            let _view = ColoredVisualEffectView()
            _view.themedBackgroundColor = .windowOverlayBackground
            _view.blendingMode = .behindWindow
            view = _view
        }
        self.view = view
       
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupStackView()
        setupObserversIfNeeded()
        updateHeaderHeight()
        setContentActive(false)
    }

    deinit {
        tabList.tearDown()
    }

    private func setupStackView() {
        addChild(pinnedTabViewController)
        addChild(tabList)

        view.addSubview(mainStackView)
        mainStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // 1. Header
        mainStackView.addArrangedSubview(headerView)
        headerView.snp.makeConstraints { make in
            headerHeightConstraint = make.height.equalTo(73).constraint
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
        }

        // 2. Header spacer
        mainStackView.addArrangedSubview(createSpacer(height: 5))

        // 3. pinned tabs
        pinnedTabsContainerView.addSubview(pinnedTabViewController.view)
        pinnedTabViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        mainStackView.addArrangedSubview(pinnedTabsContainerView)
        pinnedTabsContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            pinnedHeightConstraint = make.height.equalTo(Self.defaultFavoriteHeight).constraint
        }

        // 4. Favorites spacer
        mainStackView.addArrangedSubview(createSpacer(height: 3))

        // 5. Tab list
        mainStackView.addArrangedSubview(tabList.view)
        tabList.view.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
        }
        tabList.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabList.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // 6. Bottom spacer
        mainStackView.addArrangedSubview(createSpacer(height: 8))
    }

    private func createSpacer(height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.snp.makeConstraints { make in
            make.height.equalTo(height)
        }
        return spacer
    }

    private func setupObserversIfNeeded() {
        guard hasSetupObservers == false else { return }
        hasSetupObservers = true

        state.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHeaderHeight()
            }
            .store(in: &cancellables)
    }

    func setContentActive(_ active: Bool) {
        guard active != isContentActive else { return }
        isContentActive = active

        contentCancellables.removeAll()
        pinnedTabViewController.setActive(active)
        tabList.setActive(active)

        guard active else { return }

        pinnedTabViewController.$contentHeight
            .combineLatest(state.$isDraggingTab)
            .debounce(for: .seconds(0.01), scheduler: DispatchQueue.main)
            .sink { [weak self] newHeight, dragging in
                self?.updateFavoriteHeight(newHeight, isDragging: dragging)
            }
            .store(in: &contentCancellables)

        updateFavoriteHeight(pinnedTabViewController.contentHeight, isDragging: state.isDraggingTab)
    }

    private func updateHeaderHeight() {
        let showInSidebar = !PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        let headerHeight: CGFloat = showInSidebar ? 73 : 41
        headerHeightConstraint?.update(offset: headerHeight)
    }

    private func updateFavoriteHeight(_ newHeight: CGFloat, isDragging: Bool = false) {
        let clampedHeight: CGFloat
        if newHeight < 20 && isDragging {
            clampedHeight = 100
        } else {
            clampedHeight = newHeight
        }

        pinnedHeightConstraint?.update(offset: clampedHeight)
        view.layoutSubtreeIfNeeded()
    }
}
