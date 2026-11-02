// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// Instances persist across refreshes because the outline holds item identity; cells follow the published values.
final class LiveFolderSidebarItem: NSObject, SidebarItem, ContextMenuRepresentable, ObservableObject {
    @Published private(set) var data: LiveFolderData
    @Published private(set) var isRefreshing = false
    private(set) var rowItems: [SidebarItem] = []

    let spaceId: String
    weak var browserState: BrowserState?
    private var knownRows: [String: LiveFolderRowItem] = [:]
    private var signInItem: LiveFolderSignInItem?

    init(data: LiveFolderData, spaceId: String, browserState: BrowserState) {
        self.data = data
        self.spaceId = spaceId
        self.browserState = browserState
        super.init()
        update(data, isRefreshing: false)
    }

    func update(_ data: LiveFolderData, isRefreshing: Bool) {
        self.data = data
        self.isRefreshing = isRefreshing

        var items: [SidebarItem] = []
        if let target = Self.signInTarget(for: data) {
            let item = signInItem ?? LiveFolderSignInItem(folder: self)
            item.target = target
            signInItem = item
            items.append(item)
        } else {
            signInItem = nil
        }

        var rows: [String: LiveFolderRowItem] = [:]
        for row in data.rows {
            let item = knownRows[row.id] ?? LiveFolderRowItem(row: row, folder: self)
            item.row = row
            rows[row.id] = item
            items.append(item)
        }
        knownRows = rows
        rowItems = items
    }

    static func signInTarget(for data: LiveFolderData) -> LiveFolderSignInItem.Target? {
        if data.lastError == .notSignedIn {
            return .init(
                title: NSLocalizedString("sidebar.liveFolder.signInAction", value: "Sign in to GitHub", comment: "Sidebar live folder - Row shown when the user isn't signed in to GitHub in this profile"),
                url: "https://github.com/login?return_to=%2Fpulls"
            )
        }
        guard data.lastError == nil, let organization = data.ssoOrganizations.first else { return nil }
        return .init(
            title: String(
                format: NSLocalizedString("sidebar.liveFolder.ssoAction", value: "Sign in to %@ with SSO", comment: "Sidebar live folder - Row shown when an organization hides its pull requests until a single sign-on. %@ is the organization name"),
                organization
            ),
            url: "https://github.com/orgs/\(organization)/sso"
        )
    }

    var statusText: String? {
        switch data.lastError {
        case .rateLimited:
            return NSLocalizedString("sidebar.liveFolder.rateLimitedStatus", value: "GitHub is limiting requests. Trying again shortly.", comment: "Sidebar live folder - Tooltip when GitHub rate limits a refresh")
        case .network, .unexpectedPage:
            return NSLocalizedString("sidebar.liveFolder.failedStatus", value: "Failed to update", comment: "Sidebar live folder - Tooltip when a refresh fails")
        case .notSignedIn, nil:
            return nil
        }
    }

    // MARK: SidebarItem

