// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import AuthenticationServices
import PostHog

struct ConnectorTemplate: Identifiable {
    let id: String
    let name: String
    let provider: String
    let icon: NSImage?

    static let google = ConnectorTemplate(
        id: "google",
        name: "Google (Gmail, Calendar)",
        provider: "google",
        icon: NSImage(named: "google")
    )

    static let notion = ConnectorTemplate(
        id: "notion",
        name: "Notion",
        provider: "notion",
        icon: NSImage(named: "notion")
    )

    static let slack = ConnectorTemplate(
        id: "slack",
        name: "Slack",
        provider: "slack",
        icon: NSImage(named: "slack")
    )

    static let all: [ConnectorTemplate] = [.google, .notion, .slack]
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
    var errorMessage: String?
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

    var actionTitle: String {
        status.isConnected
        ? NSLocalizedString("Disconnect", comment: "AI settings - Button to disconnect an external data connector")
        : NSLocalizedString("Connect", comment: "AI settings - Button to connect an external data connector")
    }
}

// MARK: - AISettingsConnectorViewModel

@Observable
@MainActor
final class AISettingsConnectorViewModel {
    var connectors: [ConnectorItemState]
    private let apiClient = APIClient.shared
    private var oauthConnections: [OAuthConnection] = []
    private var isRefreshingConnections = false
    private var pendingAuthorizationTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingAuthorizationSessions: [String: ASWebAuthenticationSession] = [:]
    private var pendingAuthorizationSessionIDs: [String: UUID] = [:]
    private var pendingAuthorizationPresentationProviders: [String: ConnectorOAuthPresentationContextProvider] = [:]
    private var internallyCancelledAuthorizationSessionIDs: Set<UUID> = []

    init() {
        connectors = ConnectorTemplate.all.map { ConnectorItemState(template: $0) }
    }

    func loadConnectionsIfNeeded() {
        guard LoginController.shared.isLoggedin() else { return }
        AppLogDebug("[AISettings] Starting to load OAuth connections...")
        loadConnections()
    }

    func refreshConnections() {
        loadConnections()
    }

    func handleOAuthReturn(provider: String, result: String, error: String?) {
        cancelPendingAuthorizationTimeout(provider: provider)
        cancelPendingAuthorizationSession(provider: provider)

        if result.lowercased() != "success",
           let connector = connectors.first(where: { $0.template.provider == provider }) {
            connector.errorMessage = error ?? NSLocalizedString("Connector authorization failed.", comment: "AI settings - OAuth authorization failure")
        }

        setConnectorLoading(provider: provider, isLoading: false)

        Task { @MainActor in
            await reloadConnectionsFromNetwork()
        }
    }

    private func loadConnections(useCache: Bool = true) {
        guard LoginController.shared.isLoggedin() else { return }

        if useCache, let cached = loadCachedConnections() {
            oauthConnections = cached
            updateConnectorStates()
            AppLogDebug("[AISettings] Loaded \(cached.count) cached OAuth connections")
        }

        setAllLoading(true)

        Task { @MainActor in
            await reloadConnectionsFromNetwork()
        }
    }

