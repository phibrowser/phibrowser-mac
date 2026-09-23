//
//  PlaceholderShellViewController.swift
//  PhiBrowser
//
//  Hosts the placeholder WebContents NSView (chrome://dino) when the window
//  enters placeholder mode after closing the last tab. Mirrors the relevant
//  parts of WebContentViewController so the layout's address bar (in
//  .balanced / .comfortable) stays visible during placeholder mode. Skips
//  the splitView / AI chat / bookmark bar / progress bar — placeholder
//  doesn't use any of them.
//
//  See docs/superpowers/specs/2026-05-25-placeholder-on-last-tab-close-design.md
//  (v3, shell approach) — sections §6.3, §6.5, §9.1, §9.2 are most relevant.
//

import AppKit
import Combine
import SnapKit

/// Root view of the placeholder shell.
///
/// Browser-reserved shortcut routing (cmd+W / cmd+Q / cmd+T / cmd+L / ...)
/// is handled on the Chromium side in
/// `PhiCommandDispatcherDelegate.prePerformKeyEquivalent`, which short-
/// circuits to `kPassToMainMenu` while `Browser::IsInPlaceholderMode()` is
/// true. An earlier attempt to intercept in this view's
/// `performKeyEquivalent` never actually fired, because the placeholder
/// RWHV consumes the event during view-tree recursion before reaching this
/// root view. Plain character keys (Space etc.) still flow through
/// `keyDown:` to the RWHV unaffected.
///
/// Empty subclass kept so future view-level overrides (e.g. drag handling,
/// background tweaks) can land here without changing the view type.
private final class PlaceholderShellRootView: ColoredVisualEffectView {}

final class PlaceholderShellViewController: NSViewController {
    private weak var browserState: BrowserState?

    private lazy var leftContainerWrapper = NSView()
    private lazy var leftContainerView = NSView()
    private lazy var headerView = WebContentHeader(browserState: browserState)
    private lazy var hostView = WebContentHostView()

    private var headerHeightConstraint: Constraint?
    private var leftContainerLeadingConstraint: Constraint?
    private var layoutObserverCancellable: AnyCancellable?
    private var sidebarCollapsedObserverCancellable: AnyCancellable?

    /// Anchors the omnibox popup when invoked via cmd+L in placeholder mode.
    /// Falls through to the header's anchor view; matches how
    /// `WebContentViewController.addressBarAnchorView` works.
    var addressBarAnchorView: NSView? { headerView.addressBarAnchorView }

    init(browserState: BrowserState?) {
        self.browserState = browserState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = PlaceholderShellRootView()
        root.themedBackgroundColor = .windowOverlayBackground
        root.material = .fullScreenUI
        root.wantsLayer = true
        self.view = root
        setupView()
        observeLayoutMode()
    }

    private func setupView() {
        view.addSubview(leftContainerWrapper)
        leftContainerWrapper.snp.makeConstraints { make in
            leftContainerLeadingConstraint = make.leading.equalToSuperview()
                .inset(contentLeadingInset)
                .constraint
            make.trailing.bottom.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.equalToSuperview()
        }

        leftContainerWrapper.addSubview(leftContainerView)
        leftContainerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        leftContainerView.wantsLayer = true
        leftContainerView.layer?.cornerCurve = .continuous
        leftContainerView.layer?.cornerRadius =
            LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        leftContainerView.layer?.masksToBounds = true
        leftContainerView.phiLayer?.backgroundColor = NSColor.white <> NSColor.black

        leftContainerView.addSubview(headerView)
        headerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview()
            headerHeightConstraint = make.height.equalTo(0).constraint
        }
        // No associated tab in placeholder mode. WebContentHeader's
        // isInPlaceholderMode-aware bindings (installed in Task D) clear
        // displayed URL, hide nav buttons, hide chat button.
        headerView.currentTab = nil

        leftContainerView.addSubview(hostView)
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(headerView.snp.bottom)
        }

        updateHeaderVisibility()
    }

    /// Adapts to layout-mode preference changes (.performance ↔ .balanced
    /// ↔ .comfortable) while in placeholder mode.
    private func observeLayoutMode() {
        layoutObserverCancellable =
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateHeaderVisibility()
                }

        sidebarCollapsedObserverCancellable =
            browserState?.sidebarCollapsedPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateContentLeadingInset()
                }
    }

    private var contentLeadingInset: CGFloat {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let sidebarCollapsed = browserState?.sidebarCollapsed ?? true
        return (traditionalLayout || sidebarCollapsed)
            ? WebContentConstant.edgesSpacing
            : 0
    }

    private func updateContentLeadingInset() {
        leftContainerLeadingConstraint?.update(inset: contentLeadingInset)
    }

    private func updateHeaderVisibility() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let traditionalLayout = layoutMode.isTraditional

        if traditionalLayout || navigationAtTop {
            headerView.isHidden = false
            headerHeightConstraint?.update(offset: WebContentConstant.headerHeight)
        } else {
            // .performance — address bar lives in the sidebar; hide the
            // shell's header (would otherwise duplicate the sidebar address).
            headerView.isHidden = true
            headerHeightConstraint?.update(offset: 0)
        }

        updateContentLeadingInset()
    }

    /// Mount the placeholder WebContents NSView into hostView via Auto
    /// Layout constraints. CRITICAL: addSubview FIRST, then
    /// translatesAutoresizingMaskIntoConstraints = false, then snp
    /// constraints. This ordering matches the original shell implementation
    /// (which rendered dino correctly). Using
    /// translatesAutoresizingMaskIntoConstraints = true + manual frame
    /// (the WCVC.addWebContentView path) empirically does NOT trigger the
    /// Chromium WebContentsViewCocoa renderer for out-of-band WebContents
    /// — see spec §3.
    @MainActor
    func mountPlaceholderNativeView(_ nsView: NSView) {
        if nsView.superview !== hostView {
            nsView.removeFromSuperview()
            hostView.addSubview(nsView)
            nsView.translatesAutoresizingMaskIntoConstraints = false
            nsView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        } else {
            hostView.addSubview(nsView, positioned: .above, relativeTo: nil)
        }
    }

    /// Remove all subviews from hostView SYNCHRONOUSLY. Called before
    /// Chromium's placeholder_web_contents_.reset() destroys the underlying
    /// NSView (the AppKit hierarchy must release the dangling pointer
    /// before that happens — see spec §9.1 UAF contract).
    @MainActor
    func unmountPlaceholderNativeView() {
        for subview in hostView.subviews {
            subview.removeFromSuperview()
        }
    }
}
