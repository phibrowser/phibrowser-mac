// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import PostHog

struct AISettingView: View {
    @State private var connectorViewModel: AISettingsConnectorViewModel
    @State private var showDisableAIAlert = false
    @State private var isGuest = ApplicationState.shared.isGuest

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    init(connectorViewModel: AISettingsConnectorViewModel) {
        _connectorViewModel = State(initialValue: connectorViewModel)
    }

    private var aiFeaturesAvailable: Bool {
        phiAIEnabled && !isGuest
    }

    private var aiEnabledBinding: Binding<Bool> {
        Binding(
            get: { phiAIEnabled },
            set: { newValue in
                if newValue {
                    phiAIEnabled = true
                } else {
                    showDisableAIAlert = true
                }
            }
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                AIMasterControlSection(
                    isOn: aiEnabledBinding,
                    isGuest: isGuest,
                    loginAction: logInToEnableAI
                )
                BrowserMemorySectionView(enabled: aiFeaturesAvailable)
                PhiSentinelSectionView(enabled: aiFeaturesAvailable)
                NewTabPageSectionView(enabled: aiFeaturesAvailable)
                AISidebarSectionView(enabled: aiFeaturesAvailable)
                ExternalConnectorsSectionView(
                    connectorViewModel: connectorViewModel,
                    enabled: aiFeaturesAvailable
                )
                PhiLinkSettingsSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .onChange(of: phiAIEnabled) { oldValue, newValue in
            if newValue == false {
                connectorViewModel.disconnectAll()
            }
            notifyNativeSettingsChanged()
            // PostHog: Capture AI features toggled event
            PostHogSDK.shared.capture("ai_features_toggled", properties: [
                "enabled": newValue,
            ])
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .browserAccessStateDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            isGuest = ApplicationState.shared.isGuest
            if ApplicationState.shared.isAuthenticated {
                connectorViewModel.loadConnectionsIfNeeded()
            } else {
                connectorViewModel.suspendForUnauthenticatedAccess()
            }
        }
        .alert(
            NSLocalizedString("settings.ai.disableFeatures.title", value: "Turn Off AI Features?",
                              comment: "AI settings - Confirmation alert title when disabling all AI features"),
            isPresented: $showDisableAIAlert
        ) {
            Button(NSLocalizedString("settings.ai.disableFeatures.confirmButton", value: "Turn Off",
                                     comment: "AI settings - Destructive button to confirm turning off AI features"),
                   role: .destructive) {
                phiAIEnabled = false
            }
            Button(NSLocalizedString("settings.ai.disableFeatures.cancelButton", value: "Cancel",
                                     comment: "AI settings - Cancel button in disable-AI confirmation alert"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.ai.disableFeatures.message", value: "AI conversations will be closed and all connected Connectors will be disconnected.",
                                   comment: "AI settings - Alert message explaining consequences of disabling AI features"))
        }
    }

    private func logInToEnableAI() {
        LoginController.shared.showLoginWindowToEnableAI()
    }
}

// MARK: - AI Master Controls

private struct AIMasterControlSection: View {
    @Binding var isOn: Bool
    let isGuest: Bool
    let loginAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isGuest {
                GuestAILoginPromptRow(loginAction: loginAction)
            }

            AIEnableToggleRow(
                isOn: $isOn,
                enabled: !isGuest
            )
        }
    }
}

private struct GuestAILoginPromptRow: View {
    let loginAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(NSLocalizedString(
                "settings.ai.guestLoginPrompt.message",
                value: "Sign in to use AI features",
                comment: "AI settings - Message above the AI master toggle when Guest Mode requires sign-in"
            ))
            .font(.system(size: 13))
            .themedForeground(.textSecondary)

            Spacer(minLength: 12)

            Button(
                NSLocalizedString(
                    "settings.ai.guestLoginPrompt.loginButton",
                    value: "Sign in",
                    comment: "AI settings - Button in the Guest Mode AI prompt that opens sign-in"
                ),
                action: loginAction
            )
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
    }
}