    private func reloadConnectionsFromNetwork() async {
        guard !isRefreshingConnections else { return }
        isRefreshingConnections = true
        defer {
            isRefreshingConnections = false
            setAllLoading(false)
        }

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

    func toggleConnection(for connector: ConnectorItemState) {
        guard !connector.isLoading else { return }
        connector.errorMessage = nil

        if connector.status.isConnected {
            disconnect(connector)
        } else {
            connect(connector)
        }
    }

    private func connect(_ connector: ConnectorItemState) {
        guard LoginController.shared.isLoggedin() else { return }
        connector.isLoading = true

        Task { @MainActor in
            do {
                let provider = connector.template.provider
                let response = try await apiClient.getOAuthAuthorization(
                    provider: provider,
                    successRedirect: Self.oauthReturnURL(provider: provider, result: "success"),
                    failureRedirect: Self.oauthReturnURL(provider: provider, result: "failure")
                )
                guard openAuthorizationURL(response.data.authURL, provider: provider) else {
                    return
                }
                schedulePendingAuthorizationTimeout(provider: provider)
                AppLogInfo("[AISettings] Started OAuth authorization flow for provider: \(provider)")
            } catch {
                connector.isLoading = false
                connector.errorMessage = error.localizedDescription
                AppLogWarn("[AISettings] Failed to connect provider \(connector.template.provider): \(error)")
            }
        }
    }

    private func disconnect(_ connector: ConnectorItemState) {
        guard LoginController.shared.isLoggedin() else { return }
        connector.isLoading = true

        Task { @MainActor in
            defer { connector.isLoading = false }
            do {
                let provider = connector.template.provider
                _ = try await apiClient.deleteOAuthToken(provider: provider)
                AppLogInfo("[AISettings] Disconnected OAuth provider: \(provider)")
            } catch {
                connector.errorMessage = error.localizedDescription
                AppLogWarn("[AISettings] Failed to disconnect provider \(connector.template.provider): \(error)")
            }

            await reloadConnectionsFromNetwork()
        }
    }

    private func setAllLoading(_ isLoading: Bool) {
        for connector in connectors {
            connector.isLoading = isLoading
        }
    }

    private func setConnectorLoading(provider: String, isLoading: Bool) {
        connectors.first { $0.template.provider == provider }?.isLoading = isLoading
    }

    private func schedulePendingAuthorizationTimeout(provider: String) {
        cancelPendingAuthorizationTimeout(provider: provider)

        pendingAuthorizationTimeouts[provider] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }

            AppLogWarn("[AISettings] OAuth authorization flow timed out for provider: \(provider)")
            cancelPendingAuthorizationSession(provider: provider)
            setConnectorLoading(provider: provider, isLoading: false)
            await reloadConnectionsFromNetwork()
        }
    }

    private func cancelPendingAuthorizationTimeout(provider: String) {
        pendingAuthorizationTimeouts[provider]?.cancel()
        pendingAuthorizationTimeouts[provider] = nil
    }

    private func openAuthorizationURL(_ authURLString: String, provider: String) -> Bool {
        guard let authURL = URL(string: authURLString),
              let scheme = authURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            connectors.first { $0.template.provider == provider }?.errorMessage =
                NSLocalizedString("The connector authorization URL is invalid.", comment: "AI settings - OAuth authorization URL error")
            setConnectorLoading(provider: provider, isLoading: false)
            return false
        }

        return startAuthorizationSession(authURL, provider: provider)
    }

    private func startAuthorizationSession(_ authURL: URL, provider: String) -> Bool {
        cancelPendingAuthorizationSession(provider: provider)

        let sessionID = UUID()
        let presentationProvider = ConnectorOAuthPresentationContextProvider(
            presentationWindow: NSApp.keyWindow ?? NSApp.mainWindow ?? MainBrowserWindowControllersManager.shared.activeWindowController?.window
        )
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "phi"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.handleAuthorizationSessionResult(provider: provider, sessionID: sessionID, callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = presentationProvider
        session.prefersEphemeralWebBrowserSession = false

        pendingAuthorizationSessions[provider] = session
        pendingAuthorizationSessionIDs[provider] = sessionID
        pendingAuthorizationPresentationProviders[provider] = presentationProvider

        guard session.start() else {
            AppLogWarn("[AISettings] OAuth authorization session failed to start for provider: \(provider)")
            clearPendingAuthorizationSession(provider: provider)
            connectors.first { $0.template.provider == provider }?.errorMessage =
                NSLocalizedString("Unable to start connector authorization.", comment: "AI settings - OAuth authorization start error")
            setConnectorLoading(provider: provider, isLoading: false)
            return false
        }

        return true
    }

    private func handleAuthorizationSessionResult(provider: String, sessionID: UUID, callbackURL: URL?, error: Error?) {
        let isCurrentSession = pendingAuthorizationSessionIDs[provider] == sessionID

        if let error {
            let wasInternallyCancelled = internallyCancelledAuthorizationSessionIDs.remove(sessionID) != nil
            guard !wasInternallyCancelled else { return }
            guard isCurrentSession else { return }

            AppLogWarn("[AISettings] OAuth authorization session ended with error for provider \(provider): \(error.localizedDescription)")
            clearPendingAuthorizationSession(provider: provider)
            cancelPendingAuthorizationTimeout(provider: provider)
            setConnectorLoading(provider: provider, isLoading: false)

            if let sessionError = error as? ASWebAuthenticationSessionError,
               sessionError.code == .canceledLogin {
                Task { @MainActor in
                    await reloadConnectionsFromNetwork()
                }
                return
            }

            connectors.first { $0.template.provider == provider }?.errorMessage = error.localizedDescription
            Task { @MainActor in
                await reloadConnectionsFromNetwork()
            }
            return
        }

        guard isCurrentSession else { return }
        clearPendingAuthorizationSession(provider: provider)
        AppLogInfo("[AISettings] OAuth authorization session returned for provider \(provider): \(callbackURL?.absoluteString ?? "nil")")

        guard callbackURL?.scheme?.lowercased() == "phi" else {
            cancelPendingAuthorizationTimeout(provider: provider)
            setConnectorLoading(provider: provider, isLoading: false)
            connectors.first { $0.template.provider == provider }?.errorMessage =
                NSLocalizedString("Connector authorization failed.", comment: "AI settings - OAuth authorization failure")
            Task { @MainActor in
                await reloadConnectionsFromNetwork()
            }
            return
        }

        let result = authorizationResult(from: callbackURL, fallbackProvider: provider)
        handleOAuthReturn(provider: result.provider, result: result.result, error: result.error)
    }

    private static func oauthReturnURL(provider: String, result: String) -> String {
        var components = URLComponents()
        components.scheme = "phi"
        components.host = "native"
        components.path = "/openpage"
        components.queryItems = [
            URLQueryItem(name: "page", value: "settings"),
            URLQueryItem(name: "section", value: "aisetting"),
            URLQueryItem(name: "oauth_provider", value: provider),
            URLQueryItem(name: "oauth_result", value: result)
        ]
        return components.url?.absoluteString ?? "phi://native/openpage?page=settings&section=aisetting&oauth_provider=\(provider)&oauth_result=\(result)"
    }

    private func authorizationResult(from callbackURL: URL?, fallbackProvider: String) -> (provider: String, result: String, error: String?) {
        guard let callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return (fallbackProvider, "success", nil)
        }

        let params = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            if let value = item.value {
                result[item.name] = value
            }
        }
        let error = params["error"]
        let returnedProvider = params["oauth_provider"] ?? params["provider"] ?? fallbackProvider
        let returnedResult = params["oauth_result"] ?? (error == nil ? "success" : "failure")
        return (returnedProvider, returnedResult, error)
    }

    private func cancelPendingAuthorizationSession(provider: String) {
        let session = pendingAuthorizationSessions[provider]
        if session != nil,
           let sessionID = pendingAuthorizationSessionIDs[provider] {
            internallyCancelledAuthorizationSessionIDs.insert(sessionID)
        }
        clearPendingAuthorizationSession(provider: provider)
        session?.cancel()
    }

    private func clearPendingAuthorizationSession(provider: String) {
        pendingAuthorizationSessions[provider] = nil
        pendingAuthorizationSessionIDs[provider] = nil
        pendingAuthorizationPresentationProviders[provider] = nil
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
            await reloadConnectionsFromNetwork()
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
        PostHogSDK.shared.capture("connector_status", properties: dic)
    }
}

private final class ConnectorOAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var presentationWindow: NSWindow?

    init(presentationWindow: NSWindow?) {
        self.presentationWindow = presentationWindow
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}
