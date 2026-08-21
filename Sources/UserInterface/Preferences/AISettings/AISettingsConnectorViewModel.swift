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
            lastSyncTime = NSLocalizedString("settings.ai.connectors.lastSync.notConnectedStatus", value: "Not connected", comment: "AI settings - Last-sync text when connector is not connected")
            return
        }
        lastSyncTime = Self.formatSyncTime(connectedAt: connectedAt)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func formatSyncTime(
        connectedAt: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let date = iso8601Formatter.date(from: connectedAt)
                ?? ISO8601DateFormatter().date(from: connectedAt) else {
            return NSLocalizedString("settings.ai.connectors.lastSync.invalidDateFallback", value: "Not connected", comment: "AI settings - Fallback last-sync text when the connection date is invalid")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var actionTitle: String {
        status.isConnected
        ? NSLocalizedString("settings.ai.connectors.disconnectButton", value: "Disconnect", comment: "AI settings - Button to disconnect an external data connector")
        : NSLocalizedString("settings.ai.connectors.connectButton", value: "Connect", comment: "AI settings - Button to connect an external data connector")
    }
}

// MARK: - AISettingsConnectorViewModel

@Observable
@MainActor
final class AISettingsConnectorViewModel {
    private struct OAuthAuthorizationAttempt: Hashable {
        let profileId: String
        let provider: String
    }

    var connectors: [ConnectorItemState]
    private(set) var selectedProfileId: String?
    private let apiClient = APIClient.shared
    private var oauthConnections: [OAuthConnection] = []
    private var isRefreshingConnections = false
    private var pendingAuthorizationPolls: [OAuthAuthorizationAttempt: Task<Void, Never>] = [:]
    private var pendingAuthorizationTabGuids: [OAuthAuthorizationAttempt: String] = [:]
    private var pendingAuthorizationTabIds: [Int: OAuthAuthorizationAttempt] = [:]
    private var connectionAttemptsInProgress: Set<OAuthAuthorizationAttempt> = []
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
        guard ApplicationState.shared.isAuthenticated else { return }
        AppLogDebug("[AISettings] Starting to load OAuth connections...")
        loadConnections()
    }

    /// Chooses the profile whose connector state this settings pane manages.
    /// The selection is independent from the currently focused browser window
    /// so a user can manage connectors for every browser profile in one place.
    func prepareProfileSelection(availableProfileIds: [String], preferredProfileId: String?) {
        let selectedProfileIsAvailable = selectedProfileId.map { availableProfileIds.contains($0) } ?? false
        let preferredProfileIsAvailable = preferredProfileId.map { availableProfileIds.contains($0) } ?? false
        let targetProfileId = selectedProfileIsAvailable
            ? selectedProfileId
            : (preferredProfileIsAvailable ? preferredProfileId : availableProfileIds.first)

        guard selectedProfileId != targetProfileId else { return }
        cancelAllPendingAuthorizationPolls()
        selectedProfileId = targetProfileId
        resetDisplayedConnections()
        refreshConnections()
    }

    func selectProfile(_ profileId: String) {
        guard selectedProfileId != profileId else { return }
        selectedProfileId = profileId
        cancelAllPendingAuthorizationPolls()
        resetDisplayedConnections()
        refreshConnections()
    }

    func refreshConnections() {
        guard ApplicationState.shared.isAuthenticated else {
            suspendForUnauthenticatedAccess()
            return
        }
        guard selectedProfileId != nil else {
            resetDisplayedConnections()
            return
        }
        loadConnections()
    }

    func refreshConnection(for connector: ConnectorItemState) {
        guard ApplicationState.shared.isAuthenticated else {
            suspendForUnauthenticatedAccess()
            return
        }
        guard let profileId = selectedProfileId else { return }
        let attempt = OAuthAuthorizationAttempt(profileId: profileId, provider: connector.template.provider)
        connector.errorMessage = nil
        connector.isLoading = true
        Task { @MainActor in
            await reloadConnectionsFromNetwork(profileId: profileId)
            if connector.status.isConnected {
                finishPendingAuthorization(attempt: attempt, closeTab: true)
            } else {
                connector.isLoading = false
            }
        }
    }

    func handleOAuthReturn(provider: String, result: String, error: String?, profileId: String? = nil) {
        guard ApplicationState.shared.isAuthenticated else {
            suspendForUnauthenticatedAccess()
            return
        }
        guard let selectedProfileId,
              profileId == nil || profileId == selectedProfileId else { return }
        let attempt = OAuthAuthorizationAttempt(profileId: selectedProfileId, provider: provider)
        guard pendingAuthorizationPolls[attempt] != nil || pendingAuthorizationTabGuids[attempt] != nil else { return }
        cancelPendingAuthorizationPoll(attempt: attempt)
        pendingAuthorizationTabGuids[attempt] = nil
        removePendingAuthorizationTabIds(attempt: attempt)

        if result.lowercased() != "success",
           let connector = connectors.first(where: { $0.template.provider == provider }) {
            connectionAttemptsInProgress.remove(attempt)
            connector.errorMessage = error ?? NSLocalizedString("settings.ai.connectors.authorization.failureMessage", value: "Connector authorization failed.", comment: "AI settings - OAuth authorization failure")
        }

        setConnectorLoading(provider: provider, isLoading: false)
        setConnectorAuthorizationPending(provider: provider, isPending: false)

        Task { @MainActor in
            await reloadConnectionsFromNetwork(profileId: selectedProfileId)
        }
    }

    private func loadConnections(useCache: Bool = true) {
        guard ApplicationState.shared.isAuthenticated else { return }
        guard let profileId = selectedProfileId, !profileId.isEmpty else { return }

        if useCache, let cached = loadCachedConnections(profileId: profileId) {
            oauthConnections = cached
            updateConnectorStates()
            AppLogDebug("[AISettings] Loaded \(cached.count) cached OAuth connections")
        }

        setAllLoading(true)

        Task { @MainActor in
            await reloadConnectionsFromNetwork(profileId: profileId)
        }
    }

    private func reloadConnectionsFromNetwork(profileId: String) async {
        guard ApplicationState.shared.isAuthenticated else { return }
        guard !isRefreshingConnections else {
            reloadAfterCurrentRequest = true
            return
        }
        isRefreshingConnections = true
        defer {
            isRefreshingConnections = false
            clearFinishedLoadingStates()
            if reloadAfterCurrentRequest {
                reloadAfterCurrentRequest = false
                Task { @MainActor in
                    guard let selectedProfileId = selectedProfileId else { return }
                    await reloadConnectionsFromNetwork(profileId: selectedProfileId)
                }
            }
        }

        do {
            let response = try await apiClient.getOAuthConnections(profileId: profileId)
            guard ApplicationState.shared.isAuthenticated else { return }
            guard selectedProfileId == profileId else { return }
            let connections = response.data.connections
            let newlyConnectedProviders = Set(
                connections.lazy.filter(\.connected).map {
                    OAuthAuthorizationAttempt(profileId: profileId, provider: $0.provider)
                }
            ).intersection(connectionAttemptsInProgress)
            if !newlyConnectedProviders.isEmpty {
                FirstTimeActionTracker.capture(.connectorConnected)
                connectionAttemptsInProgress.subtract(newlyConnectedProviders)
            }
            oauthConnections = connections
            cacheConnections(connections, profileId: profileId)
            updateConnectorStates()
            recordConnections(connections)
            AppLogDebug("[AISettings] Fetched \(connections.count) OAuth connections from network")
        } catch {
            AppLogError("[AISettings] Error loading OAuth connections: \(error)")
        }
    }

    func toggleConnection(for connector: ConnectorItemState) {
        guard ApplicationState.shared.isAuthenticated else {
            suspendForUnauthenticatedAccess()
            return
        }
        guard selectedProfileId != nil else { return }
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
        guard ApplicationState.shared.isAuthenticated,
              let profileId = selectedProfileId,
              !profileId.isEmpty else { return }
        let provider = connector.template.provider
        let attempt = OAuthAuthorizationAttempt(profileId: profileId, provider: provider)
        closePendingAuthorizationTab(attempt: attempt)
        cancelPendingAuthorizationPoll(attempt: attempt)
        connectionAttemptsInProgress.insert(attempt)
        connector.isLoading = true
        connector.isAuthorizationPending = true

        Task { @MainActor in
            do {
                let response = try await apiClient.getOAuthAuthorization(
                    provider: provider,
                    successRedirect: apiClient.oauthNativeFinishedRedirect(provider: provider, result: "success", profileId: profileId),
                    failureRedirect: apiClient.oauthNativeFinishedRedirect(provider: provider, result: "failure", profileId: profileId),
                    profileId: profileId
                )
                guard selectedProfileId == profileId else { return }
                let tabGuid = Self.oauthTabGuid()
                guard openAuthorizationURL(response.data.authURL, attempt: attempt, tabGuid: tabGuid) else {
                    connectionAttemptsInProgress.remove(attempt)
                    connector.isAuthorizationPending = false
                    return
                }
                pendingAuthorizationTabGuids[attempt] = tabGuid
                capturePendingAuthorizationTabId(attempt: attempt, tabGuid: tabGuid)
                startPendingAuthorizationPoll(attempt: attempt)
                AppLogInfo("[AISettings] Started OAuth authorization flow for profile=\(profileId) provider=\(provider)")
            } catch {
                guard selectedProfileId == profileId else { return }
                connectionAttemptsInProgress.remove(attempt)
                connector.isLoading = false
                connector.isAuthorizationPending = false
                connector.errorMessage = error.localizedDescription
                AppLogWarn("[AISettings] Failed to connect provider \(connector.template.provider): \(error)")
            }
        }
    }

    private func disconnect(_ connector: ConnectorItemState) {
        guard ApplicationState.shared.isAuthenticated,
              let profileId = selectedProfileId,
              !profileId.isEmpty else { return }
        let attempt = OAuthAuthorizationAttempt(profileId: profileId, provider: connector.template.provider)
        connectionAttemptsInProgress.remove(attempt)
        cancelPendingAuthorizationPoll(attempt: attempt)
        connector.isLoading = true

        Task { @MainActor in
            defer {
                connector.isLoading = false
                connector.isAuthorizationPending = false
            }
            do {
                let provider = connector.template.provider
                _ = try await apiClient.deleteOAuthToken(provider: provider, profileId: profileId)
                AppLogInfo("[AISettings] Disconnected OAuth provider: \(provider)")
            } catch {
                connector.errorMessage = error.localizedDescription
                AppLogWarn("[AISettings] Failed to disconnect provider \(connector.template.provider): \(error)")
            }

            await reloadConnectionsFromNetwork(profileId: profileId)
        }
    }

    private func setAllLoading(_ isLoading: Bool) {
        for connector in connectors {
            connector.isLoading = isLoading
        }
    }

    private func clearFinishedLoadingStates() {
        guard let profileId = selectedProfileId else {
            setAllLoading(false)
            return
        }
        for connector in connectors where pendingAuthorizationPolls[
            OAuthAuthorizationAttempt(profileId: profileId, provider: connector.template.provider)
        ] == nil {
            connector.isLoading = false
        }
    }

    private func setConnectorLoading(provider: String, isLoading: Bool) {
        connectors.first { $0.template.provider == provider }?.isLoading = isLoading
    }

    private func setConnectorAuthorizationPending(provider: String, isPending: Bool) {
        connectors.first { $0.template.provider == provider }?.isAuthorizationPending = isPending
    }

    private func openAuthorizationURL(_ authURLString: String, attempt: OAuthAuthorizationAttempt, tabGuid: String) -> Bool {
        guard ApplicationState.shared.isAuthenticated else { return false }
        guard let authURL = URL(string: authURLString),
              let scheme = authURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            connectors.first { $0.template.provider == attempt.provider }?.errorMessage =
                NSLocalizedString("settings.ai.connectors.authorization.invalidURLError", value: "The connector authorization URL is invalid.", comment: "AI settings - OAuth authorization URL error")
            setConnectorLoading(provider: attempt.provider, isLoading: false)
            return false
        }

        guard let browserState = MainBrowserWindowControllersManager.shared.getAllWindows()
            .map(\.browserState)
            .first(where: { $0.profileId == attempt.profileId }) else {
            connectors.first { $0.template.provider == attempt.provider }?.errorMessage =
                NSLocalizedString("settings.ai.connectors.authorization.openProfileFailure", value: "Open a browser window for the selected Profile to continue.", comment: "AI settings - OAuth authorization requires an open window for the selected browser Profile")
            setConnectorLoading(provider: attempt.provider, isLoading: false)
            return false
        }

        browserState.createTab(authURL.absoluteString, customGuid: tabGuid, focusAfterCreate: true)
        return true
    }

    private static func oauthTabGuid() -> String {
        "oauth-connector-\(UUID().uuidString)"
    }

    private func startPendingAuthorizationPoll(attempt: OAuthAuthorizationAttempt) {
        guard ApplicationState.shared.isAuthenticated else { return }
        pendingAuthorizationPolls[attempt]?.cancel()
        pendingAuthorizationPolls[attempt] = nil

        pendingAuthorizationPolls[attempt] = Task { @MainActor in
            let maxAttempts = 60
            for pollAttempt in 1...maxAttempts {
                guard !Task.isCancelled,
                      ApplicationState.shared.isAuthenticated,
                      selectedProfileId == attempt.profileId else { return }
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard !Task.isCancelled,
                      ApplicationState.shared.isAuthenticated,
                      selectedProfileId == attempt.profileId else { return }

                if let tabGuid = pendingAuthorizationTabGuids[attempt] {
                    capturePendingAuthorizationTabId(attempt: attempt, tabGuid: tabGuid)
                }
                await reloadConnectionsFromNetwork(profileId: attempt.profileId)
                if connectors.first(where: { $0.template.provider == attempt.provider })?.status.isConnected == true {
                    finishPendingAuthorization(attempt: attempt, closeTab: true)
                    AppLogInfo("[AISettings] OAuth authorization connected for profile=\(attempt.profileId) provider=\(attempt.provider)")
                    return
                }

                AppLogDebug("[AISettings] OAuth authorization polling attempt \(pollAttempt) for profile=\(attempt.profileId) provider=\(attempt.provider)")
            }

            AppLogWarn("[AISettings] OAuth authorization polling timed out for profile=\(attempt.profileId) provider=\(attempt.provider)")
            connectionAttemptsInProgress.remove(attempt)
            pendingAuthorizationPolls[attempt] = nil
            pendingAuthorizationTabGuids[attempt] = nil
            removePendingAuthorizationTabIds(attempt: attempt)
            setConnectorLoading(provider: attempt.provider, isLoading: false)
            setConnectorAuthorizationPending(provider: attempt.provider, isPending: false)
        }
    }

    private func cancelPendingAuthorizationPoll(attempt: OAuthAuthorizationAttempt) {
        pendingAuthorizationPolls[attempt]?.cancel()
        pendingAuthorizationPolls[attempt] = nil
        pendingAuthorizationTabGuids[attempt] = nil
        removePendingAuthorizationTabIds(attempt: attempt)
        setConnectorAuthorizationPending(provider: attempt.provider, isPending: false)
    }

    private func cancelAllPendingAuthorizationPolls() {
        for poll in pendingAuthorizationPolls.values {
            poll.cancel()
        }
        pendingAuthorizationPolls.removeAll()
        pendingAuthorizationTabGuids.removeAll()
        pendingAuthorizationTabIds.removeAll()
        connectionAttemptsInProgress.removeAll()
        clearFinishedLoadingStates()
    }

    private func finishPendingAuthorization(attempt: OAuthAuthorizationAttempt, closeTab: Bool) {
        pendingAuthorizationPolls[attempt]?.cancel()
        pendingAuthorizationPolls[attempt] = nil
        setConnectorLoading(provider: attempt.provider, isLoading: false)
        setConnectorAuthorizationPending(provider: attempt.provider, isPending: false)
        if closeTab {
            closePendingAuthorizationTab(attempt: attempt)
        } else {
            pendingAuthorizationTabGuids[attempt] = nil
            removePendingAuthorizationTabIds(attempt: attempt)
        }
    }

    private func handleBrowserTabClosed(tabId: Int, localGuid: String?, url: String?) {
        guard ApplicationState.shared.isAuthenticated else { return }
        guard let attempt = pendingAuthorizationAttempt(tabId: tabId, localGuid: localGuid, url: url) else { return }
        AppLogInfo(
            "[AISettings] OAuth authorization tab closed " +
            "profile=\(attempt.profileId) provider=\(attempt.provider) tabId=\(tabId) localGuid=\(localGuid ?? "nil") url=\(url ?? "nil")"
        )
        Task { @MainActor in
            guard selectedProfileId == attempt.profileId else { return }
            await reloadConnectionsFromNetwork(profileId: attempt.profileId)
            if connectors.first(where: { $0.template.provider == attempt.provider })?.status.isConnected == true {
                finishPendingAuthorization(attempt: attempt, closeTab: false)
            } else {
                connectionAttemptsInProgress.remove(attempt)
                cancelPendingAuthorizationPoll(attempt: attempt)
                setConnectorLoading(provider: attempt.provider, isLoading: false)
            }
        }
    }

    private func pendingAuthorizationAttempt(tabId: Int, localGuid: String?, url: String?) -> OAuthAuthorizationAttempt? {
        if let attempt = pendingAuthorizationTabIds[tabId] {
            return attempt
        }

        for (attempt, expectedGuid) in pendingAuthorizationTabGuids {
            if localGuid == expectedGuid {
                return attempt
            }
            if Self.isOAuthCallbackURL(url, provider: attempt.provider)
                || Self.isNativeFinishedURL(url, provider: attempt.provider) {
                return attempt
            }
        }

        return nil
    }

    private func capturePendingAuthorizationTabId(attempt: OAuthAuthorizationAttempt, tabGuid: String) {
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            guard controller.browserState.profileId == attempt.profileId else { continue }
            if let tab = controller.browserState.tabs.first(where: {
                $0.guidInLocalDB == tabGuid || Self.isAuthorizationTab($0, provider: attempt.provider)
            }) {
                pendingAuthorizationTabIds[tab.guid] = attempt
                AppLogInfo("[AISettings] Captured OAuth authorization tab profile=\(attempt.profileId) provider=\(attempt.provider) tabId=\(tab.guid)")
                return
            }
        }

        AppLogDebug("[AISettings] OAuth authorization tab id not available yet profile=\(attempt.profileId) provider=\(attempt.provider) tabGuid=\(tabGuid)")
    }

    private func removePendingAuthorizationTabIds(attempt: OAuthAuthorizationAttempt) {
        pendingAuthorizationTabIds = pendingAuthorizationTabIds.filter { $0.value != attempt }
    }

    private func closePendingAuthorizationTab(attempt: OAuthAuthorizationAttempt) {
        guard let tabGuid = pendingAuthorizationTabGuids[attempt] else {
            AppLogWarn("[AISettings] Unable to close OAuth authorization tab because expected guid is missing profile=\(attempt.profileId) provider=\(attempt.provider)")
            removePendingAuthorizationTabIds(attempt: attempt)
            return
        }
        pendingAuthorizationTabGuids[attempt] = nil

        var tabsToClose: [(tab: Tab, reason: String)] = []
        var collectedTabIds = Set<Int>()
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            guard controller.browserState.profileId == attempt.profileId else { continue }
            let tabSnapshots = controller.browserState.tabs.map {
                "id=\($0.guid) localGuid=\($0.guidInLocalDB ?? "nil") url=\($0.url ?? "nil")"
            }.joined(separator: " | ")
            AppLogInfo(
                "[AISettings] Searching OAuth authorization tab " +
                "profile=\(attempt.profileId) provider=\(attempt.provider) expectedGuid=\(tabGuid) " +
                "windowId=\(controller.windowId) tabs=[\(tabSnapshots)]"
            )

            for tab in controller.browserState.tabs {
                guard collectedTabIds.insert(tab.guid).inserted else { continue }
                if Self.isNativeFinishedTab(tab, provider: attempt.provider) {
                    tabsToClose.append((tab, "native-finished"))
                } else if Self.isOAuthCallbackTab(tab, provider: attempt.provider) {
                    tabsToClose.append((tab, "callback"))
                } else if tab.guidInLocalDB == tabGuid {
                    tabsToClose.append((tab, "guid"))
                }
            }
        }

        guard !tabsToClose.isEmpty else {
            removePendingAuthorizationTabIds(attempt: attempt)
            AppLogWarn("[AISettings] Unable to find OAuth authorization tab to close profile=\(attempt.profileId) provider=\(attempt.provider) expectedGuid=\(tabGuid)")
            return
        }

        let inactiveTabs = tabsToClose.filter { !$0.tab.isActive }
        let activeTabs = tabsToClose.filter { $0.tab.isActive }
        for item in inactiveTabs + activeTabs {
            closeAuthorizationTab(item.tab, attempt: attempt, reason: item.reason)
        }
    }

    private func closeAuthorizationTab(_ tab: Tab, attempt: OAuthAuthorizationAttempt, reason: String) {
        AppLogInfo(
            "[AISettings] Closing OAuth authorization tab " +
            "profile=\(attempt.profileId) provider=\(attempt.provider) reason=\(reason) " +
            "tabId=\(tab.guid) windowId=\(tab.windowId) " +
            "isActive=\(tab.isActive) localGuid=\(tab.guidInLocalDB ?? "nil") " +
            "url=\(tab.url ?? "nil")"
        )

        removePendingAuthorizationTabIds(attempt: attempt)
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
        guard ApplicationState.shared.isAuthenticated else {
            suspendForUnauthenticatedAccess()
            return
        }
        guard let profileId = selectedProfileId, !profileId.isEmpty else { return }
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
                    _ = try await apiClient.deleteOAuthToken(provider: provider, profileId: profileId)
                    AppLogInfo("[AISettings] Disconnected OAuth provider: \(provider)")
                } catch {
                    AppLogWarn("[AISettings] Failed to disconnect provider \(provider): \(error)")
                }
            }
            await reloadConnectionsFromNetwork(profileId: profileId)
        }
    }

    func suspendForUnauthenticatedAccess() {
        cancelAllPendingAuthorizationPolls()
        oauthConnections = []
        isRefreshingConnections = false
        for connector in connectors {
            connector.updateConnection(nil)
            connector.isLoading = false
            connector.isAuthorizationPending = false
            connector.errorMessage = nil
        }
    }

    // MARK: - Cache

    private var reloadAfterCurrentRequest = false

    private func resetDisplayedConnections() {
        oauthConnections = []
        for connector in connectors {
            connector.errorMessage = nil
            connector.updateConnection(nil)
        }
    }

    private func loadCachedConnections(profileId: String?) -> [OAuthConnection]? {
        guard ApplicationState.shared.isAuthenticated else { return nil }
        guard let userDefaults = AccountController.shared.account?.userDefaults else { return nil }
        return userDefaults.codableValue(forKey: cacheKey(profileId: profileId))
    }

    private func cacheConnections(_ connections: [OAuthConnection], profileId: String?) {
        guard ApplicationState.shared.isAuthenticated else { return }
        guard let userDefaults = AccountController.shared.account?.userDefaults else { return }
        userDefaults.set(connections, forCodableKey: cacheKey(profileId: profileId))
    }

    private func cacheKey(profileId: String?) -> String {
        guard let profileId, !profileId.isEmpty else {
            return AccountUserDefaults.DefaultsKey.cachedUserConnectors.rawValue
        }
        return "\(AccountUserDefaults.DefaultsKey.cachedUserConnectors.rawValue).\(profileId)"
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