// MARK: - AI Enable Toggle (top-level, no container)

private struct AIEnableToggleRow: View {
    @Binding var isOn: Bool
    let enabled: Bool

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { enabled ? isOn : false },
            set: { if enabled { isOn = $0 } }
        )
    }

    var body: some View {
        HStack {
            Text(NSLocalizedString("settings.ai.features.enableToggle", value: "Enable AI features in Phi Browser", comment: "AI settings - Master toggle to enable or disable all AI features in Phi Browser"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .opacity(enabled ? 1.0 : 0.4)
            Spacer(minLength: 12)
            Toggle("", isOn: effectiveBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .disabled(!enabled)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
    }
}

// MARK: - Browser Memory Section

private struct BrowserMemorySectionView: View {
    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.browserMemory.sectionTitle", value: "Browser memory", comment: "AI settings - Section title for browser memory management")
        ) {
            AIContainerView {
                AINavigationRow(
                    title: NSLocalizedString("settings.ai.browserMemory.manageButtonTitle", value: "View and manage your browser memory", comment: "AI settings - Row title to open browser memory management"),
                    enabled: enabled,
                    action: openBrowserMemoryPage
                )
            }
        }
    }

    private func openBrowserMemoryPage() {
        BrowserState.currentState()?.createTab("chrome://memory/memory.html", focusAfterCreate: true)
    }
}

// MARK: - Phi Sentinel Section

private struct PhiSentinelSectionView: View {
    @AppStorage(PhiPreferences.AISettings.launchSentinelOnLogin.rawValue)
    private var launchSentinelOnLogin: Bool = PhiPreferences.AISettings.launchSentinelOnLogin.defaultValue

    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.phiSentinel.sectionTitle", value: "Phi Sentinel", comment: "AI settings - Section title for Phi Sentinel background helper"),
            subtitle: NSLocalizedString("settings.ai.phiSentinel.description", value: "Phi Sentinel is a lightweight background helper that allows Phi to complete scheduled AI tasks", comment: "AI settings - Description explaining what Phi Sentinel does")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.phiSentinel.autoLaunchToggle", value: "Launch Phi Sentinel when you sign in to your Mac", comment: "AI settings - Toggle to auto-launch Phi Sentinel when signing in to the Mac"),
                    isOn: $launchSentinelOnLogin,
                    enabled: enabled
                )

                Divider()

                AINavigationRow(
                    title: NSLocalizedString("settings.ai.privateAI.title", value: "Private AI", comment: "AI settings - Row that opens Phi Sentinel's Private AI page"),
                    enabled: enabled,
                    action: openPrivateAI
                )
            }
        }
        .onChange(of: launchSentinelOnLogin) {
            notifyNativeSettingsChanged()
        }
    }

    private func openPrivateAI() {
        SentinelHelper.openDashboard(section: "experimental")
    }
}

// MARK: - New Tab Page Section

private struct NewTabPageSectionView: View {
    @AppStorage(PhiPreferences.AISettings.enableProactiveSuggestionsOnNTP.rawValue)
    private var enableProactiveSuggestionsOnNTP: Bool = PhiPreferences.AISettings.enableProactiveSuggestionsOnNTP.defaultValue

    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.newTabPage.sectionTitle", value: "New Tab Page", comment: "AI settings - Section title for new tab page options")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.newTabPage.proactiveSuggestionsToggle", value: "Show proactive suggestions on the new tab page", comment: "AI settings - Toggle to show proactive suggestions on the new tab page"),
                    isOn: $enableProactiveSuggestionsOnNTP,
                    enabled: enabled
                )
            }
        }
        .onChange(of: enableProactiveSuggestionsOnNTP) {
            notifyNativeSettingsChanged()
        }
    }
}

// MARK: - AI Sidebar Section