    var id: AnyHashable { "live-folder:\(spaceId)" }
    var title: String {
        NSLocalizedString("sidebar.liveFolder.title", value: "Pull Requests", comment: "Sidebar live folder - Name of the folder listing the user's GitHub pull requests")
    }
    var url: String? { nil }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { true }
    var hasChildren: Bool { !rowItems.isEmpty }
    var childrenItems: [SidebarItem] { rowItems }
    var depth: Int { 0 }
    var itemType: SidebarItemType { .liveFolder }
    var isActive: Bool { false }
    var isSelectable: Bool { false }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        owner?.toggleItemExpanded(self)
    }

    // MARK: Context menu

    @MainActor func makeContextMenu(on menu: NSMenu) {
        let manager = LiveFolderManager.shared
        addItem(to: menu, title: NSLocalizedString("sidebar.liveFolder.refreshAction", value: "Refresh", comment: "Sidebar live folder menu - Fetch the pull requests again"), action: #selector(refresh))
        addItem(to: menu, title: NSLocalizedString("sidebar.liveFolder.copyLinksAction", value: "Copy All Links as Markdown", comment: "Sidebar live folder menu - Copy every pull request as a Markdown link"), action: data.rows.isEmpty ? nil : #selector(copyLinks))

        menu.addItem(.separator())
        let kinds: [(GitHubLiveFilter.Attributes, String)] = [
            (.authored, NSLocalizedString("sidebar.liveFolder.filterAuthored", value: "Created by Me", comment: "Sidebar live folder menu - Toggle showing pull requests the user created")),
            (.reviewRequests, NSLocalizedString("sidebar.liveFolder.filterReviewRequests", value: "Review Requests", comment: "Sidebar live folder menu - Toggle showing pull requests where the user was asked for a review")),
            (.teamReviewRequests, NSLocalizedString("sidebar.liveFolder.filterTeamReviewRequests", value: "Team Review Requests", comment: "Sidebar live folder menu - Toggle showing pull requests where one of the user's teams was asked for a review")),
        ]
        for (attribute, title) in kinds {
            let item = addItem(to: menu, title: title, action: #selector(toggleAttribute(_:)))
            item.representedObject = attribute.rawValue
            item.state = data.filter.attributes.contains(attribute) ? .on : .off
        }

        let repositoriesItem = NSMenuItem(
            title: NSLocalizedString("sidebar.liveFolder.repositoriesSubmenu", value: "Repositories", comment: "Sidebar live folder menu - Submenu choosing which repositories' pull requests show"),
            action: nil,
            keyEquivalent: ""
        )
        repositoriesItem.submenu = makeRepositoriesMenu(repositories: manager.repositories[spaceId] ?? [])
        menu.addItem(repositoriesItem)

        menu.addItem(.separator())
        addItem(to: menu, title: NSLocalizedString("sidebar.liveFolder.deleteAction", value: "Delete Live Folder", comment: "Sidebar live folder menu - Delete the folder from this Space"), action: #selector(deleteFolder))
    }

    private func makeRepositoriesMenu(repositories: [String]) -> NSMenu {
        let submenu = NSMenu()
        let note = NSMenuItem(
            title: NSLocalizedString("sidebar.liveFolder.repositoriesNote", value: "Based on your active pull requests", comment: "Sidebar live folder menu - Explains where the repository list comes from"),
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        submenu.addItem(note)
        let hidden = Set(data.filter.hiddenRepositories.map { $0.lowercased() })
        for repository in repositories {
            let item = addItem(to: submenu, title: repository, action: #selector(toggleRepository(_:)))
            item.representedObject = repository
            item.state = hidden.contains(repository.lowercased()) ? .off : .on
        }
        return submenu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @MainActor @objc private func refresh() {
        LiveFolderManager.shared.refreshRequestedByUser(inSpace: spaceId)
    }

    @objc private func copyLinks() {
        let links = data.rows.map { "- [\($0.title)](\($0.url))" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links, forType: .string)
    }

    @MainActor @objc private func toggleAttribute(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int else { return }
        LiveFolderManager.shared.setAttribute(
            GitHubLiveFilter.Attributes(rawValue: rawValue),
            enabled: sender.state != .on,
            inSpace: spaceId
        )
    }

    @MainActor @objc private func toggleRepository(_ sender: NSMenuItem) {
        guard let repository = sender.representedObject as? String else { return }
        LiveFolderManager.shared.setRepository(repository, hidden: sender.state == .on, inSpace: spaceId)
    }

    @MainActor @objc private func deleteFolder() {
        browserState?.deleteLiveFolder()
    }
}

final class LiveFolderRowItem: NSObject, SidebarItem, ContextMenuRepresentable, ObservableObject {
    @Published var row: LiveFolderRow
    private weak var folder: LiveFolderSidebarItem?

    init(row: LiveFolderRow, folder: LiveFolderSidebarItem) {
        self.row = row
        self.folder = folder
    }

    var browserState: BrowserState? { folder?.browserState }

    var id: AnyHashable { row.tabMarker }
    var title: String { row.title }
    var url: String? { row.url }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { false }
    var hasChildren: Bool { false }
    var childrenItems: [SidebarItem] { [] }
    var depth: Int { 1 }
    var itemType: SidebarItemType { .liveFolderRow }
    var isActive: Bool {
        guard let state = browserState else { return false }
        return state.focusingTab?.guidInLocalDB == row.tabMarker
    }
    var isSelectable: Bool { true }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        MainActor.assumeIsolated { browserState?.openLiveFolderRow(row) }
    }

    @MainActor func removeFromFolder() {
        browserState?.removeLiveFolderRow(row)
    }

    @MainActor func makeContextMenu(on menu: NSMenu) {
        let copy = NSMenuItem(
            title: NSLocalizedString("sidebar.liveFolder.copyLinkAction", value: "Copy Link", comment: "Sidebar live folder row menu - Copy the pull request's address"),
            action: #selector(copyLink),
            keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)
        let remove = NSMenuItem(
            title: NSLocalizedString("sidebar.liveFolder.removeRowAction", value: "Remove from Folder", comment: "Sidebar live folder row menu - Hide this pull request and close its tab"),
            action: #selector(remove),
            keyEquivalent: ""
        )
        remove.target = self
        menu.addItem(remove)
    }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.url, forType: .string)
    }

    @MainActor @objc private func remove() {
        removeFromFolder()
    }
}

final class LiveFolderSignInItem: NSObject, SidebarItem, ContextMenuRepresentable {
    struct Target: Equatable {
        var title: String
        var url: String
    }

    var target = Target(title: "", url: "")
    private weak var folder: LiveFolderSidebarItem?

    init(folder: LiveFolderSidebarItem) {
        self.folder = folder
    }

    var id: AnyHashable { "live-folder-sign-in" }
    var title: String { target.title }
    var url: String? { target.url }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { false }
    var hasChildren: Bool { false }
    var childrenItems: [SidebarItem] { [] }
    var depth: Int { 1 }
    var itemType: SidebarItemType { .liveFolderRow }
    var isActive: Bool { false }
    var isSelectable: Bool { false }
    var isBookmark: Bool { false }

    func performAction(with owner: SidebarTabListItemOwner?) {
        folder?.browserState?.createTab(target.url, customGuid: nil, focusAfterCreate: true)
    }

    /// Left empty on purpose: without it the row falls back to the tab area's menu.
    func makeContextMenu(on menu: NSMenu) {}
}
