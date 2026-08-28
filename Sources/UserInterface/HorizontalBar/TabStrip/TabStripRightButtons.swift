// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import Combine

/// Right-side buttons area for the TabStrip bar
/// Contains CardEntryButton and future buttons
struct TabStripRightButtons: View {
    @ObservedObject var cardManager: NotificationCardManager
    let browserState: BrowserState
    let onCardEntryTap: () -> Void
    let onSearchTabsTap: (NSView?) -> Void

    /// Set once Sparkle has prepared a downloaded update for installation.
    @State private var availableUpdateVersion: String? = nil

    // Organize-tabs is unavailable when AI is disabled, in incognito windows,
    // or when there are too few eligible tabs. `@AppStorage` keeps the AI toggle
    // reactive.
    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    /// `BrowserState` isn't an `ObservableObject`, so the eligible page count is
    /// mirrored from the `$normalTabs` publisher via `onReceive`.
    @State private var eligibleTabCount: Int

    init(
        cardManager: NotificationCardManager,
        browserState: BrowserState,
        onCardEntryTap: @escaping () -> Void,
        onSearchTabsTap: @escaping (NSView?) -> Void
    ) {
        self.cardManager = cardManager
        self.browserState = browserState
        self.onCardEntryTap = onCardEntryTap
        self.onSearchTabsTap = onSearchTabsTap
        _eligibleTabCount = State(
            initialValue: FarringdonOrganizer.eligibleTabCount(in: browserState.normalTabs))

        #if DEBUG && !PHI_OSS_BUILD
        _availableUpdateVersion = State(initialValue: Self.uiTestUpdateVersion())
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            #if !PHI_OSS_BUILD
            if availableUpdateVersion != nil {
                TabStripUpdateButton {
                    AppController.shared.checkForUpdate(nil)
                }
            }
            #endif

            if showCardEntry {
                CardEntryButton(action: onCardEntryTap)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity
                        )
                    )
            }

            if showFarringdonButton {
                TabStripFarringdonButton(eligibleTabCount: eligibleTabCount)
            }

            TabStripSearchTabsButton(action: onSearchTabsTap)
        }
        .onReceive(browserState.$normalTabs.receive(on: DispatchQueue.main)) { tabs in
            eligibleTabCount = FarringdonOrganizer.eligibleTabCount(in: tabs)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCardEntry)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showFarringdonButton)
        #if !PHI_OSS_BUILD
        .onReceive(NotificationCenter.default.publisher(for: .sparkleDidDownloadUpdate)) { notification in
            availableUpdateVersion = notification.userInfo?["displayVersion"] as? String ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .sparkleDidSkipUpdate)) { _ in
            availableUpdateVersion = nil
        }
        #endif
        // The update action is text-based, unlike the other 24pt controls. Keep
        // the existing 88pt minimum for the icon-only state, while letting the
        // hosting view grow when an update is ready so it never overlaps tabs.
        .frame(minWidth: 88, maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: availableUpdateVersion != nil)
        .ignoresSafeArea()
    }
    
    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }

    private var showFarringdonButton: Bool {
        FarringdonOrganizer.canOrganizeTabs(
            phiAIEnabled: phiAIEnabled,
            isIncognito: browserState.isIncognito,
            eligibleTabCount: eligibleTabCount
        )
    }

    #if DEBUG && !PHI_OSS_BUILD
    private static func uiTestUpdateVersion() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitest"),
              let versionFlagIndex = arguments.firstIndex(of: "-tabStripUpdateVersion"),
              arguments.indices.contains(versionFlagIndex + 1) else {
            return nil
        }

        let version = arguments[versionFlagIndex + 1]
        return version.isEmpty ? nil : version
    }
    #endif
}

#if !PHI_OSS_BUILD
/// Update action displayed to the left of the notification-card entry once
/// Sparkle has a downloaded update ready to install. Its visual configuration
/// intentionally mirrors `SidebarHeaderView.upgradeButton`.
private struct TabStripUpdateButton: View {
    private static let accessibilityIdentifier = "tabStrip.updateButton"

    @StateObject private var state = HoverableButtonState()
    let action: () -> Void

    private var title: String {
        NSLocalizedString(
            "sidebar.updateReminder.updateButton",
            value: "Update",
            comment: "Tab strip update button title"
        )
    }

