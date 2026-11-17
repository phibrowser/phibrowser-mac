// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Combine
import SwiftUI

class SidebarHeaderView: NSView, TitlebarAwareHitTestable {
    private enum AccessibilityID {
        static let sidebarButton = "sidebarHeader.sidebarButton"
        static let searchTabsButton = "sidebarHeader.searchTabsButton"
        static let upgradeButton = "sidebarHeader.upgradeButton"
        static let backButton = "sidebarHeader.backButton"
        static let forwardButton = "sidebarHeader.forwardButton"
        static let refreshButton = "sidebarHeader.refreshButton"
        static let stopButton = "sidebarHeader.stopButton"
    }

    private lazy var cancellables = Set<AnyCancellable>()
    private var sidebarButtonLeadingConstraint: Constraint?
    private var upgradeButtonLeadingConstraint: Constraint?
    private var searchTabsButtonTrailingConstraint: Constraint?
    private var spaceSwitchTopConstraint: Constraint?
    static func controlRowTopOffset(
        for layoutMode: LayoutMode,
        edgeToEdgeEnabled: Bool = PhiPreferences.GeneralSettings.edgeToEdgeWebContent.loadValue()
    ) -> CGFloat {
        if layoutMode == .performance { return 8 }
        if layoutMode == .balanced && edgeToEdgeEnabled {
            return WebContentConstant.headerHeight / 2 - 12
        }
        return 15.5
    }

    var controlRowTopOffset: CGFloat {
        usesFloatingMetrics ? 8 : Self.controlRowTopOffset(
            for: browserState?.layoutMode ?? .performance,
            edgeToEdgeEnabled: WebContentLayout(browserState: browserState).edgeToEdgeEnabled
        )
    }
    /// Address bar gap under the nav row, and under the Spaces-switch row.
    private static let addressViewTopOffset: CGFloat = 12
    private static let addressViewTopOffsetBelowSpaceSwitch: CGFloat = 8
    /// Gap between the nav row and the Spaces-switch row.
    private static func spaceSwitchTopOffset(addressInSidebar: Bool) -> CGFloat {
        addressInSidebar ? 8 : 12
    }
    /// Header height the Spaces-switch row adds. With the address bar in the
    /// sidebar the row sits above it, so the bar's gap under the nav row
    /// becomes its gap under the row.
    static func spaceSwitchBandHeight(addressInSidebar: Bool) -> CGFloat {
        let band = spaceSwitchTopOffset(addressInSidebar: addressInSidebar) + SpacesStripView.sidebarHeight
        guard addressInSidebar else { return band }
        return band + addressViewTopOffsetBelowSpaceSwitch - addressViewTopOffset
    }
    private let addressViewHeight: CGFloat = 32
    private var sidebarButtonLeadingOffset: CGFloat = 78
    private let defaultSidebarButtonTrailingInset: CGFloat = 5
    private let balancedSidebarButtonTrailingInset: CGFloat = 9
    private static let sidebarButtonWidth: CGFloat = 24
    private static let upgradeButtonSize = NSSize(width: 56, height: 24)
    private static let upgradeButtonSpacing: CGFloat = 6
    private static let navigationTrailingInset: CGFloat = 9
    private var layoutSettleCancellable: AnyCancellable?
    /// Frame observer of the zoom button the sidebar button is aligned to;
    /// see `observeFrameChanges(zoomButton:)`.
    private var zoomButtonFrameObserver: NSObjectProtocol?
    private weak var observedZoomButton: NSButton?
    private var hasSetupConfigObserver = false
    /// Currently available app update version.
    private var availableUpdateVersion: String?
    private var currentWidth: CGFloat = 0
    private var isRefreshButtonHovered = false
    private var didPlayRefreshAnimationForCurrentHover = false

    /// The mounted Spaces-switch row (owned by the sidebar view controller);
    /// the header positions it and toggles its visibility with the feature flag.
    private weak var spaceSwitchView: NSView?
    /// The Spaces-switch row sits in the control row instead of its own row:
    /// in the Balanced and Performance layouts, once the user has hidden
    /// every button that row holds (the Update button does not count; the
    /// row starts after it). Its owner reclaims the row's height and
    /// right-aligns the strip's icons while this is true.
    private(set) var spaceSwitchSitsInControlRow = false
    /// Called when `spaceSwitchSitsInControlRow` changes.
    var onSpaceSwitchPlacementChanged: ((Bool) -> Void)?
    private var spaceSwitchControlRowLeading: CGFloat?
    /// Last-applied switch visibility, so the toggle observer only remakes
    /// constraints when the master Spaces flag actually flips.
    private var spaceSwitchVisible: Bool?
    /// Forces the Spaces-switch row visible even with a single Space. Set while
    /// the sidebar create-Space overlay is open so the icon row stays visible
    /// above the form (the user is managing Spaces, so the row is relevant even
    /// when there is nothing to switch to yet). See
    /// `SidebarViewController.showCreateSpaceOverlay`.
    var forcesSpaceSwitchVisible = false {
        didSet {
            guard oldValue != forcesSpaceSwitchVisible else { return }
            updateSpaceSwitchVisibility()
        }
    }

