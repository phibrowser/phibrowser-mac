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
    let onOpenLocationBar: (NSView?) -> Void
    var onAnchorResolved: ((NSView?) -> Void)?

    @State private var extensionsModel: WebContentHeaderExtensionsModel
    @State private var isExtensionPopoverShown = false
    @State private var totalHeaderWidth: CGFloat = 10000

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
        onOpenLocationBar: @escaping (NSView?) -> Void,
        onAnchorResolved: ((NSView?) -> Void)? = nil
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
        self.onOpenLocationBar = onOpenLocationBar
        self.onAnchorResolved = onAnchorResolved
        _extensionsModel = State(wrappedValue: WebContentHeaderExtensionsModel(browserState: browserState))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 0) {
                leadingButtons
                    .padding(.leading, 16)

                if state.showAddressBar {
                    WebContentAddressBarView(
                        browserState: browserState,
                        currentTab: currentTab,
                        showBackgroundWhenInactive: false,
                        loadingProgress: state.loadingProgress,
                        isLoading: state.isLoading,
                        isProgressVisible: state.isProgressVisible,
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
                    pinnedExtensions: extensionsModel.pinnedExtensions,
                    showDownload: state.showDownloadButton,
                    showFeedback: state.showFeedbackButton,
                    showChat: state.showChatButton,
                    extensionManager: browserState?.extensionManager,
                    browserState: browserState,
                    downloadViewModel: downloadViewModel,
                    isDownloadPopoverShown: $state.isDownloadPopoverShown,
                    isExtensionPopoverShown: $isExtensionPopoverShown,
                    onFeedbackTap: onFeedbackTap,
                    onChatTap: onChatTap
                )
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
    }

    private var leadingButtonsWidth: CGFloat {
        var count = 0
        if state.showSidebarButton { count += 1 }
        if state.showNavigationButtons { count += 3 }
        let buttonsWidth: CGFloat = count > 0
            ? CGFloat(count) * 24 + CGFloat(count - 1) * 8
            : 0
        return 16 + buttonsWidth
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
                    accessibilityLabel: NSLocalizedString("Toggle Sidebar", comment: "Web content header - Accessibility description for sidebar toggle button"),
                    action: onSidebarTap
                )
            }

            if state.showNavigationButtons {
                NavigationButton(
                    systemName: "chevron.left",
                    isEnabled: state.canGoBack,
                    accessibilityLabel: NSLocalizedString("Back", comment: "Web content header - Accessibility description for back navigation button"),
                    action: onBackTap
                )

                NavigationButton(
                    systemName: "chevron.right",
                    isEnabled: state.canGoForward,
                    accessibilityLabel: NSLocalizedString("Forward", comment: "Web content header - Accessibility description for forward navigation button"),
                    action: onForwardTap
                )

                NavigationButton(
                    systemName: state.isProgressVisible ? "xmark" : "arrow.clockwise",
                    accessibilityLabel: state.isProgressVisible
                        ? NSLocalizedString("Stop", comment: "Web content header - Accessibility description for stop loading button")
                        : NSLocalizedString("Refresh", comment: "Web content header - Accessibility description for refresh page button"),
                    action: state.isProgressVisible ? onStopLoadingTap : onRefreshTap
                )
            }
        }
    }
}

// MARK: - Navigation Button

struct NavigationButton: View {
    let systemName: String
    var isEnabled: Bool = true
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(isEnabled ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .themedBackground((isHovering && isEnabled) ? .hover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(accessibilityLabel ?? "")
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