private struct AISidebarSectionView: View {
    @AppStorage(PhiPreferences.AISettings.enableChatWithTabs.rawValue)
    private var enableChatWithTabs: Bool = PhiPreferences.AISettings.enableChatWithTabs.defaultValue

    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.sidebar.sectionTitle", value: "AI Sidebar", comment: "AI settings - Section title for AI sidebar options")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.sidebar.includeCurrentTabToggle", value: "Automatically add current tab as context to new conversation", comment: "AI settings - Toggle to auto-add current tab as context when starting new AI conversation"),
                    isOn: $enableChatWithTabs,
                    enabled: enabled
                )
            }
        }
        .onChange(of: enableChatWithTabs) {
            notifyNativeSettingsChanged()
        }
    }
}

private struct ExternalConnectorsSectionView: View {
    @AppStorage(PhiPreferences.AISettings.enableConnectors.rawValue)
    private var enableConnectors: Bool = PhiPreferences.AISettings.enableConnectors.defaultValue

    @AppStorage(PhiPreferences.AISettings.enableConnectorContext.rawValue)
    private var enableConnectorContext: Bool = PhiPreferences.AISettings.enableConnectorContext.defaultValue

    @State private var showDisableConnectorsAlert = false

    let connectorViewModel: AISettingsConnectorViewModel
    let enabled: Bool

    private var subItemsEnabled: Bool { enabled && enableConnectors }

    private var connectorsEnabledBinding: Binding<Bool> {
        Binding(
            get: { enableConnectors },
            set: { newValue in
                if newValue {
                    enableConnectors = true
                } else {
                    showDisableConnectorsAlert = true
                }
            }
        )
    }

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.connectors.sectionTitle", value: "External Data Connectors", comment: "AI settings - Section title for external data connectors"),
            subtitle: NSLocalizedString("settings.ai.connectors.description", value: "External Data Connectors help to provide additional context for better AI experience", comment: "AI settings - Description explaining external data connectors purpose")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.connectors.enableToggle", value: "Enable External Data Connectors", comment: "AI settings - Toggle to enable external data connectors"),
                    isOn: connectorsEnabledBinding,
                    enabled: enabled
                )

                Divider()

                AIToggleRow(
                    title: NSLocalizedString("settings.ai.connectors.includeInNewConversationToggle", value: "Automatically add External Data Connectors as context to new conversation", comment: "AI settings - Toggle to auto-add connector data as context to new AI conversation"),
                    isOn: $enableConnectorContext,
                    enabled: subItemsEnabled
                )

                Divider()

                ConnectorsListView(connectorViewModel: connectorViewModel, enabled: subItemsEnabled)
            }
        }
        .onChange(of: enableConnectors) {
            notifyNativeSettingsChanged()
            if !enableConnectors {
                connectorViewModel.disconnectAll()
            }
        }
        .onChange(of: enableConnectorContext) {
            notifyNativeSettingsChanged()
        }
        .alert(
            NSLocalizedString("settings.ai.disableConnectors.title", value: "Turn Off Connectors?",
                              comment: "AI settings - Confirmation alert title when disabling external data connectors"),
            isPresented: $showDisableConnectorsAlert
        ) {
            Button(NSLocalizedString("settings.ai.disableConnectors.confirmButton", value: "Turn Off",
                                     comment: "AI settings - Destructive button to confirm turning off connectors"),
                   role: .destructive) {
                enableConnectors = false
            }
            Button(NSLocalizedString("settings.ai.disableConnectors.cancelButton", value: "Cancel",
                                     comment: "AI settings - Cancel button in disable-connectors confirmation alert"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.ai.disableConnectors.message", value: "All connected Connectors will be disconnected.",
                                   comment: "AI settings - Alert message explaining consequences of disabling connectors"))
        }
    }
}

// MARK: - Connectors List