    private var isFloating: Bool = false
    /// The header mirrors in the right-sidebar layout: its leading edge, where
    /// the window's lights sit, is the sidebar's outer edge either way.
    private var isMirrored = SidebarPosition.isOnRight
    /// The window's buttons in this header: the floating header's while the
    /// column is collapsed, and both headers' in right-sidebar full screen,
    /// where the titlebar is hidden.
    private let trafficLightsView = SidebarTrafficLightsView()
    /// The header's own close-button centre
    /// (`SidebarTrafficLightsView.firstCenter`).
    private static let ownFirstCenter: CGFloat = 20

    /// A floating header lays out like the docked column's while the
    /// floating panel covers the column during a dock or undock: the nav row
    /// at the column's offset, the sidebar button after the window's own
    /// lights, and its lights on the window's. The panel then matches the
    /// column it replaces, and morphs to its own spacing.
    var usesDockedMetrics = false {
        didSet {
            guard isFloating, usesDockedMetrics != oldValue else { return }
            updateLayoutVisibility(layoutMode: browserState?.layoutMode ?? .performance)
            updateSidebarButtonLeadingConstraint()
            trafficLightsView.firstCenter = trafficLightsFirstCenter
        }
    }

    /// Keeps the floating header's lights through a hand-off: on an undock
    /// they are there before the column collapses, on a dock until the
    /// window's own show, once the column has opened
    /// (`MainSplitViewController.isSidebarExpanding`).
    var keepsTrafficLightsForHandOff = false {
        didSet {
            guard keepsTrafficLightsForHandOff != oldValue else { return }
            updateTrafficLights(layoutMode: browserState?.layoutMode ?? .performance)
        }
    }

    private var usesFloatingMetrics: Bool { isFloating && !usesDockedMetrics }

    /// The close button's centre: the header's own spacing, or, in docked
    /// metrics, on the window's close button. The header then sits at the
    /// window's leading edge, so window x is header x.
    private var trafficLightsFirstCenter: CGFloat {
        guard !usesFloatingMetrics, browserState?.isInFullScreenMode != true,
              let window, let close = window.titlebarButton(.closeButton) else {
            return Self.ownFirstCenter
        }
        let midX = close.convert(close.bounds, to: nil).midX
        return isMirrored ? window.frame.width - midX : midX
    }
    
    private lazy var sidebarButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(image: .leftSidebarToggle,
//                                           imageSize: .init(width: 18, height: 13),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(sidebarButtonClicked))
        return button
    }()

