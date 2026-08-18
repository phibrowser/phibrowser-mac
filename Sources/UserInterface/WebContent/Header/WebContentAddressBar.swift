// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

final class WebContentAddressBarViewModel: ObservableObject {
    @Published var displayText: String = ""
    @Published var addressBarWidth: CGFloat = 0
    @Published var isInPlaceholderMode: Bool = false
    /// Whether the reader affordance applies to this tab. Mirrors
    /// `Tab.isReaderOfferable`: a matching site rule, or Mozilla's
    /// readerability heuristic passing in the live page.
    @Published var isReaderApplicable: Bool = false
    @Published var isReaderViewActive: Bool = false

    private weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()
    private var lastMeasuredWidth: CGFloat = 0

    init(browserState: BrowserState?, currentTab: Tab?) {
        self.browserState = browserState
        bind(currentTab: currentTab)
    }

    func bind(currentTab: Tab?) {
        cancellables.removeAll()

        // Placeholder-mode sink: blank text on enter, restore on exit. Lives
        // outside the `guard let tab` so it stays subscribed even when the
        // shell sets currentTab=nil.
        if let browserState {
            browserState.$isInPlaceholderMode
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isPlaceholder in
                    guard let self else { return }
                    self.isInPlaceholderMode = isPlaceholder
                    if isPlaceholder {
                        self.displayText = ""
                    } else if let url = currentTab?.url {
                        let alwaysShowURLPath = PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue()
                        self.displayText = self.formattedDisplayText(urlString: url, alwaysShowURLPath: alwaysShowURLPath)
                    } else {
                        self.displayText = ""
                    }
                }
                .store(in: &cancellables)
        }

        guard let tab = currentTab else {
            displayText = ""
            isReaderApplicable = false
            isReaderViewActive = false
            return
        }

        tab.$isReaderOfferable
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: \.isReaderApplicable, on: self)
            .store(in: &cancellables)

        // "In the reader" is the Phi Reader extension's page being shown in
        // the tab; the extension reports it over the bridge.
        tab.$extensionReaderActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: \.isReaderViewActive, on: self)
            .store(in: &cancellables)

        let alwaysShowURLPathPublisher = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in
                PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue()
            }
            .prepend(PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue())
            .removeDuplicates()

        let overviewActivePublisher = browserState?.$groupOverviewState
            .map { $0 != nil }
            .prepend(browserState?.groupOverviewState != nil)
            .removeDuplicates()
            .eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()

        tab.$url
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .combineLatest(alwaysShowURLPathPublisher, overviewActivePublisher)
            .map { [weak self] urlString, alwaysShowURLPath, overviewActive in
                guard !overviewActive else { return "" }
                return self?.formattedDisplayText(urlString: urlString ?? "", alwaysShowURLPath: alwaysShowURLPath) ?? ""
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                // Skip writes during placeholder mode so the placeholder sink
                // (which blanks displayText) is not raced by a stale URL update.
                guard self?.browserState?.isInPlaceholderMode != true else { return }
                self?.displayText = text
            }
            .store(in: &cancellables)
    }

    private func formattedDisplayText(urlString: String, alwaysShowURLPath: Bool) -> String {
        guard !urlString.isEmpty else {
            return ""
        }
        guard !urlString.isNTP else {
            return ""
        }
        if alwaysShowURLPath {
            return removingTrailingSlashIfNeeded(from: displayURLWithoutScheme(urlString))
        }
        return removingTrailingSlashIfNeeded(from: URLProcessor.displayName(for: urlString))
    }

    private func displayURLWithoutScheme(_ urlString: String) -> String {
        let brandedURL = URLProcessor.phiBrandEnsuredUrlString(urlString)
        if let components = URLComponents(string: brandedURL),
           let host = components.host {
            let displayHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let portSuffix = components.port.map { ":\($0)" } ?? ""
            let path = components.percentEncodedPath
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""
            return "\(displayHost)\(portSuffix)\(path)\(query)\(fragment)"
        }
        if let range = brandedURL.range(of: "://") {
            let withoutScheme = String(brandedURL[range.upperBound...])
            if withoutScheme.hasPrefix("www.") {
                return String(withoutScheme.dropFirst(4))
            }
            return withoutScheme
        }
        return brandedURL
    }

    private func removingTrailingSlashIfNeeded(from text: String) -> String {
        guard text.count > 1 else {
            return text
        }
        var result = text
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    func updateWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        if abs(width - lastMeasuredWidth) < 0.5 { return }
        lastMeasuredWidth = width
        addressBarWidth = width
    }
}

