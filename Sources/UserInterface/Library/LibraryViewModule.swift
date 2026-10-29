// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import PostHog
import SwiftUI

/// Owns Library navigation and content independently of its window presentation.
final class LibraryViewModule: NSViewController {
    enum Presentation {
        case embedded, standalone
    }

    enum Section: Int, CaseIterable {
        /// Mirage's Folio library page, hosted in the pane as the window's
        /// off-strip pane tab (`BrowserState.libraryPaneTab`).
        case folio
        case spaces, downloads

        var analyticsName: String {
            switch self {
            case .folio: return "folio"
            case .spaces: return "spaces"
            case .downloads: return "downloads"
            }
        }

        var title: String {
            switch self {
            case .downloads:
                return NSLocalizedString("library.navigation.downloads", value: "Downloads", comment: "Library - Downloads category")
            case .spaces:
                return NSLocalizedString("library.navigation.spaces", value: "Spaces", comment: "Library - Spaces category")
            case .folio:
                return NSLocalizedString("library.navigation.folio", value: "Folio", comment: "Library - Saved content category")
            }
        }

        var symbol: String {
            switch self {
            case .downloads: return "arrow.down.circle"
            case .spaces: return "square.stack.3d.up"
            case .folio: return "book"
            }
        }
    }

    static var title: String {
        NSLocalizedString("library.navigation.title", value: "Library", comment: "Library - Title and entry button label")
    }

    @Observable
    final class NavigationState {
        var selection: Section = .downloads
        var sidebarCollapsed = false
    }

    let navigationState = NavigationState()
    private let browserState: BrowserState
    private let presentation: Presentation
    private let downloadsManager = DownloadsManager(profileIds: [])
    private var findShortcutMonitor: Any?
    var onDismiss: (() -> Void)?

    init(browserState: BrowserState, presentation: Presentation = .embedded) {
        self.browserState = browserState
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let findShortcutMonitor { NSEvent.removeMonitor(findShortcutMonitor) }
    }

    override var acceptsFirstResponder: Bool { presentation == .standalone }

    override func mouseDown(with event: NSEvent) {
        guard presentation == .standalone else {
            super.mouseDown(with: event)
            return
        }
        // Unhandled blank-area clicks must end editing without closing Library.
        view.window?.makeFirstResponder(self)
    }

    override func loadView() {
        let content = LibraryContentView(navigationState: navigationState, openInNewWindow: { [weak self] in
            guard let self else { return }
            let owner = SpaceSessionControllersManager.shared.controller(for: browserState.windowId)
            owner?.openLibraryInNewWindow(section: self.navigationState.selection)
        }, browserState: browserState, presentation: presentation,
                                         downloadsManager: downloadsManager) { [weak self] in
            self?.onDismiss?()
        }
        let host = ThemedHostingController(rootView: content, themeSource: browserState.themeContext)
        addChild(host)
        view = host.view
        findShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.navigationState.selection == .spaces,
                  let window = self.viewIfLoaded?.window, window.isVisible,
                  event.window === window,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else { return event }
            // Spaces has no search; keep Find from reaching the browser behind Library.
            return nil
        }
    }
}

private struct LibraryContentView: View {
    let navigationState: LibraryViewModule.NavigationState
    let openInNewWindow: () -> Void
    let browserState: BrowserState
    let presentation: LibraryViewModule.Presentation
    let downloadsManager: DownloadsManager
    let dismiss: () -> Void
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selection: LibraryViewModule.Section {
        get { navigationState.selection }
        nonmutating set { navigationState.selection = newValue }
    }
    @State private var selectionAnimationTriggers: [LibraryViewModule.Section: Int] = [:]
    @State private var hoveredSection: LibraryViewModule.Section?
    @State private var folioAvailable = SaveForLaterService.featureEnabled
    @State private var sidebarWidth: CGFloat = Self.minimumSidebarWidth
    private var compactSidebar: Bool { sidebarWidth < Self.compactSidebarThreshold }
    @State private var floatingSidebarVisible = false
    @State private var hoveringFloatingSidebar = false

    private static let minimumSidebarWidth: CGFloat = 80
    private static let maximumSidebarWidth: CGFloat = 240
    private static let compactSidebarThreshold: CGFloat = 108
    private static let titlebarClearance: CGFloat = 32

    private func color(_ value: ThemedColor) -> Color {
        value.swiftUIColor(theme: theme, appearance: appearance)
    }