private struct ConnectorsListView: View {
    let connectorViewModel: AISettingsConnectorViewModel
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("settings.ai.connectors.listSectionTitle", value: "External Data Connectors", comment: "AI settings - Sub-section title for connectors list within the container"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(connectorViewModel.connectors.enumerated()), id: \.element.id) { index, connector in
                    ConnectorRowView(connector: connector, enabled: enabled) {
                        connectorViewModel.toggleConnection(for: connector)
                    } refreshAction: {
                        connectorViewModel.refreshConnection(for: connector)
                    }
                    if index < connectorViewModel.connectors.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 8)
            .themedBackground(ThemedColor(light: .white.withAlphaComponent(0.3),
                                           dark: .white.withAlphaComponent(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .themedStroke(.border)
            }
        }
        .padding(.vertical, 12)
        .opacity(enabled ? 1.0 : 0.4)
    }
}

// MARK: - Connector Row

private struct ConnectorRowView: View {
    let connector: ConnectorItemState
    let enabled: Bool
    let action: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            connectorIcon
            connectorInfo
            Spacer(minLength: 8)
            connectorActions
        }
        .padding(.vertical, 8)
    }

    private var connectorIcon: some View {
        Group {
            if let icon = connector.template.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 20, height: 20)
            }
        }
        .frame(width: 31, height: 31)
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var connectorInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(connector.template.name)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)

                if connector.isAuthorizationPending || connector.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            HStack(spacing: 6) {
                if connector.status.isConnected {
                    ConnectorStatusBadge()
                    
                    Text(connector.lastSyncTime)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                } else {
                    Text(NSLocalizedString("settings.ai.connectors.notConnectedRowStatus", value: "Not connected", comment: "AI settings - Connector row status text when not connected"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                }
            }

            if let errorMessage = connector.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }
        }
    }

    private var connectorActions: some View {
        HStack(spacing: 8) {
            if connector.isAuthorizationPending || connector.isLoading {
                refreshButton
            }
            manageButton
        }
        .frame(width: 144, alignment: .trailing)
    }

    private var manageButton: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connector.status.isConnected ? "xmark.circle" : "link")
                    .font(.system(size: 11))
                Text(connector.actionTitle)
                    .font(.system(size: 13))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 92)
        .disabled(!enabled || (connector.isLoading && !connector.isAuthorizationPending))
    }

    private var refreshButton: some View {
        Button {
            refreshAction()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(NSLocalizedString("settings.ai.connectors.refreshButtonTooltip", value: "Refresh connector status", comment: "AI settings - Tooltip for refreshing connector status"))
        .disabled(!enabled || (connector.isLoading && !connector.isAuthorizationPending))
    }
}

// MARK: - Connector Status Badge

private struct ConnectorStatusBadge: View {
    var body: some View {
        Text(NSLocalizedString("settings.ai.connectors.connectedStatus", value: "Connected", comment: "AI settings - Badge text when connector is successfully connected"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.004, green: 0.4, blue: 0.19))
            .padding(.horizontal, 4)
            .background(Color(red: 0.86, green: 0.99, blue: 0.91))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Reusable Components

private struct AISectionView<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AIContainerView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .themedStroke(.border)
        }
    }
}

private struct AIToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled: Bool = true

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { enabled ? isOn : false },
            set: { isOn = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .opacity(enabled ? 1.0 : 0.4)
            Spacer(minLength: 12)
            Toggle("", isOn: effectiveBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .disabled(!enabled)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AINavigationRow: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .themedForeground(.textSecondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(enabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Helpers

private func notifyNativeSettingsChanged() {
    let settings = PhiPreferences.AISettings.buildConfig()
    ChromiumLauncher.sharedInstance().bridge?.nativeSettingsChanged(settings)
    AppLogDebug("[AISettings] Native settings changed notification sent: \(settings)")
}

#Preview {
    AISettingView(connectorViewModel: AISettingsConnectorViewModel())
}