struct AddressBarAnchorView: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }
}

struct WebContentAddressBarView: View {
    private let browserState: BrowserState?
    private let currentTab: Tab?
    private let showBackgroundWhenInactive: Bool
    private let loadingProgress: Double
    private let isLoading: Bool
    private let isProgressVisible: Bool
    private let onOpenLocationBar: (NSView?) -> Void

    @StateObject private var viewModel: WebContentAddressBarViewModel
    @State private var isHovering = false
    @State private var anchorView: NSView?
    @State private var isMenuShown = false
    @State private var menuAnchorView: NSView?
    @State private var showCopyConfirmation = false
    @StateObject private var lottieState = LottieAnimationViewState()
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private let onAnchorResolved: ((NSView?) -> Void)?

    init(
        browserState: BrowserState?,
        currentTab: Tab?,
        showBackgroundWhenInactive: Bool,
        loadingProgress: Double,
        isLoading: Bool,
        isProgressVisible: Bool = false,
        onOpenLocationBar: @escaping (NSView?) -> Void,
        onAnchorResolved: ((NSView?) -> Void)? = nil
    ) {
        self.browserState = browserState
        self.currentTab = currentTab
        self.showBackgroundWhenInactive = showBackgroundWhenInactive
        self.loadingProgress = loadingProgress
        self.isLoading = isLoading
        self.isProgressVisible = isProgressVisible
        self.onOpenLocationBar = onOpenLocationBar
        self.onAnchorResolved = onAnchorResolved
        _viewModel = StateObject(wrappedValue: WebContentAddressBarViewModel(
            browserState: browserState,
            currentTab: currentTab
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenLocationBar(anchorView)
                }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(displayText)
                        .font(.system(size: 13))
                        .foregroundColor(displayTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                if !viewModel.isInPlaceholderMode {
                    HStack(spacing: 2) {
                        readerButton
                        copyURLButton
                        menuButton
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 0)

        }
        .frame(height: 26)
        .background(progressBackgroundInline)
        .background(backgroundShape)
        .background(anchorBackground)
        .overlay(alignment: .bottom) {
            AddressBarProgressBarView(
                progress: effectiveLoadingProgress,
                isVisible: isProgressVisible
            )
            .frame(height: 1)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .background(widthReader)
        .onChange(of: currentTab?.guid) { _, _ in
            viewModel.bind(currentTab: currentTab)
        }
        .clipShape(Capsule())
    }

    private var backgroundShape: some View {
        // Placeholder mode shows the inactive background so users can spot
        // the address bar without hovering — it'd otherwise be a blank patch.
        let baseColor = (showBackgroundWhenInactive || viewModel.isInPlaceholderMode)
            ? Color(.sidebarTabHovered)
            : ThemedColor.windowBackground.swiftUIColor(theme: theme, appearance: appearance)
        let hoverColor = Color(.sidebarTabHoveredColorEmphasized)
        let shouldHighlight = isHovering || isMenuShown
        return Capsule()
            .fill(shouldHighlight ? hoverColor : baseColor)
    }

    /// Progress background rendered in `.background()` so it never changes layout.
    private var progressBackgroundInline: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let clampedProgress = min(max(effectiveLoadingProgress, 0), 1)
            let baseColor = ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
            let backgroundLead: CGFloat = 100
            let progressWidth = totalWidth * clampedProgress
            let backgroundWidth = min(totalWidth, progressWidth + backgroundLead)

            if isProgressVisible && clampedProgress > 0 && totalWidth > 0 {
                LinearGradient(
                    stops: [
                        .init(color: baseColor.opacity(0.0), location: 0),
                        .init(color: baseColor.opacity(0.2), location: 0.8),
                        .init(color: baseColor.opacity(0.0), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: backgroundWidth, height: proxy.size.height)
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.2), value: clampedProgress)
            }
        }
        .allowsHitTesting(false)
    }

    private var displayText: String {
        if viewModel.isInPlaceholderMode {
            return NSLocalizedString("browser.webContentAddressBar.emptyWindowPlaceholder", value: "Search or Enter URL", comment: "Web content address bar - Placeholder text shown when window has no tab")
        }
        if viewModel.displayText.isEmpty {
            return ""
        }
        return viewModel.displayText
    }

    private var displayTextColor: Color {
        if viewModel.isInPlaceholderMode {
            // Match SideAddressBar's placeholder text — system standard placeholder
            // color is weaker than textSecondary and signals "fill me in" affordance.
            return Color(NSColor.placeholderTextColor)
        }
        return viewModel.displayText.isEmpty
            ? ThemedColor.textSecondary.swiftUIColor(theme: theme, appearance: appearance)
            : ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)
    }