    var body: some View {
        Group {
            if presentation == .standalone {
                HSplitView {
                    if !navigationState.sidebarCollapsed {
                        navigation(compact: compactSidebar)
                            .ignoresSafeArea(.container, edges: .top)
                            .frame(minWidth: Self.minimumSidebarWidth, idealWidth: sidebarWidth, maxWidth: Self.maximumSidebarWidth)
                            .background(LibrarySidebarPosition(width: sidebarWidth))
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.width
                            } action: { width in
                                guard !navigationState.sidebarCollapsed, width >= Self.minimumSidebarWidth else { return }
                                sidebarWidth = min(width, Self.maximumSidebarWidth)
                            }
                    }
                    // Keep the detail in place when the sidebar is removed so its
                    // search, reader, and internal split state survive collapsing.
                    content
                        .ignoresSafeArea(.container, edges: .top)
                        .layoutPriority(1)
                }
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .leading) {
                    if navigationState.sidebarCollapsed {
                        floatingSidebar
                    }
                }
                .background(color(.windowBackground.withAlphaComponent(1)))
            } else {
                HStack(spacing: 0) {
                    navigation(compact: false)
                        .frame(width: 136)
                    Rectangle()
                        .fill(color(.separator))
                        .frame(width: 1)
                    content
                }
                .background(color(.windowBackground.withAlphaComponent(1)))
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(color(.border), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .themedForeground(.textPrimary)
        .tint(color(.themeColor))
        .task(id: selection) {
            folioAvailable = SaveForLaterService.featureEnabled
            if selection == .folio, !folioAvailable {
                // Folio went away under a stale selection: fall back.
                selection = .downloads
                return
            }
            PostHogSDK.shared.capture("library_section_viewed", properties: [
                "section": selection.analyticsName,
                "is_standalone_window": presentation == .standalone,
            ])
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if selection == .downloads {
                AllDownloadsListView(downloadsManager: downloadsManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selection == .folio {
                LibraryFolioPane(browserState: browserState,
                                 staysOpen: presentation == .standalone,
                                 dismiss: dismiss)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Keep the page below the window controls, as the Spaces cards are.
                    .padding(.top, presentation == .standalone ? Self.titlebarClearance : 0)
            } else {
                LibrarySpacesView(browserState: browserState)
                    // Keep standalone cards below the window controls in both sidebar states.
                    .padding(.top, presentation == .standalone ? Self.titlebarClearance : 0)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            color(.contentOverlayBackground)
        }
        .clipped()
    }

    private var floatingSidebar: some View {
        Color.clear
            .frame(width: floatingSidebarVisible ? sidebarWidth + 10 : 15)
            .contentShape(.rect)
            .overlay(alignment: .leading) {
                if floatingSidebarVisible {
                    navigation(compact: compactSidebar, floating: true)
                        .frame(width: sidebarWidth)
                        .clipShape(.rect(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(color(.border), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 2, y: 2)
                        .padding(.leading, 5)
                        .padding(.top, Self.titlebarClearance)
                        .padding(.bottom, 5)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.sidebarReveal")
            .onHover { hovering in
                hoveringFloatingSidebar = hovering
                if hovering {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        floatingSidebarVisible = true
                    }
                }
            }
            .task(id: hoveringFloatingSidebar) {
                guard !hoveringFloatingSidebar else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.15)) {
                    floatingSidebarVisible = false
                }
            }
            .onDisappear {
                hoveringFloatingSidebar = false
                floatingSidebarVisible = false
            }
    }

    private func navigation(compact: Bool, floating: Bool = false) -> some View {
        VStack(spacing: 12) {
            ForEach(LibraryViewModule.Section.allCases.filter { $0 != .folio || folioAvailable }, id: \.self) { section in
                Button {
                    selectionAnimationTriggers[section, default: 0] += 1
                    selection = section
                } label: {
                    VStack(spacing: 9) {
                        Image(systemName: section.symbol)
                            .font(.system(size: compact ? 22 : 25, weight: .regular))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(color(.themeColor))
                            .symbolEffect(.bounce, options: .speed(1.6),
                                          value: reduceMotion ? 0 : selectionAnimationTriggers[section, default: 0])
                        if !compact {
                            Text(section.title)
                                .foregroundStyle(color(.textPrimary))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, compact ? 0 : 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 48 : 88)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selection == section
                                  ? color(.themeColor).opacity(appearance.isDark ? 0.22 : 0.12)
                                  : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(color(.hover).opacity(hoveredSection == section ? 1 : 0))
                            }
                    }
                    .contentShape(.rect)
                    .scaleEffect(!reduceMotion && hoveredSection == section ? 1.025 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredSection == section)
                }
                .buttonStyle(.plain)
                .help(section.title)
                .accessibilityLabel(section.title)
                .onHover { hovering in
                    if hovering {
                        hoveredSection = section
                    } else if hoveredSection == section {
                        hoveredSection = nil
                    }
                }
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 24)
        .frame(minWidth: Self.minimumSidebarWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .bottom) {
            sidebarButton(floating: floating)
                .padding(.bottom, 16)
        }
        .background(color(.windowBackground.withAlphaComponent(1)))
        .onHover { if !$0 { hoveredSection = nil } }
        .onDisappear { hoveredSection = nil }
    }

    private func sidebarButton(floating: Bool) -> some View {
        let title = presentation == .embedded
            ? NSLocalizedString("library.navigation.openInNewWindow", value: "Open Library in New Window", comment: "Profile menu - Opens Library in a separate window")
            : floating
                ? NSLocalizedString("library.navigation.showSidebar", value: "Show Sidebar", comment: "Library - Tooltip and accessibility label for expanding the navigation sidebar")
                : NSLocalizedString("library.navigation.hideSidebar", value: "Hide Sidebar", comment: "Library - Tooltip and accessibility label for collapsing the navigation sidebar")
        return Button {
            if presentation == .embedded {
                openInNewWindow()
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    navigationState.sidebarCollapsed = !floating
                }
            }
        } label: {
            Image(systemName: presentation == .embedded ? "arrow.up.forward.square" : "sidebar.left")
                .font(.system(size: 17))
                .foregroundStyle(color(.themeColor))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(presentation == .embedded ? "library.openInNewWindow" : floating ? "library.showSidebar" : "library.hideSidebar")
    }
}

/// The Folio pane: Mirage's library page, a Chromium tab of the Library's
/// window that the Library hosts off the strip (`BrowserState.libraryPaneTab`).
/// The pane asks for the tab when it enters a window and closes it when it
/// leaves one — a section switch, the overlay's dismissal or the standalone
/// window closing — so the page lives exactly as long as it is on screen.
private struct LibraryFolioPane: NSViewRepresentable {
    let browserState: BrowserState
    /// Whether the Library stays on screen after yielding (the standalone
    /// window does; the attached panel dismisses), so the pane asks for a
    /// fresh library page in place of the one that left for the strip.
    let staysOpen: Bool
    /// The Library yields to its browser window: a link followed inside the
    /// page adopted the tab into the strip, which now shows that page.
    let dismiss: () -> Void

    func makeNSView(context: Context) -> LibraryFolioPaneHostView {
        LibraryFolioPaneHostView(browserState: browserState, staysOpen: staysOpen, dismiss: dismiss)
    }

    func updateNSView(_ view: LibraryFolioPaneHostView, context: Context) {}

    static func dismantleNSView(_ view: LibraryFolioPaneHostView, coordinator: ()) {
        view.unmount()
    }
}

/// Hosts the pane tab's native view edge to edge. A Chromium web view mounted
/// outside the browser window's page container draws itself, in whichever
/// window it is in — the attached Library panel or the standalone Library
/// window — as Peek's and Reader's do.
final class LibraryFolioPaneHostView: NSView {
    private weak var browserState: BrowserState?
    private let staysOpen: Bool
    private let dismiss: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private weak var hostedTab: Tab?
    private weak var hostedWebView: NSView?

    init(browserState: BrowserState, staysOpen: Bool, dismiss: @escaping () -> Void) {
        self.browserState = browserState
        self.staysOpen = staysOpen
        self.dismiss = dismiss
        super.init(frame: .zero)
        wantsLayer = true
        // Synchronous on purpose: `libraryPaneTabWillBeRemoved` runs inside
        // Chromium's close turn, and the view must leave before the
        // WebContents is destroyed.
        browserState.$libraryPaneTab
            .sink { [weak self] tab in self?.host(tab) }
            .store(in: &subscriptions)
        browserState.libraryPaneTabAdopted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.dismiss()
                if self.staysOpen, self.window != nil {
                    self.browserState?.requestLibraryPaneTab()
                }
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let browserState else { return }
        if window == nil {
            unmount()
            return
        }
        host(browserState.libraryPaneTab)
        browserState.requestLibraryPaneTab()
    }

    /// Leaves the window's pane tab: detaches the page and closes the tab.
    func unmount() {
        detachHostedWebView()
        browserState?.closeLibraryPane()
    }

    private func host(_ tab: Tab?) {
        guard let window else { return }
        if let tab, tab === hostedTab, hostedWebView?.superview === self { return }
        detachHostedWebView()
        guard let tab else { return }
        guard let webView = tab.webContentView else {
            // Without a native view there is nothing to host — show the page
            // as a tab instead of an empty pane. Deferred: this runs inside
            // the publish of `libraryPaneTab`, before the value is stored.
            AppLogWarn("📚 [LibraryPane] tab \(tab.guid) has no webContentView — expanding into a tab")
            DispatchQueue.main.async { [weak browserState] in
                browserState?.expandLibraryPaneIntoTab()
            }
            return
        }
        hostedTab = tab
        hostedWebView = webView
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        if window.isKeyWindow {
            window.makeFirstResponder(webView)
            tab.webContentWrapper?.focus()
        }
    }

    private func detachHostedWebView() {
        if let hostedWebView, hostedWebView.superview === self {
            hostedWebView.removeFromSuperview()
        }
        hostedWebView = nil
        hostedTab = nil
    }
}

/// HSplitView has no divider-position binding. Restore the saved width once when
/// the sidebar is inserted, then leave subsequent divider dragging to SwiftUI.
private struct LibrarySidebarPosition: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> Anchor { Anchor(width: width) }
    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        private let width: CGFloat

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView {
                        guard split.arrangedSubviews.count == 2 else { return }
                        split.setPosition(self.width, ofDividerAt: 0)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
