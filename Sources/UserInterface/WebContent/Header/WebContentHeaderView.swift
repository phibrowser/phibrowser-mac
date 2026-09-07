// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

struct WebContentHeaderView: View {
    @ObservedObject var state: WebContentHeaderState
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    var currentTab: Tab?
    var browserState: BrowserState?

    let onSidebarTap: () -> Void
    let onBackTap: () -> Void
    let onForwardTap: () -> Void
    let onRefreshTap: () -> Void
    let onStopLoadingTap: () -> Void
    let onChatTap: () -> Void
    let onFeedbackTap: () -> Void
    let onMemoryTap: () -> Void
    let onDownloadTap: () -> Void
    let onOpenLocationBar: (NSView?) -> Void
    var onAnchorResolved: ((NSView?) -> Void)?
    var onSidebarAnchorResolved: ((NSView?) -> Void)?
    var onChatAnchorResolved: ((NSView?) -> Void)?

    @State private var extensionsModel: WebContentHeaderExtensionsModel
    @State private var isExtensionPopoverShown = false
    @State private var totalHeaderWidth: CGFloat = 10000
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    init(
        state: WebContentHeaderState,
        downloadViewModel: DownloadButtonViewModel,
        currentTab: Tab?,
        browserState: BrowserState?,
        onSidebarTap: @escaping () -> Void,
        onBackTap: @escaping () -> Void,
        onForwardTap: @escaping () -> Void,
        onRefreshTap: @escaping () -> Void,
        onStopLoadingTap: @escaping () -> Void,
        onChatTap: @escaping () -> Void,
        onFeedbackTap: @escaping () -> Void,
        onMemoryTap: @escaping () -> Void = {},
        onDownloadTap: @escaping () -> Void = {},
        onOpenLocationBar: @escaping (NSView?) -> Void,
        onAnchorResolved: ((NSView?) -> Void)? = nil,
        onSidebarAnchorResolved: ((NSView?) -> Void)? = nil,
        onChatAnchorResolved: ((NSView?) -> Void)? = nil
    ) {
        self.state = state
        self.downloadViewModel = downloadViewModel
        self.currentTab = currentTab
        self.browserState = browserState
        self.onSidebarTap = onSidebarTap
        self.onBackTap = onBackTap
        self.onForwardTap = onForwardTap
        self.onRefreshTap = onRefreshTap
        self.onStopLoadingTap = onStopLoadingTap
        self.onChatTap = onChatTap
        self.onFeedbackTap = onFeedbackTap
        self.onMemoryTap = onMemoryTap
        self.onDownloadTap = onDownloadTap
        self.onOpenLocationBar = onOpenLocationBar
        self.onAnchorResolved = onAnchorResolved
        self.onSidebarAnchorResolved = onSidebarAnchorResolved
        self.onChatAnchorResolved = onChatAnchorResolved
        _extensionsModel = State(wrappedValue: WebContentHeaderExtensionsModel(browserState: browserState))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 0) {
                leadingButtons
                    .padding(.leading, state.isInPlaceholderMode ? 8 : 16)

                if state.showAddressBar {
                    WebContentAddressBarView(
                        browserState: browserState,
                        currentTab: currentTab,
                        showBackgroundWhenInactive: false,
                        loadingProgress: state.loadingProgress,
                        isLoading: state.isLoading,
                        isProgressVisible: state.isProgressVisible,
                        backgroundColor: state.pageBackgroundColor.map { Color(nsColor: $0) },
                        onOpenLocationBar: onOpenLocationBar,
                        onAnchorResolved: onAnchorResolved
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .layoutPriority(1)
                }

                Spacer(minLength: 0)

                HeaderTrailingArea(
                    availableWidth: max(0, totalHeaderWidth - leadingButtonsWidth - addressBarReservedWidth),
                    pinnedExtensions: extensionsModel.visiblePinnedExtensions,
                    showDownload: state.showDownloadButton,
                    showMemory: state.showMemoryButton,
                    showFeedback: state.showFeedbackButton,
                    feedbackIconOnly: state.isFeedbackIconOnly,
                    showChat: state.showChatButton,
                    isInPlaceholderMode: state.isInPlaceholderMode,
                    extensionManager: browserState?.extensionManager,
                    browserState: browserState,
                    downloadViewModel: downloadViewModel,
                    isDownloadPopoverShown: $state.isDownloadPopoverShown,
                    isExtensionPopoverShown: $isExtensionPopoverShown,
                    onFeedbackTap: onFeedbackTap,
                    onChatTap: onChatTap,
                    onMemoryTap: onMemoryTap,
                    onDownloadTap: onDownloadTap,
                    onChatAnchorResolved: onChatAnchorResolved
                )
                .frame(height: HeaderTrailingLayout.rowHeight)
                .layoutPriority(2)
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newValue in
                totalHeaderWidth = newValue
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .environment(\.phiAppearance, state.pageAppearance ?? appearance)
        .environment(\.colorScheme, state.pageAppearance.map { $0.isDark ? .dark : .light } ?? colorScheme)
    }

    private var leadingButtonsWidth: CGFloat {
        var count = 0
        if state.showSidebarButton { count += 1 }
        if state.showNavigationButtons { count += 3 }
        let buttonsWidth: CGFloat = count > 0
            ? CGFloat(count) * 24 + CGFloat(count - 1) * 8
            : 0
        let leadingPadding: CGFloat = state.isInPlaceholderMode ? 8 : 16
        return leadingPadding + buttonsWidth
    }

    /// Minimum width reserved for the address bar so trailing area doesn't over-expand
    private var addressBarReservedWidth: CGFloat {
        state.showAddressBar ? 200 : 0
    }

    // MARK: - Leading Buttons

    @ViewBuilder
    private var leadingButtons: some View {
        HStack(spacing: 8) {
            if state.showSidebarButton {
                NavigationButton(
                    systemName: "sidebar.left",
                    accessibilityLabel: NSLocalizedString("browser.webContentHeader.sidebarButton.accessibilityLabel", value: "Toggle Sidebar", comment: "Web content header - Accessibility description for sidebar toggle button"),
                    onAnchorResolved: onSidebarAnchorResolved,
                    action: onSidebarTap
                )
            }

            if state.showNavigationButtons {
                NavigationButton(
                    systemName: "chevron.left",
                    isEnabled: state.canGoBack,
                    accessibilityLabel: NSLocalizedString("browser.webContentHeader.backButton.accessibilityLabel", value: "Back", comment: "Web content header - Accessibility description for back navigation button"),
                    action: onBackTap
                )

                NavigationButton(
                    systemName: "chevron.right",
                    isEnabled: state.canGoForward,
                    accessibilityLabel: NSLocalizedString("browser.webContentHeader.forwardButton.accessibilityLabel", value: "Forward", comment: "Web content header - Accessibility description for forward navigation button"),
                    action: onForwardTap
                )

                RefreshStopNavigationButton(
                    isProgressVisible: state.isProgressVisible,
                    onRefreshTap: onRefreshTap,
                    onStopLoadingTap: onStopLoadingTap
                )
            }
        }
    }
}

private struct RefreshStopNavigationButton: View {
    let isProgressVisible: Bool
    let onRefreshTap: () -> Void
    let onStopLoadingTap: () -> Void