    private var isNTP: Bool {
        currentTab?.isNTP == true
    }

    private var effectiveLoadingProgress: Double {
        if isNTP || !isLoading {
            return 0
        }
        return loadingProgress
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: AddressBarWidthPreferenceKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(AddressBarWidthPreferenceKey.self) { width in
            viewModel.updateWidth(width)
        }
    }

    private var anchorBackground: some View {
        AddressBarAnchorView { view in
            anchorView = view
            onAnchorResolved?(view)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var readerButton: some View {
        if viewModel.isReaderApplicable {
            ReaderButtonView(
                isActive: viewModel.isReaderViewActive,
                isAddressBarHovering: isHovering,
                isMenuShown: isMenuShown,
                action: {
                    anchorView?.window?.customTooltipController.dismissAll()
                    guard let tab = currentTab else { return }
                    browserState?.toggleReaderView(for: tab, from: .addressBar)
                }
            )
            .customTooltip {
                CommandShortcutTooltipContent(
                    title: NSLocalizedString("browser.webContentAddressBar.readerViewTooltip", value: "Reader View", comment: "Reader View shortcut tooltip title in the address bar"),
                    command: .PHI_TOGGLE_READER
                )
            }
        }
    }

    @ViewBuilder
    private var copyURLButton: some View {
        CopyURLButtonView(
            currentTab: currentTab,
            showCopyConfirmation: $showCopyConfirmation,
            isAddressBarHovering: isHovering,
            isMenuShown: isMenuShown,
            dismissTooltip: {
                anchorView?.window?.customTooltipController.dismissAll()
            }
        )
        .customTooltip {
            CommandShortcutTooltipContent(
                title: NSLocalizedString("browser.webContentAddressBar.copyURLTooltip", value: "Copy URL", comment: "Copy URL shortcut tooltip title"),
                command: .PHI_COPY_URL
            )
        }
    }

    private var menuButton: some View {
        let config = LottieAnimationViewConfig(
            animationName: "extension-button",
            size: CGSize(width: 22, height: 22),
            hoverBackgroundColor: Color(.sidebarTabHovered),
            cornerRadius: 999,
            animationTrigger: .onHoverEnter,
            themedTintColor: .textPrimary,
            reverseOnHoverExit: true
        )

        return ZStack {
            Circle()
                .fill(Color(.sidebarTabHovered))
                .frame(width: 24, height: 24)
                .opacity(isMenuShown ? 1 : 0)

            LottieAnimationView(config: config, state: lottieState) {
                presentAddressBarMenu()
            }
            .background(
                AddressBarAnchorView { view in
                    menuAnchorView = view
                }
                .allowsHitTesting(false)
            )
        }
        .frame(width: 24, height: 24)
        .opacity((isHovering || isMenuShown) ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering || isMenuShown)
    }

    private func presentAddressBarMenu() {
        WebContentAddressBarMenuPresenter.present(
            browserState: browserState,
            currentTab: currentTab,
            anchorView: menuAnchorView
        ) { isPresented in
            isMenuShown = isPresented
        }
    }

}

/// Address-bar affordance for Reader View.
///
/// Hover-gated like `CopyURLButtonView`, except it stays visible while Reader
/// View is on so the selected state doesn't disappear with the pointer.
private struct ReaderButtonView: View {
    let isActive: Bool
    let isAddressBarHovering: Bool
    let isMenuShown: Bool
    let action: () -> Void

    @State private var isButtonHovering = false
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(.sidebarTabHovered))
                    .frame(width: 24, height: 24)
                    .opacity((isButtonHovering || isActive) ? 1 : 0)

                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        ThemedColor.textPrimary.swiftUIColor(theme: theme,
                                                             appearance: appearance))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .onHover { hovering in
            isButtonHovering = hovering
        }
        .opacity((isAddressBarHovering || isMenuShown || isActive) ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isAddressBarHovering || isMenuShown)
        .animation(.easeInOut(duration: 0.15), value: isButtonHovering)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

private struct CopyURLButtonView: View {
    let currentTab: Tab?
    @Binding var showCopyConfirmation: Bool
    let isAddressBarHovering: Bool
    let isMenuShown: Bool
    let dismissTooltip: () -> Void

