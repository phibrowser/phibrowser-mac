// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct AISettingView: View {
    @State private var connectorViewModel: AISettingsConnectorViewModel
    @State private var showDisableAIAlert = false

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    init(connectorViewModel: AISettingsConnectorViewModel) {
        _connectorViewModel = State(initialValue: connectorViewModel)
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
                AIEnableToggleRow(isOn: aiEnabledBinding)
                BrowserMemorySectionView(enabled: phiAIEnabled)
                PhiSentinelSectionView(enabled: phiAIEnabled)
                AISidebarSectionView(enabled: phiAIEnabled)
                ExternalConnectorsSectionView(connectorViewModel: connectorViewModel,
                                              enabled: phiAIEnabled)
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
        }
        .alert(
            NSLocalizedString("Turn Off AI Features?",
                              comment: "AI settings - Confirmation alert title when disabling all AI features"),
            isPresented: $showDisableAIAlert
        ) {
            Button(NSLocalizedString("Turn Off",
                                     comment: "AI settings - Destructive button to confirm turning off AI features"),
                   role: .destructive) {
                phiAIEnabled = false
            }
            Button(NSLocalizedString("Cancel",
                                     comment: "AI settings - Cancel button in disable-AI confirmation alert"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("AI conversations will be closed and all connected Connectors will be disconnected.",
                                   comment: "AI settings - Alert message explaining consequences of disabling AI features"))
        }
    }
}

// MARK: - AI Enable Toggle (top-level, no container)

private struct AIEnableToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(NSLocalizedString("Enable AI features in Phi Browser", comment: "AI settings - Master toggle to enable or disable all AI features in Phi Browser"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
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
            title: NSLocalizedString("Browser memory", comment: "AI settings - Section title for browser memory management")
        ) {
            AIContainerView {
                AINavigationRow(
                    title: NSLocalizedString("View and manage your browser memory", comment: "AI settings - Row title to open browser memory management"),
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
            title: NSLocalizedString("Phi Sentinel", comment: "AI settings - Section title for Phi Sentinel background helper"),
            subtitle: NSLocalizedString("Phi Sentinel is a lightweight background helper that allows Phi to complete scheduled AI tasks", comment: "AI settings - Description explaining what Phi Sentinel does")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("Launch Phi Sentinel automatically at login", comment: "AI settings - Toggle to auto-launch Phi Sentinel at system login"),
                    isOn: $launchSentinelOnLogin,
                    enabled: enabled
                )
            }
        }
        .onChange(of: launchSentinelOnLogin) {
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
            title: NSLocalizedString("AI Sidebar", comment: "AI settings - Section title for AI sidebar options")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("Automatically add current tab as context to new conversation", comment: "AI settings - Toggle to auto-add current tab as context when starting new AI conversation"),
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

// MARK: - External Data Connectors Section

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
            title: NSLocalizedString("External Data Connectors", comment: "AI settings - Section title for external data connectors"),
            subtitle: NSLocalizedString("External Data Connectors help to provide additional context for better AI experience", comment: "AI settings - Description explaining external data connectors purpose")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("Enable External Data Connectors", comment: "AI settings - Toggle to enable external data connectors"),
                    isOn: connectorsEnabledBinding,
                    enabled: enabled
                )

                Divider()

                AIToggleRow(
                    title: NSLocalizedString("Automatically add External Data Connectors as context to new conversation", comment: "AI settings - Toggle to auto-add connector data as context to new AI conversation"),
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
            NSLocalizedString("Turn Off Connectors?",
                              comment: "AI settings - Confirmation alert title when disabling external data connectors"),
            isPresented: $showDisableConnectorsAlert
        ) {
            Button(NSLocalizedString("Turn Off",
                                     comment: "AI settings - Destructive button to confirm turning off connectors"),
                   role: .destructive) {
                enableConnectors = false
            }
            Button(NSLocalizedString("Cancel",
                                     comment: "AI settings - Cancel button in disable-connectors confirmation alert"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("All connected Connectors will be disconnected.",
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
            Text(NSLocalizedString("External Data Connectors", comment: "AI settings - Sub-section title for connectors list within the container"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(connectorViewModel.connectors.enumerated()), id: \.element.id) { index, connector in
                    ConnectorRowView(connector: connector, enabled: enabled)
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

    var body: some View {
        HStack(spacing: 8) {
            connectorIcon
            connectorInfo
            Spacer(minLength: 8)
            manageButton
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

                if connector.isLoading {
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
                    Text(NSLocalizedString("Not connected", comment: "AI settings - Connector row status text when not connected"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                }
            }
        }
    }

    private var manageButton: some View {
        Button {
            connector.openManagePage()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                Text(NSLocalizedString("Manage", comment: "AI settings - Button to open connector management page"))
                    .font(.system(size: 13))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
    }
}

// MARK: - Connector Status Badge

private struct ConnectorStatusBadge: View {
    var body: some View {
        Text(NSLocalizedString("Connected", comment: "AI settings - Badge text when connector is successfully connected"))
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