    private var config: HoverableButtonConfig {
        HoverableButtonConfig(
            title: title,
            displayMode: .titleOnly,
            backgroundColor: .themeColor,
            hoverBackgroundColor: .themeColorOnHover,
            titleColor: .custom(light: .white, dark: .white),
            titleFont: .system(size: 11, weight: .medium),
            edgeInsets: EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4),
            cornerRadius: 6
        )
    }

    var body: some View {
        HoverableButton(config: config, state: state, action: action)
            .frame(width: 56, height: 24)
            .help(title)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .accessibilityLabel(Text(title))
    }
}
#endif

/// "Organize tabs with AI" (Farringdon) button for the horizontal tab strip,
/// shown next to the search button. Triggers the same focused-window organize run
/// as the sidebar broom and loops its Lottie animation while a run is in progress
/// (driven by the shared `.farringdonOrganizeDidStart` /
/// `.farringdonOrganizeDidFinish` events).
private struct TabStripFarringdonButton: View {
    let eligibleTabCount: Int

    @StateObject private var lottieState = LottieAnimationViewState()
    @State private var isOrganizing = false
    @State private var organizeStartedAt: Date?
    @State private var anchorView: NSView?

    private let buttonSize: CGFloat = 24
    private static let safetyTimeout: TimeInterval = 8.0

    private let animationConfig = LottieAnimationViewConfig(
        animationName: "broom",
        size: CGSize(width: 24, height: 24),
        hoverBackgroundColor: Color.sidebarTabHovered,
        cornerRadius: 6,
        animationTrigger: .manual,
        themedTintColor: .custom(light: .black, dark: .white),
        loopMode: .loop
    )

    private var label: String {
        NSLocalizedString("toolbar.organizeTabs.accessibilityLabel", value: "Organize tabs with AI",
            comment: "Organize Tabs - Button tooltip and accessibility label")
    }

    var body: some View {
        LottieAnimationView(config: animationConfig, state: lottieState) {
            guard !isOrganizing else { return }
            FeatureEntryAnalytics.capture(.organizeTabs, surface: .webContentHeader)
            FarringdonOrganizer.organizeFocusedWindow(eligibleTabCount: eligibleTabCount)
        }
        .frame(width: buttonSize, height: buttonSize)
        .background(
            TabStripAnchorReader { view in
                self.anchorView = view
            }
        )
        .help(label)
        .accessibilityLabel(Text(label))
        .onReceive(NotificationCenter.default.publisher(for: .farringdonOrganizeDidStart)) { _ in
            // Only the window that triggered the run (the key window) animates.
            guard anchorView?.window?.isKeyWindow == true else { return }
            startAnimation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .farringdonOrganizeDidFinish)) { _ in
            stopAnimation()
        }
    }

    private func startAnimation() {
        guard !isOrganizing else { return }
        isOrganizing = true
        organizeStartedAt = Date()
        lottieState.triggerAnimation()
        // Stop even if the completion signal never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.safetyTimeout) {
            stopAnimation()
        }
    }

    private func stopAnimation() {
        guard isOrganizing else { return }

        // Complete at least one full playback even when the organize run finishes immediately.
        let elapsed = organizeStartedAt.map { Date().timeIntervalSince($0) }
            ?? BroomAnimation.minimumPlaybackDuration
        let remaining = max(0, BroomAnimation.minimumPlaybackDuration - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            guard isOrganizing else { return }
            isOrganizing = false
            organizeStartedAt = nil
            lottieState.stopAnimation()
        }
    }
}

private struct TabStripSearchTabsButton: View {
    private static let accessibilityIdentifier = "tabStrip.searchTabsButton"

    let action: (NSView?) -> Void

    @State private var isHovering = false
    @State private var anchorView: NSView?

    private let buttonSize: CGFloat = 24
    private let iconSize: CGFloat = 16
    private let cornerRadius: CGFloat = 6
    private var searchTabsLabel: String {
        NSLocalizedString("toolbar.searchTabs.accessibilityLabel", value: "Search Tabs", comment: "Search Tabs - Button tooltip and accessibility label")
    }

    var body: some View {
        Button {
            action(anchorView)
        } label: {
            Image(.leftSidebarSearchTab)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.primary)
                .frame(width: iconSize, height: iconSize)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
                .background(
                    TabStripAnchorReader { anchorView in
                        self.anchorView = anchorView
                    }
                )
        }
        .buttonStyle(.plain)
        .frame(width: buttonSize, height: buttonSize)
        .help(searchTabsLabel)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .accessibilityLabel(Text(searchTabsLabel))
    }
}

private struct TabStripAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughAnchorView()
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