    @State private var isButtonHovering = false
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        let iconName = showCopyConfirmation ? "checkmark" : "link"
        let iconColor = showCopyConfirmation
            ? ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)
            : ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)

        Button {
            dismissTooltip()
            guard let urlString = currentTab?.url, !urlString.isEmpty else { return }
            let branded = URLProcessor.phiBrandEnsuredUrlString(urlString)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branded, forType: .string)
            showCopyConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showCopyConfirmation = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.sidebarTabHovered))
                    .frame(width: 24, height: 24)
                    .opacity(isButtonHovering ? 1 : 0)

                Image(systemName: iconName)
                    .contentTransition(.symbolEffect(.replace, options: .speed(3)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .onHover { hovering in
            isButtonHovering = hovering
        }
        .opacity((isAddressBarHovering || isMenuShown) ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isAddressBarHovering || isMenuShown)
        .animation(.easeInOut(duration: 0.15), value: isButtonHovering)
    }
}

private struct AddressBarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AddressBarProgressBarView: View {
    let progress: Double
    let isVisible: Bool
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let clampedProgress = min(max(progress, 0), 1)
            let progressWidth = width * clampedProgress
            let baseColor = ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
            let backgroundColor = ThemedColor.windowBackground.swiftUIColor(theme: theme, appearance: appearance)
            let fadeStart: Double = 0.3
            let fadeRange: Double = 0.2
            let gradientOpacity = max(0, min(1, (clampedProgress - fadeStart) / fadeRange))

            ZStack(alignment: .leading) {
                if isVisible && clampedProgress > 0 {
                    Capsule()
                        .fill(baseColor)
                        .frame(width: progressWidth, height: height)
                        .opacity(1 - gradientOpacity)

                    LinearGradient(
                        colors: [backgroundColor, baseColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: progressWidth, height: height)
                    .clipShape(Capsule())
                    .opacity(gradientOpacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: clampedProgress)
        }
    }
}

#if DEBUG
#Preview("AddressBar Progress States") {
    VStack(spacing: 12) {
        WebContentAddressBarView(
            browserState: nil,
            currentTab: nil,
            showBackgroundWhenInactive: false,
            loadingProgress: 0.1,
            isLoading: true,
            onOpenLocationBar: { _ in }
        )
        .frame(height: 26)

        WebContentAddressBarView(
            browserState: nil,
            currentTab: nil,
            showBackgroundWhenInactive: false,
            loadingProgress: 0.6,
            isLoading: true,
            onOpenLocationBar: { _ in }
        )
        .frame(height: 26)

        WebContentAddressBarView(
            browserState: nil,
            currentTab: nil,
            showBackgroundWhenInactive: false,
            loadingProgress: 0.9,
            isLoading: true,
            onOpenLocationBar: { _ in }
        )
        .frame(height: 26)

        WebContentAddressBarView(
            browserState: nil,
            currentTab: nil,
            showBackgroundWhenInactive: false,
            loadingProgress: 1.0,
            isLoading: false,
            onOpenLocationBar: { _ in }
        )
        .frame(height: 26)
    }
    .padding()
}
#endif