    private lazy var searchTabsButton: HoverableButtonNSView = {
        let label = NSLocalizedString("sidebar.searchTabsButton.accessibilityLabel", value: "Search Tabs", comment: "Search Tabs - Button tooltip and accessibility label")
        let config = HoverableButtonConfig(image: .leftSidebarSearchTab,
                                           imageSize: .init(width: 16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(searchTabsButtonClicked))
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isHidden = true
        return button
    }()

    private lazy var upgradeButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(
            title: NSLocalizedString("sidebar.updateReminder.updateButton", value: "Update", comment: "Sidebar header upgrade button title"),
            displayMode: .titleOnly,
            backgroundColor: .themeColor,
            hoverBackgroundColor: .themeColorOnHover,
            titleColor: .custom(light: .white, dark: .white),
            titleFont: .system(size: 11, weight: .medium),
            edgeInsets: EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4),
            cornerRadius: 6
        )
        let button = HoverableButtonNSView(config: config) { [weak self] in
            self?.upgradeButtonClicked()
        }
        button.isHidden = true
        return button
    }()
    
    
    private lazy var backButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "chevron.left", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarBackward,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(backButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var forwardButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "chevron.right", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarForward,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(forwardButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var refreshButton: LottieAnimationNSView = {
        let config = LottieAnimationViewConfig(
            animationName: "refresh",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 4,
            animationTrigger: .manual,
            themedTintColor: .custom(light: .black, dark: .white),
            reverseOnHoverExit: true
        )
        let button = LottieAnimationNSView(
            config: config,
            target: self,
            selector: #selector(refreshButtonClicked)
        )
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var stopButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "xmark", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: image,
                                           imageSize: .init(width: 14, height: 14),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(stopButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        button.isHidden = true
        return button
    }()

    private lazy var refreshStopButtonContainer: HoverableView = {
        let container = HoverableView()
        container.backgroundColor = .clear
        container.hoveredColor = .clear
        container.selectedColor = .clear
        container.responseToClickAction = false

        container.addSubview(refreshButton)
        container.addSubview(stopButton)

        refreshButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        stopButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        container.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        container.hoverStateChanged = { [weak self, weak container] hovered in
            guard let self, let container else { return }

            let hoverChanged = hovered != self.isRefreshButtonHovered
            self.isRefreshButtonHovered = hovered
            guard container.responseToHoverAnimation, hoverChanged else { return }

            if hovered {
                guard self.stopButton.isHidden else { return }
                self.didPlayRefreshAnimationForCurrentHover = true
                self.refreshButton.triggerAnimation()
            } else if self.didPlayRefreshAnimationForCurrentHover {
                self.didPlayRefreshAnimationForCurrentHover = false
                self.refreshButton.triggerReverseAnimation()
            }
        }

        return container
    }()

    private lazy var stackView: NSStackView = {
        let stack = NSStackView(views: [backButton, forwardButton, refreshStopButtonContainer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        return stack
    }()
    
    
    private lazy var addressView: SideAddressBar = {
        let addressView = SideAddressBar(browserState: browserState, isFloating: isFloating)
        addressView.setAccessoryButtonsVisible(isFloating)
        return addressView
    }()

    func setAddressBarButtonsVisible(_ visible: Bool, animated: Bool = true) {
        addressView.setAccessoryButtonsVisible(isFloating || visible, animated: animated)
    }
    
    private weak var browserState: BrowserState?
    /// Holds the header-button preferences the sidebar's context menu writes.
    private let defaults: UserDefaults

    init(state: BrowserState?, isFloating: Bool = false, defaults: UserDefaults = .standard) {
        self.browserState = state
        self.isFloating = isFloating
        self.defaults = defaults
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        self.defaults = .standard
        super.init(coder: coder)
        setupViews()
    }

    deinit {
        if let zoomButtonFrameObserver {
            NotificationCenter.default.removeObserver(zoomButtonFrameObserver)
        }
    }
    
    // MARK: - TitlebarAwareHitTestable
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        return false
    }
    
    private func setupViews() {
        let initialLayoutMode = browserState?.layoutMode ?? .performance

        configureAccessibilityIdentifiers()

        addSubview(sidebarButton)
        addSubview(searchTabsButton)
        addSubview(upgradeButton)

        sidebarButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(controlRowTopOffset)
            sidebarButtonLeadingConstraint = pinToLeadingEdge(make, inset: 78)
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        addSubview(trafficLightsView)
        addSubview(stackView)
        remakeMirroredConstraints()

        updateLayoutVisibility(layoutMode: initialLayoutMode)
    }

    /// An offset written for the left-sidebar layout, mirrored for the right.
    private func directed(_ offset: CGFloat) -> CGFloat {
        isMirrored ? -offset : offset
    }

    @discardableResult
    private func pinToLeadingEdge(_ make: ConstraintMaker, inset: CGFloat) -> Constraint {
        (isMirrored ? make.right : make.left).equalToSuperview().offset(directed(inset)).constraint
    }

    @discardableResult
    private func pinToTrailingEdge(_ make: ConstraintMaker, inset: CGFloat) -> Constraint {
        (isMirrored ? make.left : make.right).equalToSuperview().offset(directed(-inset)).constraint
    }

    /// Lays the row out for the side the sidebar is on. Back and forward keep
    /// their reading order on either side; their glyphs are not mirrored.
    private func remakeMirroredConstraints() {
        trafficLightsView.isMirrored = isMirrored
        trafficLightsView.firstCenter = trafficLightsFirstCenter
        trafficLightsView.snp.remakeConstraints { make in
            if isMirrored { make.trailing.equalToSuperview() } else { make.leading.equalToSuperview() }
            make.centerY.equalTo(sidebarButton)
            make.height.equalTo(24)
        }

        searchTabsButton.snp.remakeConstraints { make in
            make.centerY.equalTo(sidebarButton)
            searchTabsButtonTrailingConstraint = (isMirrored
                ? make.left.equalTo(sidebarButton.snp.right)
                : make.right.equalTo(sidebarButton.snp.left)).offset(directed(-2)).constraint
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        upgradeButton.snp.remakeConstraints { make in
            make.centerY.equalTo(sidebarButton)
            upgradeButtonLeadingConstraint = pinToLeadingEdge(make, inset: sidebarButtonLeadingOffset)
            make.size.equalTo(Self.upgradeButtonSize)
        }

        let navigationButtons: [NSView] = isMirrored
            ? [refreshStopButtonContainer, backButton, forwardButton]
            : [backButton, forwardButton, refreshStopButtonContainer]
        for button in navigationButtons {
            stackView.removeArrangedSubview(button)
            stackView.addArrangedSubview(button)
        }
        stackView.snp.remakeConstraints { make in
            make.centerY.equalTo(sidebarButton)
            make.height.equalTo(24)
            pinToTrailingEdge(make, inset: Self.navigationTrailingInset)
        }

        // Re-placed on the new side by `updateSpaceSwitchPlacement`.
        spaceSwitchControlRowLeading = nil
    }

    private func configureAccessibilityIdentifiers() {
        configureButtonAccessibility(sidebarButton, identifier: AccessibilityID.sidebarButton)
        configureButtonAccessibility(searchTabsButton, identifier: AccessibilityID.searchTabsButton)
        configureButtonAccessibility(upgradeButton, identifier: AccessibilityID.upgradeButton)
        configureButtonAccessibility(backButton, identifier: AccessibilityID.backButton)
        configureButtonAccessibility(forwardButton, identifier: AccessibilityID.forwardButton)
        configureButtonAccessibility(refreshButton, identifier: AccessibilityID.refreshButton)
        configureButtonAccessibility(stopButton, identifier: AccessibilityID.stopButton)
    }

    private func configureButtonAccessibility(_ button: NSView, identifier: String) {
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(identifier)
    }

    /// Mounts the Spaces-switch row between the nav row and the address bar so
    /// it reads as the top-most per-Space control. The view is owned by the
    /// sidebar view controller (a child hosting controller); the header only
    /// positions it and re-points the address bar to sit beneath it.
    func mountSpaceSwitch(_ view: NSView) {
        addSubview(view)
        spaceSwitchView = view
        updateSpaceSwitchVisibility()
    }

    func unmountSpaceSwitch() {
        guard let strip = spaceSwitchView else { return }
        spaceSwitchView = nil
        spaceSwitchVisible = nil
        spaceSwitchTopConstraint = nil
        spaceSwitchControlRowLeading = nil
        setSpaceSwitchSitsInControlRow(false)
        makeAddressViewConstraints()
        strip.snp.removeConstraints()
        strip.removeFromSuperview()
    }

    /// Shows or hides the Spaces-switch row, reclaiming the row's height (and
    /// re-pinning the address bar to the nav row) when it is hidden. The row
    /// shows only when the master Spaces feature flag is on AND more than one
    /// Space exists — with a single Space there is nothing to switch to, so the
    /// pip row is pure noise. Called on mount, whenever the toggle flips, and
    /// whenever the Space count crosses the single-Space threshold, so the
    /// header never reserves space for a control the user can't use.
    func updateSpaceSwitchVisibility() {
        guard let view = spaceSwitchView else { return }
        let enabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && (SpaceManager.shared.spaces.count > 1 || forcesSpaceSwitchVisible)
        guard spaceSwitchVisible != enabled else { return }
        spaceSwitchVisible = enabled

        view.isHidden = !enabled
        if enabled {
            let addressInSidebar = isSidebarLayout(browserState?.layoutMode ?? .performance)
            view.snp.remakeConstraints { make in
                make.leading.trailing.equalToSuperview()
                spaceSwitchTopConstraint = make.top.equalTo(stackView.snp.bottom)
                    .offset(Self.spaceSwitchTopOffset(addressInSidebar: addressInSidebar)).constraint
                make.height.equalTo(SpacesStripView.sidebarHeight)
            }
        } else {
            spaceSwitchControlRowLeading = nil
            setSpaceSwitchSitsInControlRow(false)
            view.snp.remakeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.top.equalTo(stackView.snp.bottom)
                make.height.equalTo(0)
            }
        }
        makeAddressViewConstraints()
        updateLayoutVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }

    /// Only the Performance layout shows the address bar in the header.
    /// Elsewhere it leaves the view tree: hidden, it would still be laid out
    /// on every step of a window resize.
    private func setAddressViewAttached(_ attached: Bool) {
        guard attached != (addressView.superview != nil) else { return }
        if attached {
            if let spaceSwitchView {
                addSubview(addressView, positioned: .below, relativeTo: spaceSwitchView)
            } else {
                addSubview(addressView)
            }
            makeAddressViewConstraints()
        } else {
            addressView.removeFromSuperview()
        }
    }

    private func makeAddressViewConstraints() {
        guard addressView.superview != nil else { return }
        addressView.snp.remakeConstraints { make in
            make.left.right.equalToSuperview()
            if spaceSwitchVisible == true, let spaceSwitchView {
                make.top.equalTo(spaceSwitchView.snp.bottom).offset(Self.addressViewTopOffsetBelowSpaceSwitch)
            } else {
                make.top.equalTo(stackView.snp.bottom).offset(Self.addressViewTopOffset)
            }
            make.height.equalTo(addressViewHeight)
        }
    }

    private func isSidebarLayout(_ layoutMode: LayoutMode) -> Bool {
        layoutMode == .performance
    }

    /// Update view visibility based on configuration
    private func updateLayoutVisibility(layoutMode: LayoutMode) {
        if isMirrored != SidebarPosition.isOnRight {
            isMirrored = SidebarPosition.isOnRight
            remakeMirroredConstraints()
        }
        sidebarButton.isImageMirrored = isMirrored
        updateTrafficLights(layoutMode: layoutMode)
        let showInSidebar = isSidebarLayout(layoutMode)
        let inPlaceholder = browserState?.isInPlaceholderMode ?? false
        AppLogDebug("[SidebarHeader] updateLayoutVisibility showInSidebar=\(showInSidebar) inPlaceholder=\(inPlaceholder)")

        // Default layout: navigation buttons and address bar in sidebar.
        // The back/forward/reload stack is hidden by
        // `updateNavigationButtonsVisibility`, which this method ends with.
        // Address bar visibility is delegated to SideAddressBar's own
        // placeholder-mode sink (blanks the text field).
        setAddressViewAttached(showInSidebar)
        spaceSwitchTopConstraint?.update(offset: Self.spaceSwitchTopOffset(addressInSidebar: showInSidebar))

        // Adjust sidebarButton position
        sidebarButton.snp.remakeConstraints { make in
            make.top.equalToSuperview().offset(usesFloatingMetrics ? 8 : Self.controlRowTopOffset(
                for: layoutMode,
                edgeToEdgeEnabled: WebContentLayout(browserState: browserState).edgeToEdgeEnabled
            ))
            make.size.equalTo(NSSize(width: 24, height: 24))

            if showInSidebar {
                // Default layout: sidebarButton after the traffic light buttons
                AppLogDebug("[SidebarHeader] updateLayoutVisibility apply default constraints offset=\(sidebarButtonLeadingOffset)")
                sidebarButtonLeadingConstraint = pinToLeadingEdge(make, inset: sidebarButtonLeadingOffset)
            } else {
                // Legacy layout: sidebarButton at the trailing edge
                AppLogDebug("[SidebarHeader] updateLayoutVisibility apply legacy constraints")
                let trailingInset = layoutMode == .balanced
                    ? balancedSidebarButtonTrailingInset
                    : defaultSidebarButtonTrailingInset
                pinToTrailingEdge(make, inset: trailingInset)
            }
        }

        // In default layout mode, update sidebarButton left position based on window buttons
        if showInSidebar {
            scheduleSidebarButtonUpdateAfterLayoutChange()
        }
        // The floating header too: in full screen its lights come and go
        // with the side.
        updateSidebarButtonLeadingConstraint()
        // A sidebar-side change reaches this sink before the window's
        // split has moved the column, so the lights were measured from
        // the old side. Measure again once the move has landed.
        DispatchQueue.main.async { [weak self] in
            self?.updateSidebarButtonLeadingConstraint()
        }

        updateUpgradeAndSidebarVisibility(layoutMode: layoutMode)
    }

    /// Observe configuration changes
    private func setupConfigObserver() {
        guard hasSetupConfigObserver == false,
              let browserState else {
            return
        }
        hasSetupConfigObserver = true

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in }
            .merge(with: browserState.$isTranscriptDocked.map { _ in })
            .prepend(())
            .receive(on: DispatchQueue.main)
            .map { [weak browserState] _ -> (Bool, Bool) in
                let layout = WebContentLayout(browserState: browserState)
                return (layout.edgeToEdgeEnabled, layout.sidebarOnRight)
            }
            .removeDuplicates { (previous: (Bool, Bool), current: (Bool, Bool)) in
                guard previous.0 == current.0 else { return false }
                return previous.1 == current.1
            }
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateLayoutVisibility(layoutMode: self.browserState?.layoutMode ?? .performance)
            }
            .store(in: &cancellables)

        // The header buttons the user hides from the sidebar's context menu.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in }
            .prepend(())
            .map { [defaults] _ in
                [PhiPreferences.GeneralSettings.sidebarHeaderShowsSearchTabs,
                 .sidebarHeaderShowsSidebarToggle,
                 .sidebarHeaderShowsBack,
                 .sidebarHeaderShowsForward,
                 .sidebarHeaderShowsReload].map { $0.loadValue(from: defaults) }
            }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateUpgradeAndSidebarVisibility(layoutMode: self.browserState?.layoutMode ?? .performance)
            }
            .store(in: &cancellables)

        if isFloating {
            browserState.sidebarCollapsedPublisher
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    updateTrafficLights(layoutMode: self.browserState?.layoutMode ?? .performance)
                }
                .store(in: &cancellables)
        }

        browserState.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink {  [weak self] mode in
                guard let self else {
                    return
                }
                updateLayoutVisibility(layoutMode: mode)
            }
            .store(in: &cancellables)

        // Re-run layout visibility on placeholder-mode transitions so the
        // back/forward/reload stack hides alongside the placeholder shell.
        // Reuse the same method to avoid overshadowing stackView.isHidden.
        browserState.$isInPlaceholderMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateLayoutVisibility(layoutMode: PhiPreferences.GeneralSettings.loadLayoutMode())
            }
            .store(in: &cancellables)

        browserState.$isInFullScreenMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
                self.updateLayoutVisibility(layoutMode: layoutMode)
                if self.isSidebarLayout(layoutMode) {
                    self.updateSidebarButtonLeadingConstraint()
                }
            }
            .store(in: &cancellables)
    }
    
    /// The window's own buttons in the floating header while the column is
    /// collapsed, in the Balanced and Performance layouts, and in either
    /// header in right-sidebar full screen
    /// (`SpaceSessionController.applyTrafficLightVisibility`).
    private func updateTrafficLights(layoutMode: LayoutMode) {
        let fullScreen = browserState?.isInFullScreenMode == true
        trafficLightsView.firstCenter = trafficLightsFirstCenter
        guard isFloating else {
            trafficLightsView.isActive = fullScreen && isMirrored
            return
        }
        trafficLightsView.isActive = !layoutMode.isTraditional
            && (browserState?.sidebarCollapsed == true || keepsTrafficLightsForHandOff)
            && (!fullScreen || isMirrored)
    }

    /// How far the leading chrome controls reach into this header from its
    /// leading edge.
    private func leadingChromeExtent() -> CGFloat? {
        if browserState?.isInFullScreenMode == true {
            return isMirrored ? trafficLightsView.trailingEdge : 0
        }
        if usesFloatingMetrics {
            return trafficLightsView.trailingEdge
        }
        return windowButtonExtent(button: .zoomButton)
            ?? windowButtonExtent(button: .closeButton)
    }

    /// How far a standard window button reaches in from the window's edge on
    /// the sidebar's side, in window coordinates, or nil if the button
    /// doesn't exist.
    ///
    /// Not converted into this view: the docked header's resting outer edge
    /// is the window's, but while the column slides in or out it is offscreen,
    /// and a titlebar re-tile during that slide would turn into an offset that
    /// pushes the button out of the header with nothing to correct it after.
    private func windowButtonExtent(button type: NSWindow.ButtonType) -> CGFloat? {
        guard let window, let btn = window.titlebarButton(type) else { return nil }
        let frame = btn.convert(btn.bounds, to: nil)
        let extent = isMirrored ? window.frame.width - frame.minX : frame.maxX
        AppLogDebug("[SidebarHeader] windowButtonExtent type=\(type.rawValue) extent=\(extent)")
        return extent
    }

    /// Updates the leading constraint for `sidebarButton` based on the extent of the leading chrome.
    private func updateSidebarButtonLeadingConstraint() {
        observeFrameChanges(zoomButton: isFloating ? nil : window?.titlebarButton(.zoomButton))
        guard let x = leadingChromeExtent() else {
            AppLogDebug("[SidebarHeader] updateSidebarButtonLeadingConstraint extent=nil (window buttons unavailable)")
            return
        }
        // Keep a small gap after the leading chrome group.
        if abs(sidebarButtonLeadingOffset - (x + 10)) < 0.01 { return }
        AppLogDebug("[SidebarHeader] updateSidebarButtonLeadingConstraint update offset=\(x + 10)")
        sidebarButtonLeadingOffset = x + 10
        sidebarButtonLeadingConstraint?.update(offset: directed(sidebarButtonLeadingOffset))
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
        // A titlebar frame notification can arrive during layout. Let AppKit
        // coalesce this constraint update instead of laying out recursively.
        needsLayout = true
    }

    /// Realigns the sidebar button when the zoom button changes frame, which
    /// titlebar layout changes do without resizing the window. Observed as an
    /// object: an observer without one runs for every view resized anywhere
    /// in the app, which an animation does every frame. The block form keeps
    /// neither the button nor the window alive. The observer follows the
    /// button the alignment last looked up: it moves to a button AppKit
    /// replaced and goes when the header leaves its window. The floating
    /// header aligns to its own lights and observes none.
    private func observeFrameChanges(zoomButton: NSButton?) {
        if let zoomButton, zoomButton === observedZoomButton { return }
        if let zoomButtonFrameObserver {
            NotificationCenter.default.removeObserver(zoomButtonFrameObserver)
        }
        zoomButtonFrameObserver = nil
        observedZoomButton = zoomButton
        guard let zoomButton else { return }
        zoomButtonFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: zoomButton,
            queue: .main
        ) { [weak self] _ in
            self?.updateSidebarButtonLeadingConstraint()
        }
    }

    private func scheduleSidebarButtonUpdateAfterLayoutChange() {
        layoutSettleCancellable?.cancel()
        // The subscription retains its `object`, this view, until it fires.
        // A header that has left its window gets no layout pass to fire it
        // and would stay alive for good, with the state and slot its
        // subviews hold. Entering a window arms it and realigns directly.
        guard window != nil else {
            layoutSettleCancellable = nil
            return
        }
        postsFrameChangedNotifications = true
        layoutSettleCancellable = NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: self)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                AppLogDebug("[SidebarHeader] frameDidChange settled updateSidebarButtonLeadingConstraint")
                self.updateSidebarButtonLeadingConstraint()
                self.layoutSettleCancellable?.cancel()
                self.layoutSettleCancellable = nil
            }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // React to layout-mode and preference changes.
        setupConfigObserver()
        updateLayoutVisibility(layoutMode: browserState?.layoutMode ?? .performance)

        browserState?.$focusingTab
            .compactMap { $0 }
            .map { tab in Publishers.CombineLatest3(Just(tab), tab.$canGoBack, tab.$canGoForward) }
            .switchToLatest()
            .sink { [weak self] tab, canBack, canForward in
                guard let self else { return }
                self.backButton.isEnabled = canBack
                self.forwardButton.isEnabled = canForward
            }
            .store(in: &cancellables)

        browserState?.$focusingTab
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                guard let self else { return }
                self.refreshButton.isHidden = false
                self.stopButton.isHidden = true
                self.addressView.currentTab = tab
            }
            .store(in: &cancellables)

        browserState?.$focusingTab
            .compactMap { $0 }
            .map { tab in
                tab.$isLoading.combineLatest(tab.$loadingProgress)
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading, progress in
                guard let self else { return }
                self.updateStopRefreshButton(isLoading: isLoading, progress: CGFloat(progress))
            }
            .store(in: &cancellables)
        
        // React to width changes that may affect header layout.
        publisher(for: \.frame)
            .map { $0.width }
            .removeDuplicates()
            .sink { [weak self] newWidth in
                guard let self else { return }
                self.handleWidthChange(newWidth)
            }
            .store(in: &cancellables)
        
        // Position sidebar button relative to the window's traffic-light buttons
        updateSidebarButtonLeadingConstraint()

        // Keep updated on window resize. Matched by identity rather than
        // `object:` — a Combine subscription retains its `object`, and a
        // window retained by a view it hosts never deallocates. Titlebar
        // layout changes move the zoom button instead, which
        // `observeFrameChanges(zoomButton:)` observes without retaining it.
        if window != nil {
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification))
                .filter { [weak self] notification in
                    guard let self, let window = self.window else { return false }
                    return notification.object as? NSWindow === window
                }
                .sink { [weak self] _ in self?.updateSidebarButtonLeadingConstraint() }
                .store(in: &cancellables)
        }

        // The header's lights follow full screen through the deferred
        // `isInFullScreenMode` sink, which runs after AppKit has captured the
        // window for its animation, so the old lights could stay in it until
        // it ended: the floating header's, and the docked header's with the
        // sidebar on the right. The window controller marks the Browser as
        // the transition starts; check the lights again in that same turn.
        if window != nil {
            NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification))
                .filter { [weak self] notification in
                    guard let self, let window = self.window else { return false }
                    return notification.object as? NSWindow === window
                }
                .sink { [weak self] _ in
                    guard let self else { return }
                    updateTrafficLights(layoutMode: browserState?.layoutMode ?? .performance)
                }
                .store(in: &cancellables)
        }

        #if !PHI_OSS_BUILD
        // Show the upgrade button once Sparkle reports a downloaded update.
        NotificationCenter.default.publisher(for: .sparkleDidDownloadUpdate)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                let displayVersion = notification.userInfo?["displayVersion"] as? String ?? ""
                self?.showUpgradeButton(version: displayVersion)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sparkleDidSkipUpdate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.hideUpgradeButton()
            }
            .store(in: &cancellables)
        #endif

        #if DEBUG
        applyUITestUpdateOverrideIfNeeded()
        #endif
    }

    func refreshFloatingTrafficLights() {
        guard isFloating else {
            return
        }

        updateTrafficLights(layoutMode: browserState?.layoutMode ?? .performance)
        trafficLightsView.refresh()
    }

    #if DEBUG
    private func applyUITestUpdateOverrideIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitest"),
              let versionFlagIndex = arguments.firstIndex(of: "-sidebarHeaderUpdateVersion"),
              arguments.indices.contains(versionFlagIndex + 1) else {
            return
        }

        let version = arguments[versionFlagIndex + 1]
        guard !version.isEmpty else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentWidth = self.frame.width
            self.showUpgradeButton(version: version)
        }
    }
    #endif
    
    private func handleWidthChange(_ newWidth: CGFloat) {
        currentWidth = newWidth
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }
    
    @objc private func sidebarButtonClicked() {
        browserState?.toggleSidebar(nil)
    }

    @objc private func searchTabsButtonClicked() {
        browserState?.windowController?.toggleSearchTabs(attachedTo: searchTabsButton)
    }
    
    @objc private func backButtonClicked() {
        if browserState?.closePeekForBackForwardNavigation() == true { return }
        if browserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        browserState?.focusingTab?.goBack()
    }

    @objc private func forwardButtonClicked() {
        if browserState?.closePeekForBackForwardNavigation() == true { return }
        if browserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        browserState?.focusingTab?.goForward()
    }
    
    @objc private func refreshButtonClicked() {
        browserState?.focusingTab?.reload()
    }

    @objc private func stopButtonClicked() {
        browserState?.focusingTab?.stopLoading()
    }

    private func updateStopRefreshButton(isLoading: Bool, progress: CGFloat) {
        let isNTP = browserState?.focusingTab?.isNTP == true
        let showStop = isLoading && !isNTP && progress > 0 && progress < 1.0
        refreshButton.isHidden = showStop
        stopButton.isHidden = !showStop
    }

    private func upgradeButtonClicked() {
        guard availableUpdateVersion != nil else { return }
        #if !PHI_OSS_BUILD
        AppController.shared.checkForUpdate(nil)
        #endif
    }

    /// Shows the upgrade button for a downloaded update.
    private func showUpgradeButton(version: String) {
        availableUpdateVersion = version
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }

    /// Hides the upgrade button.
    private func hideUpgradeButton() {
        availableUpdateVersion = nil
        updateUpgradeAndSidebarVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }

    /// Shows the back, forward, and reload buttons the user keeps. The stack
    /// closes up around hidden ones, and hides whole in the placeholder
    /// shell (no tab to act on) or once none is left.
    private func updateNavigationButtonsVisibility(layoutMode: LayoutMode) {
        typealias Setting = PhiPreferences.GeneralSettings
        backButton.isHidden = !Setting.sidebarHeaderShowsBack.loadValue(from: defaults)
        forwardButton.isHidden = !Setting.sidebarHeaderShowsForward.loadValue(from: defaults)
        refreshStopButtonContainer.isHidden = !Setting.sidebarHeaderShowsReload.loadValue(from: defaults)
        let inPlaceholder = browserState?.isInPlaceholderMode ?? false
        stackView.isHidden = !isSidebarLayout(layoutMode) || inPlaceholder || !keepsNavigationButton
    }

    /// Whether the user keeps any of back, forward, and reload.
    private var keepsNavigationButton: Bool {
        !(backButton.isHidden && forwardButton.isHidden && refreshStopButtonContainer.isHidden)
    }

    private func updateUpgradeAndSidebarVisibility(layoutMode: LayoutMode) {
        updateNavigationButtonsVisibility(layoutMode: layoutMode)
        let showsSidebarToggle = PhiPreferences.GeneralSettings.sidebarHeaderShowsSidebarToggle.loadValue(from: defaults)
        sidebarButton.isHidden = !showsSidebarToggle
        searchTabsButton.isHidden = layoutMode != .balanced
            || !PhiPreferences.GeneralSettings.sidebarHeaderShowsSearchTabs.loadValue(from: defaults)
        // Search Tabs sits just before the sidebar button, and takes its
        // place when the user hides it.
        searchTabsButtonTrailingConstraint?.update(offset: directed(showsSidebarToggle ? -2 : Self.sidebarButtonWidth))

        let upgradeLeadingOffset = upgradeButtonLeadingOffset(layoutMode: layoutMode)
        upgradeButtonLeadingConstraint?.update(offset: directed(upgradeLeadingOffset))
        upgradeButton.isHidden = availableUpdateVersion == nil
            || !hasRoomForUpgradeButton(layoutMode: layoutMode, leadingOffset: upgradeLeadingOffset)
        updateSpaceSwitchPlacement(layoutMode: layoutMode)
    }

    /// Moves the Spaces-switch row up into the control row once the user has
    /// hidden every button in it, and back into its own row when one returns.
    /// In Performance the row also holds back, forward, and reload, so those
    /// must be hidden too. The Update button comes and goes with the
    /// sidebar's width, so it never decides the row: the Spaces row starts
    /// after it instead, and a resize never changes the header's height.
    private func updateSpaceSwitchPlacement(layoutMode: LayoutMode) {
        guard let view = spaceSwitchView, spaceSwitchVisible == true else { return }
        let inControlRow = layoutMode != .comfortable
            && sidebarButton.isHidden && searchTabsButton.isHidden
            && !holdsNavigationButtons(layoutMode: layoutMode)
        if inControlRow {
            let leading = spaceSwitchControlRowLeadingOffset(layoutMode: layoutMode)
            guard !spaceSwitchSitsInControlRow || spaceSwitchControlRowLeading != leading else { return }
            spaceSwitchControlRowLeading = leading
            spaceSwitchTopConstraint = nil
            view.snp.remakeConstraints { make in
                pinToLeadingEdge(make, inset: leading)
                pinToTrailingEdge(make, inset: 0)
                make.centerY.equalTo(sidebarButton)
                make.height.equalTo(SpacesStripView.sidebarHeight)
            }
        } else {
            guard spaceSwitchSitsInControlRow else { return }
            spaceSwitchControlRowLeading = nil
            view.snp.remakeConstraints { make in
                make.leading.trailing.equalToSuperview()
                spaceSwitchTopConstraint = make.top.equalTo(stackView.snp.bottom)
                    .offset(Self.spaceSwitchTopOffset(addressInSidebar: isSidebarLayout(layoutMode))).constraint
                make.height.equalTo(SpacesStripView.sidebarHeight)
            }
        }
        setSpaceSwitchSitsInControlRow(inControlRow)
    }

    /// Whether the control row keeps a back, forward, or reload button. The
    /// placeholder shell does not count: it hides the stack for a moment, and
    /// the Spaces row should not jump with it.
    private func holdsNavigationButtons(layoutMode: LayoutMode) -> Bool {
        isSidebarLayout(layoutMode) && keepsNavigationButton
    }

    /// Where the Spaces row starts in the control row: after the leading
    /// chrome, or after the Update button while it shows. The docked header
    /// reuses the traffic-light offset `updateSidebarButtonLeadingConstraint`
    /// keeps current, so a width change measures no window buttons.
    private func spaceSwitchControlRowLeadingOffset(layoutMode: LayoutMode) -> CGFloat {
        let chromeLeading = isFloating ? (leadingChromeExtent() ?? 0) + 10 : sidebarButtonLeadingOffset
        guard !upgradeButton.isHidden else { return chromeLeading }
        let upgradeMaxX = upgradeButtonLeadingOffset(layoutMode: layoutMode) + Self.upgradeButtonSize.width
        return max(chromeLeading, upgradeMaxX + Self.upgradeButtonSpacing)
    }

    private func setSpaceSwitchSitsInControlRow(_ sits: Bool) {
        guard spaceSwitchSitsInControlRow != sits else { return }
        spaceSwitchSitsInControlRow = sits
        onSpaceSwitchPlacementChanged?(sits)
    }

    /// Performance keeps the sidebar button after the traffic lights, so
    /// Update follows it; elsewhere the sidebar button sits at the trailing
    /// edge and Update takes the slot after the traffic lights.
    private func upgradeButtonLeadingOffset(layoutMode: LayoutMode) -> CGFloat {
        guard isSidebarLayout(layoutMode), !sidebarButton.isHidden else { return sidebarButtonLeadingOffset }
        return sidebarButtonLeadingOffset + Self.sidebarButtonWidth + Self.upgradeButtonSpacing
    }

    private func hasRoomForUpgradeButton(layoutMode: LayoutMode, leadingOffset: CGFloat) -> Bool {
        guard isSidebarLayout(layoutMode) else { return currentWidth > 225 }
        let navigationWidth = stackView.isHidden ? 0 : stackView.fittingSize.width
        let navigationMinX = currentWidth - Self.navigationTrailingInset - navigationWidth
        return leadingOffset + Self.upgradeButtonSize.width + Self.upgradeButtonSpacing <= navigationMinX
    }
}