    @StateObject private var lottieState = LottieAnimationViewState()
    @State private var isHovering = false
    @State private var didPlayRefreshAnimationForCurrentHover = false

    var body: some View {
        ZStack {
            RefreshNavigationButton(lottieState: lottieState, action: onRefreshTap)
                .opacity(isProgressVisible ? 0 : 1)
                .allowsHitTesting(!isProgressVisible)
                .accessibilityHidden(isProgressVisible)

            NavigationButton(
                systemName: "xmark",
                accessibilityLabel: NSLocalizedString("browser.webContentHeader.stopButton.accessibilityLabel", value: "Stop", comment: "Web content header - Accessibility description for stop loading button"),
                action: onStopLoadingTap
            )
            .opacity(isProgressVisible ? 1 : 0)
            .allowsHitTesting(isProgressVisible)
            .accessibilityHidden(!isProgressVisible)
        }
        .frame(width: 24, height: 24)
        .onHover(perform: handleHoverChange)
    }

    private func handleHoverChange(_ hovered: Bool) {
        guard hovered != isHovering else { return }
        isHovering = hovered

        if hovered {
            guard !isProgressVisible else { return }
            didPlayRefreshAnimationForCurrentHover = true
            lottieState.triggerAnimation()
        } else if didPlayRefreshAnimationForCurrentHover {
            didPlayRefreshAnimationForCurrentHover = false
            lottieState.triggerReverseAnimation()
        }
    }
}

private struct RefreshNavigationButton: View {
    @ObservedObject var lottieState: LottieAnimationViewState
    let action: () -> Void

