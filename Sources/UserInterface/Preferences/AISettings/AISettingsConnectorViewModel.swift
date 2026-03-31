// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

struct ConnectorTemplate: Identifiable {
    let id: String
    let name: String
    let provider: String
    let icon: NSImage?

    static let googleDrive = ConnectorTemplate(
        id: "google-drive",
        name: "Google Drive",
        provider: "google",
        icon: NSImage(named: "google-drive")
    )

    static let notion = ConnectorTemplate(
        id: "notion",
        name: "Notion",
        provider: "notion",
        icon: NSImage(named: "notion")
    )

    static let all: [ConnectorTemplate] = [.googleDrive, .notion]
}

// MARK: - ConnectorItemState

@Observable
@MainActor
final class ConnectorItemState: @MainActor Identifiable {
    enum ConnectionStatus {
        case connected
        case disconnected

        var isConnected: Bool { self == .connected }
    }

    let template: ConnectorTemplate
    var id: String { template.id }
    var status: ConnectionStatus = .disconnected
    var lastSyncTime: String = ""
    var isLoading: Bool = false
    private var oauthConnection: OAuthConnection?

    init(template: ConnectorTemplate) {
        self.template = template
    }

    func updateConnection(_ newConnection: OAuthConnection?) {
        oauthConnection = newConnection
        refreshStatus()
        refreshSyncTime()
    }

    private func refreshStatus() {
        guard let oauthConnection else {
            status = .disconnected
            return
        }
        status = oauthConnection.connected ? .connected : .disconnected
    }

    private func refreshSyncTime() {
        guard let oauthConnection,
              oauthConnection.connected,
              let connectedAt = oauthConnection.connectedAt else {
            lastSyncTime = NSLocalizedString("Not connected", comment: "AI settings - Default text when connector is not connected")
            return
        }
        lastSyncTime = Self.formatSyncTime(connectedAt: connectedAt)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy"
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private static func formatSyncTime(connectedAt: String) -> String {
        guard let date = iso8601Formatter.date(from: connectedAt)
                ?? ISO8601DateFormatter().date(from: connectedAt) else {
            return NSLocalizedString("Not connected", comment: "AI settings - Default text when connector is not connected")
        }
        return displayDateFormatter.string(from: date)
    }

    func openManagePage() {
        guard let browserState = BrowserState.currentState() else { return }

    #if NIGHTLY_BUILD || DEBUG
        if AuthManager.useStagingAuth0 {
            browserState.createTab("https://account.stag.phibrowser.com/settings/oauth-center", focusAfterCreate: true)
        } else {
            browserState.createTab("https://account.phibrowser.com/settings/oauth-center", focusAfterCreate: true)
        }
    #else
        browserState.createTab("https://account.phibrowser.com/settings/oauth-center", focusAfterCreate: true)
    #endif
    }
}

// MARK: - AISettingsConnectorViewModel

@Observable
@MainActor
final class AISettingsConnectorViewModel {
    var connectors: [ConnectorItemState]
    private let apiClient = APIClient.shared
    private var oauthConnections: [OAuthConnection] = []

    init() {
        connectors = ConnectorTemplate.all.map { ConnectorItemState(template: $0) }
    }

    func loadConnectionsIfNeeded() {
        guard LoginController.shared.isLoggedin() else { return }
        AppLogDebug("[AISettings] Starting to load OAuth connections...")
        loadConnections()
    }

    private func loadConnections() {
        guard LoginController.shared.isLoggedin() else { return }

        if let cached = loadCachedConnections() {
            oauthConnections = cached
            updateConnectorStates()
            AppLogDebug("[AISettings] Loaded \(cached.count) cached OAuth connections")
        }

        setAllLoading(true)

        Task { @MainActor in
            defer { setAllLoading(false) }
            do {
                let response = try await apiClient.getOAuthConnections()
                let connections = response.data.connections
                oauthConnections = connections
                cacheConnections(connections)
                updateConnectorStates()
                recordConnections(connections)
                AppLogDebug("[AISettings] Fetched \(connections.count) OAuth connections from network")
            } catch {
                AppLogError("[AISettings] Error loading OAuth connections: \(error)")
            }
        }
    }

    private func setAllLoading(_ isLoading: Bool) {
        for connector in connectors {
            connector.isLoading = isLoading
        }
    }

    private func updateConnectorStates() {
        for connector in connectors {
            let connection = oauthConnections.first { $0.provider == connector.template.provider }
            connector.updateConnection(connection)
        }
    }

    func disconnectAll() {
        let connectedProviders = connectors
            .filter { $0.status.isConnected }
            .map { $0.template.provider }

        guard !connectedProviders.isEmpty else { return }

        setAllLoading(true)

        Task { @MainActor in
            defer { setAllLoading(false) }
            for provider in connectedProviders {
                do {
                    _ = try await apiClient.deleteOAuthToken(provider: provider)
                    AppLogInfo("[AISettings] Disconnected OAuth provider: \(provider)")
                } catch {
                    AppLogWarn("[AISettings] Failed to disconnect provider \(provider): \(error)")
                }
            }
            loadConnections()
        }
    }

    // MARK: - Cache

    private func loadCachedConnections() -> [OAuthConnection]? {
        guard let userDefaults = AccountController.shared.account?.userDefaults else { return nil }
        return userDefaults.codableValue(forKey: AccountUserDefaults.DefaultsKey.cachedUserConnectors.rawValue)
    }

    private func cacheConnections(_ connections: [OAuthConnection]) {
        guard let userDefaults = AccountController.shared.account?.userDefaults else { return }
        userDefaults.set(connections, forCodableKey: AccountUserDefaults.DefaultsKey.cachedUserConnectors.rawValue)
    }

    private func recordConnections(_ connections: [OAuthConnection]) {
        let dic: [String: String] = connections.reduce(into: [:]) { partialResult, connection in
            if let template = ConnectorTemplate.all.first(where: { $0.provider == connection.provider }) {
                partialResult[template.name] = connection.connected ? "connected" : "disconnected"
            }
        }
    }
}
