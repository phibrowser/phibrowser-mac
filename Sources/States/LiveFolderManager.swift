// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// App-scoped because several windows can show one Space; tabs stay with `BrowserState`.
/// Only the active window's Space refreshes, since a fetch needs a tab of that Space's profile.
@MainActor
final class LiveFolderManager: ObservableObject {
    static let shared = LiveFolderManager()

    static let refreshInterval: TimeInterval = 120
    static let retryInterval: TimeInterval = 30
    static let minimumInterval: TimeInterval = 10
    private static let tickInterval: TimeInterval = 15
    private static let storageKey = "liveFolders"

    @Published private(set) var folders: [String: LiveFolderData] = [:]
    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var repositories: [String: [String]] = [:]

    private weak var loadedAccount: Account?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func folder(forSpace spaceId: String) -> LiveFolderData? {
        loadIfNeeded()
        return folders[spaceId]
    }

    func startIfNeeded() {
        guard timer == nil else { return }
        loadIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { LiveFolderManager.shared.tick() }
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, .activeBrowserWindowDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LiveFolderManager.shared.refreshActiveSpace() }
            })
        }
    }

    // MARK: Folder lifecycle

    func createFolder(inSpace spaceId: String) {
        loadIfNeeded()
        guard folders[spaceId] == nil else { return }
        folders[spaceId] = LiveFolderData()
        save()
        refreshActiveSpace(force: true)
    }

    func deleteFolder(inSpace spaceId: String) {
        loadIfNeeded()
        guard folders.removeValue(forKey: spaceId) != nil else { return }
        repositories[spaceId] = nil
        save()
    }

    // MARK: Editing

    func setAttribute(_ attribute: GitHubLiveFilter.Attributes, enabled: Bool, inSpace spaceId: String) {
        update(spaceId) { folder in
            if enabled {
                folder.filter.attributes.insert(attribute)
            } else {
                folder.filter.attributes.remove(attribute)
            }
        }
        refreshActiveSpace(force: true)
    }

    func setRepository(_ repository: String, hidden: Bool, inSpace spaceId: String) {
        update(spaceId) { $0.setRepository(repository, hidden: hidden) }
        if !hidden { refreshActiveSpace(force: true) }
    }

    func hideRow(url: String, inSpace spaceId: String) {
        update(spaceId) { $0.hide(url: url) }
    }

    func markRead(url: String, inSpace spaceId: String) {
        guard folder(forSpace: spaceId)?.rows.first(where: { $0.url == url })?.isUnread == true else { return }
        update(spaceId) { folder in
            guard let index = folder.rows.firstIndex(where: { $0.url == url }) else { return }
            folder.rows[index].isUnread = false
        }
    }

    func setExpanded(_ expanded: Bool, inSpace spaceId: String) {
        guard folder(forSpace: spaceId)?.isExpanded != expanded else { return }
        update(spaceId) { $0.isExpanded = expanded }
    }

    // MARK: Refresh

    func refreshActiveSpace(force: Bool = false) {
        guard NSApp.isActive || force, let state = activeBrowserState,
              let folder = folder(forSpace: state.spaceId) else { return }
        let elapsed = Date().timeIntervalSince(folder.lastFetch ?? .distantPast)
        let failing = folder.lastError != nil || folder.needsSignIn
        guard force || elapsed >= (failing ? Self.retryInterval : Self.refreshInterval) else { return }
        refresh(spaceId: state.spaceId, state: state)
    }

    func refreshRequestedByUser(inSpace spaceId: String) {
        guard let state = activeBrowserState, state.spaceId == spaceId,
              let folder = folder(forSpace: spaceId) else { return }
        let elapsed = Date().timeIntervalSince(folder.lastFetch ?? .distantPast)
        guard folder.lastError != nil || elapsed >= Self.minimumInterval else { return }
        refresh(spaceId: spaceId, state: state)
    }

    private var activeBrowserState: BrowserState? {
        guard let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState,
              !state.isIncognito else { return nil }
        return state
    }

    private func tick() {
        if let state = activeBrowserState {
            let openMarkers = Set(state.tabs.compactMap(\.guidInLocalDB).filter { LiveFolderRow.isTabMarker($0) })
            if var folder = folders[state.spaceId], folder.expireRows(openTabMarkers: openMarkers) {
                folders[state.spaceId] = folder
                save()
            }
        }
        refreshActiveSpace()
    }

    private func refresh(spaceId: String, state: BrowserState) {
        guard !refreshing.contains(spaceId), let folder = folders[spaceId] else { return }
        guard let anchor = (state.focusingTab.map { [$0] } ?? []).appending(contentsOf: state.tabs)
            .lazy.compactMap({ $0.webContentWrapper?.devToolsTargetId }).first(where: { !$0.isEmpty }) else {
            return
        }
        let attributes = [GitHubLiveFilter.Attributes.authored, .reviewRequests, .teamReviewRequests]
            .filter { folder.filter.attributes.contains($0) }
        refreshing.insert(spaceId)
        Task { @MainActor in
            let outcome = await Self.fetch(attributes: attributes, anchorTargetId: anchor)
            refreshing.remove(spaceId)
            switch outcome {
            case .success(let pages):
                let pullRequests = GitHubLiveClient.merge(pages)
                let organizations = Array(Set(pages.flatMap(\.1.ssoOrganizations))).sorted()
                update(spaceId) { $0.apply(pullRequests, ssoOrganizations: organizations) }
                guard let hidden = folders[spaceId]?.filter.hiddenRepositories else { return }
                repositories[spaceId] = Array(Set(pullRequests.map(\.repository) + hidden))
                    .sorted { $0.lowercased() < $1.lowercased() }
            case .failure(let error):
                // Never apply a partial result: it would empty rows only the failed search found.
                update(spaceId) { $0.applyFailure(error) }
            }
        }
    }

    private static func fetch(
        attributes: [GitHubLiveFilter.Attributes],
        anchorTargetId: String
    ) async -> Result<[(GitHubLiveFilter.Attributes, GitHubLiveClient.Page)], LiveFolderError> {
        guard !attributes.isEmpty else { return .success([]) }
        let fetcher: GitHubSessionFetcher
        do {
            fetcher = try await GitHubSessionFetcher.open(anchorTargetId: anchorTargetId)
        } catch {
            AppLogError("[LiveFolder] Could not open the GitHub session page: \(error)")
            return .failure(.network)
        }
        var pages: [(GitHubLiveFilter.Attributes, GitHubLiveClient.Page)] = []
        var failure: LiveFolderError?
        for attribute in attributes {
            switch await search(GitHubLiveClient.query(for: attribute), with: fetcher) {
            case .success(let page): pages.append((attribute, page))
            case .failure(let error): failure = failure == .notSignedIn ? failure : error
            }
        }
        await fetcher.close()
        if let failure { return .failure(failure) }
        return .success(pages)
    }

    private static func search(_ query: String, with fetcher: GitHubSessionFetcher) async -> Result<GitHubLiveClient.Page, LiveFolderError> {
        let pulls = await read(GitHubLiveClient.pullsURL(query: query), with: fetcher)
        if case .success(let page) = pulls, !page.pullRequests.isEmpty { return pulls }
        if case .failure(let error) = pulls, error != .unexpectedPage { return pulls }
        let search = await read(GitHubLiveClient.searchURL(query: query), with: fetcher)
        if case .success = search { return search }
        return pulls
    }

    private static func read(_ url: String, with fetcher: GitHubSessionFetcher) async -> Result<GitHubLiveClient.Page, LiveFolderError> {
        let response: GitHubSessionFetcher.Response
        do {
            response = try await fetcher.get(url, headers: GitHubLiveClient.jsonHeaders)
        } catch {
            AppLogError("[LiveFolder] Read failed: \(error)")
            return .failure(.network)
        }
        let result = GitHubLiveClient.read(status: response.status, finalURL: response.finalURL, body: response.body)
        if case .failure(let error) = result {
            AppLogError("[LiveFolder] GitHub answered \(response.status), \(response.body.utf8.count) bytes: \(error)")
        }
        return result
    }

    // MARK: Storage

    private func update(_ spaceId: String, _ change: (inout LiveFolderData) -> Void) {
        guard var folder = folder(forSpace: spaceId) else { return }
        change(&folder)
        guard folder != folders[spaceId] else { return }
        folders[spaceId] = folder
        save()
    }

    private func loadIfNeeded() {
        guard let account = AccountController.shared.localDataAccount, account !== loadedAccount else { return }
        loadedAccount = account
        let stored: [String: LiveFolderData] = account.userDefaults.codableValue(forKey: Self.storageKey) ?? [:]
        folders = stored.mapValues { $0.clearingStaleError() }
        repositories = [:]
    }

    private func save() {
        loadedAccount?.userDefaults.set(folders, forCodableKey: Self.storageKey)
    }
}

private extension Array {
    func appending(contentsOf other: [Element]) -> [Element] { self + other }
}