    var body: some View {
        let config = LottieAnimationViewConfig(
            animationName: "refresh",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 999,
            animationTrigger: .manual,
            themedTintColor: .custom(light: .black, dark: .white),
            reverseOnHoverExit: true
        )

        LottieAnimationView(config: config, state: lottieState, action: action)
            .accessibilityLabel(NSLocalizedString(
                "browser.webContentHeader.refreshButton.accessibilityLabel",
                value: "Refresh",
                comment: "Web content header - Accessibility description for refresh page button"
            ))
    }
}

// MARK: - Navigation Button

struct NavigationButton: View {
    let systemName: String
    var isEnabled: Bool = true
    var accessibilityLabel: String? = nil
    /// Vertical offset for the hover background relative to the icon (negative moves up).
    var hoverBackgroundOffsetY: CGFloat = 0
    var onAnchorResolved: ((NSView?) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(isEnabled ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .themedFill((isHovering && isEnabled) ? .hover : .clear)
                        .frame(width: 24, height: 24)
                        .offset(y: hoverBackgroundOffsetY)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(accessibilityLabel ?? "")
        .background(controlAnchorBackground)
    }

    @ViewBuilder
    private var controlAnchorBackground: some View {
        if let onAnchorResolved {
            HeaderControlAnchorView { view in
                onAnchorResolved(view)
            }
        }
    }
}

struct HeaderControlAnchorView: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughAnchorView(frame: .zero)
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

    private final class PassthroughAnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

// MARK: - Preview

#Preview("Default Layout - 40pt") {
    let state = WebContentHeaderState()
    state.showAddressBar = true
    state.showNavigationButtons = true
    state.showChatButton = true
    state.showSidebarButton = true
    state.showFeedbackButton = true
    state.showDownloadButton = true
    state.canGoBack = true
    state.canGoForward = true
    state.loadingProgress = 0.5
    state.isLoading = true

    let downloadViewModel = DownloadButtonViewModel()

    return WebContentHeaderView(
        state: state,
        downloadViewModel: downloadViewModel,
        currentTab: nil,
        browserState: nil,
        onSidebarTap: {},
        onBackTap: {},
        onForwardTap: {},
        onRefreshTap: {},
        onStopLoadingTap: {},
        onChatTap: {},
        onFeedbackTap: {},
        onOpenLocationBar: { _ in }
    )
    .frame(height: 40)
    .border(Color.green, width: 2)
}

#Preview("Tall Layout - 60pt") {
    let state = WebContentHeaderState()
    state.showAddressBar = true
    state.showNavigationButtons = true
    state.showChatButton = true
    state.showSidebarButton = false
    state.showFeedbackButton = true
    state.canGoBack = false
    state.canGoForward = true
    state.loadingProgress = 0

    let downloadViewModel = DownloadButtonViewModel()

    return WebContentHeaderView(
        state: state,
        downloadViewModel: downloadViewModel,
        currentTab: nil,
        browserState: nil,
        onSidebarTap: {},
        onBackTap: {},
        onForwardTap: {},
        onRefreshTap: {},
        onStopLoadingTap: {},
        onChatTap: {},
        onFeedbackTap: {},
        onOpenLocationBar: { _ in }
    )
    .frame(height: 60)
    .border(Color.green, width: 2)
}

#Preview("Compact - 30pt") {
    let state = WebContentHeaderState()
    state.showAddressBar = true
    state.showNavigationButtons = true
    state.showChatButton = false
    state.showSidebarButton = false
    state.canGoBack = true
    state.canGoForward = false
    state.loadingProgress = 1.0
    state.isLoading = true

    let downloadViewModel = DownloadButtonViewModel()

    return WebContentHeaderView(
        state: state,
        downloadViewModel: downloadViewModel,
        currentTab: nil,
        browserState: nil,
        onSidebarTap: {},
        onBackTap: {},
        onForwardTap: {},
        onRefreshTap: {},
        onStopLoadingTap: {},
        onChatTap: {},
        onFeedbackTap: {},
        onOpenLocationBar: { _ in }
    )
    .frame(height: 30)
    .border(Color.green, width: 2)
}
