// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
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
    var isAuthorizationPending: Bool = false
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
    private var pendingAuthorizationPolls: [String: Task<Void, Never>] = [:]
    private var pendingAuthorizationTabGuids: [String: String] = [:]
    private var pendingAuthorizationTabIds: [Int: String] = [:]
    private var tabCloseObserver: NotificationObserver?

    init() {
        connectors = ConnectorTemplate.all.map { ConnectorItemState(template: $0) }
        tabCloseObserver = NotificationObserver(
            NotificationCenter.default.addObserver(
                forName: .browserTabDidClose,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let tabId = notification.userInfo?[BrowserTabCloseInfoKey.tabId] as? Int else { return }
                let localGuid = notification.userInfo?[BrowserTabCloseInfoKey.localGuid] as? String
                let url = notification.userInfo?[BrowserTabCloseInfoKey.url] as? String
                Task { @MainActor in
                    self?.handleBrowserTabClosed(tabId: tabId, localGuid: localGuid, url: url)
                }
            }
        )
    }

    func loadConnectionsIfNeeded() {
        guard LoginController.shared.isLoggedin() else { return }
        AppLogDebug("[AISettings] Starting to load OAuth connections...")
        loadConnections()
    }

    func refreshConnections() {
        loadConnections()
    }

    func refreshConnection(for connector: ConnectorItemState) {
        connector.errorMessage = nil
        connector.isLoading = true
        Task { @MainActor in
            await reloadConnectionsFromNetwork()
            if connector.status.isConnected {
                finishPendingAuthorization(provider: connector.template.provider, closeTab: true)
            } else {
                connector.isLoading = false
            }
        }
    }

    func handleOAuthReturn(provider: String, result: String, error: String?) {
        cancelPendingAuthorizationPoll(provider: provider)
        pendingAuthorizationTabGuids[provider] = nil
        removePendingAuthorizationTabIds(provider: provider)

        if result.lowercased() != "success",
           let connector = connectors.first(where: { $0.template.provider == provider }) {
            connector.errorMessage = error ?? NSLocalizedString("Connector authorization failed.", comment: "AI settings - OAuth authorization failure")
        }

        setConnectorLoading(provider: provider, isLoading: false)
        setConnectorAuthorizationPending(provider: provider, isPending: false)

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
            clearFinishedLoadingStates()
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
        if connector.isLoading && !connector.isAuthorizationPending {
            return
        }
        connector.errorMessage = nil

        if connector.status.isConnected {
            disconnect(connector)
        } else {
            connect(connector)
        }
    }

    private func connect(_ connector: ConnectorItemState) {
        guard LoginController.shared.isLoggedin() else { return }
        let provider = connector.template.provider
        closePendingAuthorizationTab(provider: provider)
        cancelPendingAuthorizationPoll(provider: provider)
        connector.isLoading = true
        connector.isAuthorizationPending = true

        Task { @MainActor in
            do {
                let response = try await apiClient.getOAuthAuthorization(
                    provider: provider,
                    successRedirect: apiClient.oauthNativeFinishedRedirect(provider: provider, result: "success"),
                    failureRedirect: apiClient.oauthNativeFinishedRedirect(provider: provider, result: "failure")
                )
                let tabGuid = Self.oauthTabGuid(provider: provider)
                guard openAuthorizationURL(response.data.authURL, provider: provider, tabGuid: tabGuid) else {
                    return
                }
                pendingAuthorizationTabGuids[provider] = tabGuid
                capturePendingAuthorizationTabId(provider: provider, tabGuid: tabGuid)
                startPendingAuthorizationPoll(provider: provider)
                AppLogInfo("[AISettings] Started OAuth authorization flow for provider: \(provider)")
            } catch {
                connector.isLoading = false
                connector.isAuthorizationPending = false
                connector.errorMessage = error.localizedDescription
                AppLogWarn("[AISettings] Failed to connect provider \(connector.template.provider): \(error)")
            }
        }
    }

    private func disconnect(_ connector: ConnectorItemState) {
        guard LoginController.shared.isLoggedin() else { return }
        cancelPendingAuthorizationPoll(provider: connector.template.provider)
        connector.isLoading = true

        Task { @MainActor in
            defer {
                connector.isLoading = false
                connector.isAuthorizationPending = false
            }
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

    private func clearFinishedLoadingStates() {
        for connector in connectors where pendingAuthorizationPolls[connector.template.provider] == nil {
            connector.isLoading = false
        }
    }

    private func setConnectorLoading(provider: String, isLoading: Bool) {
        connectors.first { $0.template.provider == provider }?.isLoading = isLoading
    }

    private func setConnectorAuthorizationPending(provider: String, isPending: Bool) {
        connectors.first { $0.template.provider == provider }?.isAuthorizationPending = isPending
    }

    private func openAuthorizationURL(_ authURLString: String, provider: String, tabGuid: String) -> Bool {
        guard let authURL = URL(string: authURLString),
              let scheme = authURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            connectors.first { $0.template.provider == provider }?.errorMessage =
                NSLocalizedString("The connector authorization URL is invalid.", comment: "AI settings - OAuth authorization URL error")
            setConnectorLoading(provider: provider, isLoading: false)
            return false
        }

        guard let browserState = BrowserState.currentState()
                ?? MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else {
            connectors.first { $0.template.provider == provider }?.errorMessage =
                NSLocalizedString("Unable to open connector authorization.", comment: "AI settings - OAuth authorization open error")
            setConnectorLoading(provider: provider, isLoading: false)
            return false
        }

        browserState.createTab(authURL.absoluteString, customGuid: tabGuid, focusAfterCreate: true)
        return true
    }

    private static func oauthTabGuid(provider: String) -> String {
        "oauth-connector-\(provider)"
    }

    private func startPendingAuthorizationPoll(provider: String) {
        pendingAuthorizationPolls[provider]?.cancel()
        pendingAuthorizationPolls[provider] = nil

        pendingAuthorizationPolls[provider] = Task { @MainActor in
            let maxAttempts = 60
            for attempt in 1...maxAttempts {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard !Task.isCancelled else { return }

                if let tabGuid = pendingAuthorizationTabGuids[provider] {
                    capturePendingAuthorizationTabId(provider: provider, tabGuid: tabGuid)
                }
                await reloadConnectionsFromNetwork()
                if connectors.first(where: { $0.template.provider == provider })?.status.isConnected == true {
                    finishPendingAuthorization(provider: provider, closeTab: true)
                    AppLogInfo("[AISettings] OAuth authorization connected for provider: \(provider)")
                    return
                }

                AppLogDebug("[AISettings] OAuth authorization polling attempt \(attempt) for provider: \(provider)")
            }

            AppLogWarn("[AISettings] OAuth authorization polling timed out for provider: \(provider)")
            pendingAuthorizationPolls[provider] = nil
            pendingAuthorizationTabGuids[provider] = nil
            removePendingAuthorizationTabIds(provider: provider)
            setConnectorLoading(provider: provider, isLoading: false)
            setConnectorAuthorizationPending(provider: provider, isPending: false)
        }
    }

    private func cancelPendingAuthorizationPoll(provider: String) {
        pendingAuthorizationPolls[provider]?.cancel()
        pendingAuthorizationPolls[provider] = nil
        pendingAuthorizationTabGuids[provider] = nil
        removePendingAuthorizationTabIds(provider: provider)
        setConnectorAuthorizationPending(provider: provider, isPending: false)
    }

    private func cancelAllPendingAuthorizationPolls() {
        for poll in pendingAuthorizationPolls.values {
            poll.cancel()
        }
        pendingAuthorizationPolls.removeAll()
        pendingAuthorizationTabGuids.removeAll()
        pendingAuthorizationTabIds.removeAll()
        clearFinishedLoadingStates()
    }

    private func finishPendingAuthorization(provider: String, closeTab: Bool) {
        pendingAuthorizationPolls[provider]?.cancel()
        pendingAuthorizationPolls[provider] = nil
        setConnectorLoading(provider: provider, isLoading: false)
        setConnectorAuthorizationPending(provider: provider, isPending: false)
        if closeTab {
            closePendingAuthorizationTab(provider: provider)
        } else {
            pendingAuthorizationTabGuids[provider] = nil
            removePendingAuthorizationTabIds(provider: provider)
        }
    }

    private func handleBrowserTabClosed(tabId: Int, localGuid: String?, url: String?) {
        guard let provider = pendingAuthorizationProvider(tabId: tabId, localGuid: localGuid, url: url) else { return }
        AppLogInfo(
            "[AISettings] OAuth authorization tab closed " +
            "provider=\(provider) tabId=\(tabId) localGuid=\(localGuid ?? "nil") url=\(url ?? "nil")"
        )
        Task { @MainActor in
            await reloadConnectionsFromNetwork()
            if connectors.first(where: { $0.template.provider == provider })?.status.isConnected == true {
                finishPendingAuthorization(provider: provider, closeTab: false)
            } else {
                cancelPendingAuthorizationPoll(provider: provider)
                setConnectorLoading(provider: provider, isLoading: false)
            }
        }
    }

    private func pendingAuthorizationProvider(tabId: Int, localGuid: String?, url: String?) -> String? {
        if let provider = pendingAuthorizationTabIds[tabId] {
            return provider
        }

        for (provider, expectedGuid) in pendingAuthorizationTabGuids {
            if localGuid == expectedGuid {
                return provider
            }
            if Self.isOAuthCallbackURL(url, provider: provider)
                || Self.isNativeFinishedURL(url, provider: provider) {
                return provider
            }
        }

        return nil
    }

    private func capturePendingAuthorizationTabId(provider: String, tabGuid: String) {
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            if let tab = controller.browserState.tabs.first(where: {
                $0.guidInLocalDB == tabGuid || Self.isAuthorizationTab($0, provider: provider)
            }) {
                pendingAuthorizationTabIds[tab.guid] = provider
                AppLogInfo("[AISettings] Captured OAuth authorization tab provider=\(provider) tabId=\(tab.guid)")
                return
            }
        }

        AppLogDebug("[AISettings] OAuth authorization tab id not available yet provider=\(provider) tabGuid=\(tabGuid)")
    }

    private func removePendingAuthorizationTabIds(provider: String) {
        pendingAuthorizationTabIds = pendingAuthorizationTabIds.filter { $0.value != provider }
    }

    private func closePendingAuthorizationTab(provider: String) {
        guard let tabGuid = pendingAuthorizationTabGuids[provider] else {
            AppLogWarn("[AISettings] Unable to close OAuth authorization tab because expected guid is missing provider=\(provider)")
            removePendingAuthorizationTabIds(provider: provider)
            return
        }
        pendingAuthorizationTabGuids[provider] = nil

        var tabsToClose: [(tab: Tab, reason: String)] = []
        var collectedTabIds = Set<Int>()
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            let tabSnapshots = controller.browserState.tabs.map {
                "id=\($0.guid) localGuid=\($0.guidInLocalDB ?? "nil") url=\($0.url ?? "nil")"
            }.joined(separator: " | ")
            AppLogInfo(
                "[AISettings] Searching OAuth authorization tab " +
                "provider=\(provider) expectedGuid=\(tabGuid) " +
                "windowId=\(controller.windowId) tabs=[\(tabSnapshots)]"
            )

            for tab in controller.browserState.tabs {
                guard collectedTabIds.insert(tab.guid).inserted else { continue }
                if Self.isNativeFinishedTab(tab, provider: provider) {
                    tabsToClose.append((tab, "native-finished"))
                } else if Self.isOAuthCallbackTab(tab, provider: provider) {
                    tabsToClose.append((tab, "callback"))
                } else if tab.guidInLocalDB == tabGuid {
                    tabsToClose.append((tab, "guid"))
                }
            }
        }

        guard !tabsToClose.isEmpty else {
            removePendingAuthorizationTabIds(provider: provider)
            AppLogWarn("[AISettings] Unable to find OAuth authorization tab to close provider=\(provider) expectedGuid=\(tabGuid)")
            return
        }

        let inactiveTabs = tabsToClose.filter { !$0.tab.isActive }
        let activeTabs = tabsToClose.filter { $0.tab.isActive }
        for item in inactiveTabs + activeTabs {
            closeAuthorizationTab(item.tab, provider: provider, reason: item.reason)
        }
    }

    private func closeAuthorizationTab(_ tab: Tab, provider: String, reason: String) {
        AppLogInfo(
            "[AISettings] Closing OAuth authorization tab " +
            "provider=\(provider) reason=\(reason) " +
            "tabId=\(tab.guid) windowId=\(tab.windowId) " +
            "isActive=\(tab.isActive) localGuid=\(tab.guidInLocalDB ?? "nil") " +
            "url=\(tab.url ?? "nil")"
        )

        removePendingAuthorizationTabIds(provider: provider)
        tab.close()
    }

    private static func isNativeFinishedTab(_ tab: Tab, provider: String) -> Bool {
        isNativeFinishedURL(tab.url, provider: provider)
    }

    private static func isNativeFinishedURL(_ urlString: String?, provider: String) -> Bool {
        guard let components = oauthURLComponents(urlString) else { return false }
        let provider = provider.lowercased()
        let queryItems = components.queryItems ?? []
        let returnedProvider = queryItems.first(where: { $0.name == "provider" })?.value?.lowercased()
        let result = queryItems.first(where: { $0.name == "result" })?.value?.lowercased()
        return isAccountHost(components.host)
            && components.path == "/oauth/native-finished"
            && returnedProvider == provider
            && (result == nil || result == "success" || result == "failure")
    }

    private static func isOAuthCallbackTab(_ tab: Tab, provider: String) -> Bool {
        isOAuthCallbackURL(tab.url, provider: provider)
    }

    private static func isOAuthCallbackURL(_ urlString: String?, provider: String) -> Bool {
        guard let components = oauthURLComponents(urlString) else { return false }
        let provider = provider.lowercased()
        return isAccountHost(components.host)
            && components.path.lowercased() == "/api/oauth/callback/\(provider)"
    }

    private static func isAuthorizationTab(_ tab: Tab, provider: String) -> Bool {
        isOAuthURL(tab.url, provider: provider, expectedGuid: nil, localGuid: tab.guidInLocalDB)
    }

    private static func isOAuthURL(_ urlString: String?, provider: String, expectedGuid: String?, localGuid: String?) -> Bool {
        if let expectedGuid, localGuid == expectedGuid {
            return true
        }

        guard let url = urlString?.lowercased() else { return false }
        let provider = provider.lowercased()
        return isOAuthCallbackURL(urlString, provider: provider)
            || isNativeFinishedURL(urlString, provider: provider)
            || url.contains("\(provider).com/oauth")
            || (provider == "google" && url.contains("accounts.google.com"))
            || (provider == "slack" && url.contains(".slack.com/oauth"))
            || (provider == "notion" && url.contains("api.notion.com/v1/oauth/authorize"))
    }

    private static func oauthURLComponents(_ urlString: String?) -> URLComponents? {
        guard let urlString else { return nil }
        return URLComponents(string: urlString)
    }

    private static func isAccountHost(_ host: String?) -> Bool {
        let host = host?.lowercased()
        return host == "account.phibrowser.com" || host == "account.stag.phibrowser.com"
    }

    private func updateConnectorStates() {
        for connector in connectors {
            let connection = oauthConnections.first { $0.provider == connector.template.provider }
            connector.updateConnection(connection)
        }
    }

    func disconnectAll() {
        cancelAllPendingAuthorizationPolls()

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

private final class NotificationObserver {
    private let observer: NSObjectProtocol

    init(_ observer: NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }
}
