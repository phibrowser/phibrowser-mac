// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

enum PhiScriptingTabScope: Equatable {
    case all
    case current
    case space(String)

    init(scope: String?, spaceId: String?) throws {
        switch scope?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "all" {
        case "all", "":
            self = .all
        case "current":
            self = .current
        case "space":
            guard let spaceId = Self.nonEmpty(spaceId) else {
                throw PhiScriptingError.invalidArgument
            }
            self = .space(spaceId)
        default:
            throw PhiScriptingError.invalidArgument
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum PhiScriptingError: Error, Equatable {
    case invalidArgument
    case noWindows
    case noActiveWindow
    case spaceNotFound
    case tabNotFound
    case operationFailed

    var code: String {
        switch self {
        case .invalidArgument: "invalid_argument"
        case .noWindows: "no_windows"
        case .noActiveWindow: "no_active_window"
        case .spaceNotFound: "space_not_found"
        case .tabNotFound: "tab_not_found"
        case .operationFailed: "operation_failed"
        }
    }

    var message: String {
        switch self {
        case .invalidArgument:
            "One or more command arguments are invalid."
        case .noWindows:
            "Phi has no open browser windows."
        case .noActiveWindow:
            "Phi has no active normal browser window."
        case .spaceNotFound:
            "The selected Space is no longer available."
        case .tabNotFound:
            "The selected tab or saved item is no longer available."
        case .operationFailed:
            "Phi could not complete the requested operation."
        }
    }
}

private func phiScriptingURLJSONObject(_ url: String?) -> Any {
    url.map(URLProcessor.phiBrandEnsuredUrlString) ?? NSNull()
}

struct PhiScriptingSpaceSnapshot: Equatable {
    let id: String
    let title: String
    let profileId: String
    let profileName: String
    let colorHex: String
    let iconData: String?
    let isActive: Bool
    let isOpen: Bool

    var jsonObject: [String: Any] {
        [
            "id": id,
            "title": title,
            "profileId": profileId,
            "profileName": profileName,
            "colorHex": colorHex,
            "iconData": iconData ?? NSNull(),
            "isActive": isActive,
            "isOpen": isOpen,
        ]
    }
}

struct PhiScriptingTabSnapshot: Equatable {
    let id: String
    let windowId: String
    let spaceId: String
    let title: String
    let url: String?
    let isActive: Bool
    let isPinned: Bool

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "windowId": windowId,
            "spaceId": spaceId,
            "title": title,
            "isActive": isActive,
            "isPinned": isPinned,
        ]
        object["url"] = phiScriptingURLJSONObject(url)
        return object
    }
}

struct PhiScriptingSavedPaneSnapshot: Equatable {
    let id: String
    let title: String
    let url: String?

    var jsonObject: [String: Any] {
        [
            "id": id,
            "title": title,
            "url": phiScriptingURLJSONObject(url),
        ]
    }
}

struct PhiScriptingPinnedTabSnapshot: Equatable {
    let id: String
    let scope: PinnedTabScope
    let ownerSpaceId: String?
    let spaceIds: [String]
    let title: String
    let url: String?
    let secondary: PhiScriptingSavedPaneSnapshot?

    var jsonObject: [String: Any] {
        [
            "id": id,
            "scope": scope.rawValue,
            "ownerSpaceId": ownerSpaceId ?? NSNull(),
            "spaceIds": spaceIds,
            "title": title,
            "url": phiScriptingURLJSONObject(url),
            "secondary": secondary?.jsonObject ?? NSNull(),
        ]
    }
}

struct PhiScriptingBookmarkSnapshot: Equatable {
    let id: String
    let spaceId: String
    let title: String
    let url: String?
    let secondary: PhiScriptingSavedPaneSnapshot?

    var jsonObject: [String: Any] {
        [
            "id": id,
            "spaceId": spaceId,
            "title": title,
            "url": phiScriptingURLJSONObject(url),
            "secondary": secondary?.jsonObject ?? NSNull(),
        ]
    }
}

struct PhiScriptingWindowSnapshot: Equatable {
    let id: String
    let spaceId: String
    let tabs: [PhiScriptingTabSnapshot]
}

struct PhiScriptingSnapshot: Equatable {
    let spaces: [PhiScriptingSpaceSnapshot]
    let windows: [PhiScriptingWindowSnapshot]
    let pinnedTabs: [PhiScriptingPinnedTabSnapshot]
    let bookmarks: [PhiScriptingBookmarkSnapshot]
    let activeWindowId: String?

    init(
        spaces: [PhiScriptingSpaceSnapshot],
        windows: [PhiScriptingWindowSnapshot],
        pinnedTabs: [PhiScriptingPinnedTabSnapshot] = [],
        bookmarks: [PhiScriptingBookmarkSnapshot] = [],
        activeWindowId: String?
    ) {
        self.spaces = spaces
        self.windows = windows
        self.pinnedTabs = pinnedTabs
        self.bookmarks = bookmarks
        self.activeWindowId = activeWindowId
    }
}

struct PhiScriptingSavedItemsSnapshot: Equatable {
    let pinnedTabs: [PhiScriptingPinnedTabSnapshot]
    let bookmarks: [PhiScriptingBookmarkSnapshot]
}

enum PhiScriptingWindowKind {
    case normal
    case incognito
}

enum PhiScriptingOperationResult: String {
    case completed
    case accepted
    case failed
}

enum PhiScriptingSlotRouting {
    static func preferredSlot<Slot>(
        focusedSlot: Slot?,
        slots: [Slot],
        containsTargetSpace: (Slot) -> Bool
    ) -> Slot? {
        focusedSlot
            ?? slots.first(where: containsTargetSpace)
            ?? slots.first
    }
}

@MainActor
struct PhiScriptingDependencies {
    var snapshot: () -> PhiScriptingSnapshot
    var savedItems: (_ targetSpaceId: String?) -> PhiScriptingSavedItemsSnapshot
    var activateSpace: (String) -> PhiScriptingOperationResult
    var activateTab: (String, String) -> PhiScriptingOperationResult
    var closeTab: (String, String) -> PhiScriptingOperationResult
    var reloadTab: (String, String) -> PhiScriptingOperationResult
    var forceReloadTab: (String, String) -> PhiScriptingOperationResult
    var addSplitView: (String, String) -> PhiScriptingOperationResult
    var openPinnedTab: (String, String) -> PhiScriptingOperationResult
    var openBookmark: (String, String) -> PhiScriptingOperationResult
    var openTab: (String, String?) -> PhiScriptingOperationResult
    var createWindow: (PhiScriptingWindowKind) -> PhiScriptingOperationResult
    var applicationVersion: () -> (version: String, build: String)
    var chromiumDataDirectory: () -> String
}

@MainActor
final class PhiScriptingService {
    static let schemaVersion = 1
    static let apiVersion = 1
    static let spaceIconPointSize: CGFloat = 20
    static let spaceIconScale: CGFloat = 2
    static let shared = PhiScriptingService(dependencies: .live)

    private let dependencies: PhiScriptingDependencies

    init(dependencies: PhiScriptingDependencies) {
        self.dependencies = dependencies
    }

    static func spaceIconData(for storedValue: String) -> String? {
        SpaceIconView.rasterizedImage(
            for: storedValue,
            canvasSize: spaceIconPointSize,
            scale: spaceIconScale
        )?
        .pngData()?
        .base64EncodedString()
    }

    func listSpaces() -> [String: Any] {
        let spaces = dependencies.snapshot().spaces.map(\.jsonObject)
        return success(["spaces": spaces])
    }

    func listTabs(scope: PhiScriptingTabScope) -> [String: Any] {
        let snapshot = dependencies.snapshot()

        let targetSpaceId: String?
        let windows: [PhiScriptingWindowSnapshot]
        switch scope {
        case .all:
            targetSpaceId = nil
            windows = snapshot.windows
        case .current:
            guard let activeWindowId = snapshot.activeWindowId,
                  let activeWindow = snapshot.windows.first(where: { $0.id == activeWindowId }) else {
                return failure(.noActiveWindow)
            }
            targetSpaceId = activeWindow.spaceId
            windows = snapshot.windows.filter { $0.spaceId == activeWindow.spaceId }
        case .space(let spaceId):
            guard snapshot.spaces.contains(where: { $0.id == spaceId }) else {
                return failure(.spaceNotFound)
            }
            targetSpaceId = spaceId
            windows = snapshot.windows.filter { $0.spaceId == spaceId }
        }

        let savedItems = dependencies.savedItems(targetSpaceId)
        return success([
            "tabs": windows.flatMap(\.tabs).map(\.jsonObject),
            "pinnedTabs": savedItems.pinnedTabs.map(\.jsonObject),
            "bookmarks": savedItems.bookmarks.map(\.jsonObject),
            "targetSpaceId": targetSpaceId ?? NSNull(),
        ])
    }

    func getActiveSpace() -> [String: Any] {
        let snapshot = dependencies.snapshot()
        guard let activeWindowId = snapshot.activeWindowId,
              let activeWindow = snapshot.windows.first(where: { $0.id == activeWindowId }),
              let activeSpace = snapshot.spaces.first(where: { $0.id == activeWindow.spaceId }) else {
            return failure(.noActiveWindow)
        }
        return success(["space": activeSpace.jsonObject])
    }

    func activateSpace(spaceId: String?) -> [String: Any] {
        guard let spaceId = nonEmpty(spaceId) else {
            return failure(.invalidArgument)
        }
        let snapshot = dependencies.snapshot()
        guard snapshot.spaces.contains(where: { $0.id == spaceId }) else {
            return failure(.spaceNotFound)
        }
        guard !snapshot.windows.isEmpty else {
            return failure(.noWindows)
        }
        return response(for: dependencies.activateSpace(spaceId))
    }

    func activateTab(windowId: String?, tabId: String?) -> [String: Any] {
        performTabAction(windowId: windowId, tabId: tabId, action: dependencies.activateTab)
    }

    func closeTab(windowId: String?, tabId: String?) -> [String: Any] {
        performTabAction(windowId: windowId, tabId: tabId, action: dependencies.closeTab)
    }

    func reloadTab(windowId: String?, tabId: String?) -> [String: Any] {
        performTabAction(windowId: windowId, tabId: tabId, action: dependencies.reloadTab)
    }

    func forceReloadTab(windowId: String?, tabId: String?) -> [String: Any] {
        performTabAction(windowId: windowId, tabId: tabId, action: dependencies.forceReloadTab)
    }

    func addSplitView(windowId: String?, tabId: String?) -> [String: Any] {
        performTabAction(windowId: windowId, tabId: tabId, action: dependencies.addSplitView)
    }

    func openPinnedTab(spaceId: String?, pinnedTabId: String?) -> [String: Any] {
        guard let spaceId = nonEmpty(spaceId),
              let pinnedTabId = nonEmpty(pinnedTabId) else {
            return failure(.invalidArgument)
        }
        let snapshot = dependencies.snapshot()
        guard snapshot.spaces.contains(where: { $0.id == spaceId }) else {
            return failure(.spaceNotFound)
        }
        guard dependencies.savedItems(spaceId).pinnedTabs.contains(where: {
            $0.id == pinnedTabId && $0.spaceIds.contains(spaceId)
        }) else {
            return failure(.tabNotFound)
        }
        return response(for: dependencies.openPinnedTab(spaceId, pinnedTabId))
    }

    func openBookmark(spaceId: String?, bookmarkId: String?) -> [String: Any] {
        guard let spaceId = nonEmpty(spaceId),
              let bookmarkId = nonEmpty(bookmarkId) else {
            return failure(.invalidArgument)
        }
        let snapshot = dependencies.snapshot()
        guard snapshot.spaces.contains(where: { $0.id == spaceId }) else {
            return failure(.spaceNotFound)
        }
        guard dependencies.savedItems(spaceId).bookmarks.contains(where: {
            $0.id == bookmarkId && $0.spaceId == spaceId
        }) else {
            return failure(.tabNotFound)
        }
        return response(for: dependencies.openBookmark(spaceId, bookmarkId))
    }

    func openTab(address: String?, spaceId: String?) -> [String: Any] {
        guard let address = nonEmpty(address) else {
            return failure(.invalidArgument)
        }
        let requestedSpaceId = nonEmpty(spaceId)
        let snapshot = dependencies.snapshot()
        if let requestedSpaceId,
           !snapshot.spaces.contains(where: { $0.id == requestedSpaceId }) {
            return failure(.spaceNotFound)
        }
        return response(for: dependencies.openTab(address, requestedSpaceId))
    }

    func newWindow() -> [String: Any] {
        createWindow(kind: .normal)
    }

    func newIncognitoWindow() -> [String: Any] {
        createWindow(kind: .incognito)
    }

    func getVersion() -> [String: Any] {
        let version = dependencies.applicationVersion()
        return success([
            "apiVersion": Self.apiVersion,
            "version": version.version,
            "build": version.build,
        ])
    }

    func getChromiumDataDirectory() -> [String: Any] {
        success([
            "chromiumDataDirectory": dependencies.chromiumDataDirectory(),
        ])
    }

    private func performTabAction(
        windowId: String?,
        tabId: String?,
        action: (String, String) -> PhiScriptingOperationResult
    ) -> [String: Any] {
        guard let windowId = nonEmpty(windowId),
              let tabId = nonEmpty(tabId) else {
            return failure(.invalidArgument)
        }
        let snapshot = dependencies.snapshot()
        guard let window = snapshot.windows.first(where: { $0.id == windowId }),
              window.tabs.contains(where: { $0.id == tabId }) else {
            return failure(.tabNotFound)
        }
        return response(for: action(windowId, tabId))
    }

    private func createWindow(kind: PhiScriptingWindowKind) -> [String: Any] {
        response(for: dependencies.createWindow(kind))
    }

    private func response(for result: PhiScriptingOperationResult) -> [String: Any] {
        switch result {
        case .completed, .accepted:
            return success(["outcome": result.rawValue])
        case .failed:
            return failure(.operationFailed)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func success(_ payload: [String: Any] = [:]) -> [String: Any] {
        var response = payload
        response["schemaVersion"] = Self.schemaVersion
        response["ok"] = true
        return response
    }

    private func failure(_ error: PhiScriptingError) -> [String: Any] {
        [
            "schemaVersion": Self.schemaVersion,
            "ok": false,
            "error": [
                "code": error.code,
                "message": error.message,
            ],
        ]
    }
}

extension PhiScriptingDependencies {
    static var live: PhiScriptingDependencies {
        PhiScriptingDependencies(
            snapshot: makeLiveSnapshot,
            savedItems: makeLiveSavedItemsSnapshot,
            activateSpace: activateLiveSpace,
            activateTab: activateLiveTab,
            closeTab: closeLiveTab,
            reloadTab: reloadLiveTab,
            forceReloadTab: forceReloadLiveTab,
            addSplitView: addLiveSplitView,
            openPinnedTab: openLivePinnedTab,
            openBookmark: openLiveBookmark,
            openTab: openLiveTab,
            createWindow: createLiveWindow,
            applicationVersion: {
                let info = Bundle.main.infoDictionary
                return (
                    info?["CFBundleShortVersionString"] as? String ?? "unknown",
                    info?["CFBundleVersion"] as? String ?? "unknown"
                )
            },
            chromiumDataDirectory: FileSystemUtils.applicationSupportDirctory
        )
    }

    private static func makeLiveSnapshot() -> PhiScriptingSnapshot {
        let spaceManager = SpaceManager.shared
        let windowManager = MainBrowserWindowControllersManager.shared
        let userSpaces = spaceManager.userSpaces
        let userSpaceIds = Set(userSpaces.map(\.spaceId))
        let controllers = eligibleControllers(
            from: windowManager.getAllWindows(),
            userSpaceIds: userSpaceIds
        )
        let openSpaceIds = Set(controllers.map(\.spaceId))
        let activeController = windowManager.activeWindowController.flatMap { controller in
            controllers.contains(where: { $0 === controller }) ? controller : nil
        }
        let activeSpaceId = activeController?.spaceId

        let spaces = userSpaces.map { space in
            PhiScriptingSpaceSnapshot(
                id: space.spaceId,
                title: space.name,
                profileId: space.profileId,
                profileName: ProfileManager.shared.profile(for: space.profileId)?.displayName ?? space.profileId,
                colorHex: space.colorHex,
                iconData: PhiScriptingService.spaceIconData(for: space.iconName),
                isActive: space.spaceId == activeSpaceId,
                isOpen: openSpaceIds.contains(space.spaceId)
            )
        }

        let windows = controllers
            .sorted { $0.windowId < $1.windowId }
            .map { controller in
                let state = controller.browserState
                let tabs = state.tabs.map { tab in
                    PhiScriptingTabSnapshot(
                        id: String(tab.guid),
                        windowId: String(controller.windowId),
                        spaceId: controller.spaceId,
                        title: tab.title,
                        url: tab.url,
                        isActive: state.focusingTab?.guid == tab.guid,
                        isPinned: tab.isPinned
                    )
                }
                return PhiScriptingWindowSnapshot(
                    id: String(controller.windowId),
                    spaceId: controller.spaceId,
                    tabs: tabs
                )
            }

        let activeWindowId = activeController.map { String($0.windowId) }
        return PhiScriptingSnapshot(
            spaces: spaces,
            windows: windows,
            activeWindowId: activeWindowId
        )
    }

    private static func makeLiveSavedItemsSnapshot(
        targetSpaceId: String?
    ) -> PhiScriptingSavedItemsSnapshot {
        guard let store = AccountController.shared.localDataAccount?.localStorage
        else {
            return PhiScriptingSavedItemsSnapshot(
                pinnedTabs: [],
                bookmarks: []
            )
        }

        let allSpaces = SpaceManager.shared.userSpaces
        let selectedSpaces: [SpaceModel]
        if let targetSpaceId {
            selectedSpaces = allSpaces.filter { $0.spaceId == targetSpaceId }
        } else {
            selectedSpaces = allSpaces
        }
        return PhiScriptingSavedItemsSnapshot(
            pinnedTabs: makeLivePinnedTabSnapshots(
                store: store,
                selectedSpaces: selectedSpaces,
                allSpaces: allSpaces
            ),
            bookmarks: makeLiveBookmarkSnapshots(
                store: store,
                spaces: selectedSpaces
            )
        )
    }

    private static func makeLivePinnedTabSnapshots(
        store: LocalStore,
        selectedSpaces: [SpaceModel],
        allSpaces: [SpaceModel]
    ) -> [PhiScriptingPinnedTabSnapshot] {
        guard !selectedSpaces.isEmpty else { return [] }

        let scope = store.pinnedTabScope()
        switch scope {
        case .space:
            return selectedSpaces.flatMap { space in
                makePinnedTabSnapshots(
                    from: store.getAllPinnedTabs(
                        for: space.profileId,
                        spaceId: space.spaceId
                    ),
                    scope: scope,
                    ownerSpaceId: space.spaceId,
                    spaceIds: [space.spaceId]
                )
            }
        case .profile:
            var seenProfileIds = Set<String>()
            var snapshots: [PhiScriptingPinnedTabSnapshot] = []
            for space in selectedSpaces
                where seenProfileIds.insert(space.profileId).inserted {
                let profileSpaceIds = allSpaces
                    .filter { $0.profileId == space.profileId }
                    .map(\.spaceId)
                snapshots.append(
                    contentsOf: makePinnedTabSnapshots(
                        from: store.getAllPinnedTabs(
                            for: space.profileId,
                            spaceId: space.spaceId
                        ),
                        scope: scope,
                        ownerSpaceId: nil,
                        spaceIds: profileSpaceIds
                    )
                )
            }
            return snapshots
        case .app:
            guard let representative = selectedSpaces.first else { return [] }
            return makePinnedTabSnapshots(
                from: store.getAllPinnedTabs(
                    for: representative.profileId,
                    spaceId: representative.spaceId
                ),
                scope: scope,
                ownerSpaceId: nil,
                spaceIds: allSpaces.map(\.spaceId)
            )
        }
    }

    private static func makePinnedTabSnapshots(
        from rows: [TabDataModel],
        scope: PinnedTabScope,
        ownerSpaceId: String?,
        spaceIds: [String]
    ) -> [PhiScriptingPinnedTabSnapshot] {
        var consumedIds = Set<String>()
        var snapshots: [PhiScriptingPinnedTabSnapshot] = []

        for row in rows {
            guard consumedIds.insert(row.guid).inserted else { continue }

            let secondary: PhiScriptingSavedPaneSnapshot?
            if let partnerId = row.splitPartnerGuid,
               let partner = rows.first(where: { $0.guid == partnerId }) {
                consumedIds.insert(partner.guid)
                secondary = PhiScriptingSavedPaneSnapshot(
                    id: partner.guid,
                    title: partner.title,
                    url: partner.url.absoluteString
                )
            } else {
                secondary = nil
            }

            snapshots.append(
                PhiScriptingPinnedTabSnapshot(
                    id: row.guid,
                    scope: scope,
                    ownerSpaceId: ownerSpaceId,
                    spaceIds: spaceIds,
                    title: row.title,
                    url: row.url.absoluteString,
                    secondary: secondary
                )
            )
        }
        return snapshots
    }

    private static func makeLiveBookmarkSnapshots(
        store: LocalStore,
        spaces: [SpaceModel]
    ) -> [PhiScriptingBookmarkSnapshot] {
        store.fetchBookmarkTabs(in: spaces).compactMap { bookmark in
            guard let spaceId = bookmark.spaceId else { return nil }
            let secondaryURL = bookmark.secondaryUrl?.absoluteString
            let secondary = secondaryURL.map {
                PhiScriptingSavedPaneSnapshot(
                    id: "\(bookmark.guid):secondary",
                    title: bookmark.secondaryTitle.flatMap { $0.isEmpty ? nil : $0 } ?? $0,
                    url: $0
                )
            }
            return PhiScriptingBookmarkSnapshot(
                id: bookmark.guid,
                spaceId: spaceId,
                title: bookmark.title,
                url: bookmark.url.absoluteString,
                secondary: secondary
            )
        }
    }

    private static func eligibleControllers(
        from controllers: [MainBrowserWindowController],
        userSpaceIds: Set<String>
    ) -> [MainBrowserWindowController] {
        controllers.filter {
            $0.browserType == .normal && userSpaceIds.contains($0.spaceId)
        }
    }

    private static func activateLiveSpace(_ spaceId: String) -> PhiScriptingOperationResult {
        let manager = SpaceManager.shared
        guard manager.keySlot != nil || !manager.slots.isEmpty else {
            return .failed
        }
        manager.activateInFocusedWindow(spaceId: spaceId)
        return .accepted
    }

    private static func activateLiveTab(
        windowId: String,
        tabId: String
    ) -> PhiScriptingOperationResult {
        guard let target = liveTab(windowId: windowId, tabId: tabId),
              let slot = target.controller.slot,
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            return .failed
        }

        let focus: () -> Bool = { [weak controller = target.controller] in
            guard let controller,
                  controller.browserState.tabs.contains(where: { String($0.guid) == tabId }),
                  let numericTabId = Int64(tabId) else {
                return false
            }
            controller.window?.makeKeyAndOrderFront(nil)
            return bridge.activateSearchTab(
                withTabId: numericTabId,
                windowId: Int64(controller.windowId)
            )
        }

        if slot.activeSpaceId == target.controller.spaceId {
            return focus() ? .completed : .failed
        }
        slot.activate(spaceId: target.controller.spaceId) {
            _ = focus()
        }
        return .accepted
    }

    private static func closeLiveTab(
        windowId: String,
        tabId: String
    ) -> PhiScriptingOperationResult {
        guard let target = liveTab(windowId: windowId, tabId: tabId) else {
            return .failed
        }
        target.tab.close()
        return .completed
    }

    private static func reloadLiveTab(
        windowId: String,
        tabId: String
    ) -> PhiScriptingOperationResult {
        guard let target = liveTab(windowId: windowId, tabId: tabId) else {
            return .failed
        }
        target.tab.reload()
        return .completed
    }

    private static func forceReloadLiveTab(
        windowId: String,
        tabId: String
    ) -> PhiScriptingOperationResult {
        guard let target = liveTab(windowId: windowId, tabId: tabId) else {
            return .failed
        }
        target.tab.reloadBypassingCache()
        return .completed
    }

    private static func addLiveSplitView(
        windowId: String,
        tabId: String
    ) -> PhiScriptingOperationResult {
        guard let target = liveTab(windowId: windowId, tabId: tabId),
              target.controller.browserState.splitGroup(forTabId: target.tab.guid) == nil else {
            return .failed
        }
        target.controller.browserState.openNewTabAsSplit(partnerTabId: target.tab.guid)
        return .completed
    }

    private static func openLivePinnedTab(
        spaceId: String,
        pinnedTabId: String
    ) -> PhiScriptingOperationResult {
        performLiveSavedItemAction(spaceId: spaceId) { state in
            guard let tab = state.pinnedTabs.first(where: {
                $0.guidInLocalDB == pinnedTabId
            }) else {
                return false
            }
            state.openOrFocusPinnedTab(tab)
            return true
        }
    }

    private static func openLiveBookmark(
        spaceId: String,
        bookmarkId: String
    ) -> PhiScriptingOperationResult {
        performLiveSavedItemAction(spaceId: spaceId) { state in
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkId) else {
                return false
            }
            state.openBookmark(bookmark)
            return true
        }
    }

    private static func performLiveSavedItemAction(
        spaceId: String,
        action: @escaping (BrowserState) -> Bool
    ) -> PhiScriptingOperationResult {
        let manager = SpaceManager.shared
        guard manager.userSpaces.contains(where: { $0.spaceId == spaceId }) else {
            return .failed
        }

        let routedSlot = PhiScriptingSlotRouting.preferredSlot(
            focusedSlot: manager.keySlot,
            slots: manager.slots,
            containsTargetSpace: { $0.windowController(for: spaceId) != nil }
        )
        // Nil only when the app holds no slot at all, so every path below that
        // ends without a window has to reclaim what this mints — see
        // `SpaceManager.reclaimsMintedSlot` for what a stranded mint costs.
        let slot = routedSlot ?? manager.createSlot(initialSpaceId: spaceId)
        let didMintSlot = routedSlot == nil
        let retryWhenReady = {
            retryLiveSavedItemAction(
                in: slot,
                spaceId: spaceId,
                action: action,
                attemptsRemaining: 10
            )
        }

        if slot.activeSpaceId == spaceId,
           let controller = slot.windowController(for: spaceId) {
            controller.window?.makeKeyAndOrderFront(nil)
            if action(controller.browserState) {
                return .completed
            }
            retryWhenReady()
            return .accepted
        }
        guard slot.windowController(for: spaceId) != nil
                || ChromiumLauncher.sharedInstance().bridge != nil else {
            manager.reclaimMintedSlot(slot, mintedForThisAttempt: didMintSlot)
            return .failed
        }
        slot.activate(
            spaceId: spaceId,
            onActivationFailed: {
                manager.reclaimMintedSlot(slot, mintedForThisAttempt: didMintSlot)
            },
            onSwapSettled: retryWhenReady
        )
        return .accepted
    }

    private static func retryLiveSavedItemAction(
        in slot: SpaceWindowSlot,
        spaceId: String,
        action: @escaping (BrowserState) -> Bool,
        attemptsRemaining: Int
    ) {
        if let controller = slot.windowController(for: spaceId) {
            controller.window?.makeKeyAndOrderFront(nil)
            if action(controller.browserState) {
                return
            }
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            retryLiveSavedItemAction(
                in: slot,
                spaceId: spaceId,
                action: action,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private static func openLiveTab(
        _ address: String,
        spaceId: String?
    ) -> PhiScriptingOperationResult {
        let manager = SpaceManager.shared

        if ChromiumLauncher.sharedInstance().bridge == nil
            || shouldDeferOpenTabUntilLaunchIsReady(manager) {
            retryOpenLiveTabAfterLaunch(
                address,
                spaceId: spaceId,
                attemptsRemaining: 40
            )
            return .accepted
        }

        let preferredSlot = PhiScriptingSlotRouting.preferredSlot(
            focusedSlot: manager.keySlot,
            slots: manager.slots,
            containsTargetSpace: { slot in
                guard let spaceId else { return false }
                return slot.windowController(for: spaceId) != nil
            }
        )
        let targetSpaceId = spaceId
            ?? preferredSlot?.activeSpaceId
            ?? [manager.activeSpaceId, manager.persistedActiveSpaceId]
                .compactMap { $0 }
                .first(where: { candidate in
                    manager.userSpaces.contains(where: { $0.spaceId == candidate })
                })
            ?? manager.userSpaces.first?.spaceId
        guard let targetSpaceId,
              manager.userSpaces.contains(where: { $0.spaceId == targetSpaceId }) else {
            return .failed
        }
        // Same pairing as `performLiveSavedItemAction` above. The bounded retry
        // below cannot stand in for it — that only polls for a window a refused
        // activation will never produce.
        let slot = preferredSlot ?? manager.createSlot(initialSpaceId: targetSpaceId)
        let didMintSlot = preferredSlot == nil
        let processedAddress = URLProcessor.processUserInput(address)

        var didOpen = false
        let openWhenReady: () -> Bool = { [weak slot] in
            if didOpen {
                return true
            }
            guard let slot,
                  slot.activeSpaceId == targetSpaceId,
                  ChromiumLauncher.sharedInstance().bridge != nil,
                  let controller = slot.windowController(for: targetSpaceId) else {
                return false
            }

            didOpen = true
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.browserState.createTab(
                processedAddress,
                focusAfterCreate: true
            )
            return true
        }

        if openWhenReady() {
            return .completed
        }

        let hadRegisteredController = slot.windowController(for: targetSpaceId) != nil
        slot.activate(
            spaceId: targetSpaceId,
            onActivationFailed: {
                manager.reclaimMintedSlot(slot, mintedForThisAttempt: didMintSlot)
            }
        ) {
            _ = openWhenReady()
        }
        if !hadRegisteredController {
            // Window creation normally invokes the completion after synchronous
            // registration. Keep a bounded fallback for Chromium callbacks that
            // register on a later run-loop turn and cannot invoke that completion.
            retryOpenLiveTabWhenWindowIsReady(
                openWhenReady,
                attemptsRemaining: 40
            )
        }
        return .accepted
    }

    private static func shouldDeferOpenTabUntilLaunchIsReady(
        _ manager: SpaceManager
    ) -> Bool {
        manager.userSpaces.isEmpty
            || (
                manager.slots.isEmpty
                    && !manager.hasEverHostedSlotWindow
                    && !manager.hasLoadedURLRules
            )
    }

    private static func retryOpenLiveTabAfterLaunch(
        _ address: String,
        spaceId: String?,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else {
            AppLogWarn("[PhiScripting] open tab timed out waiting for launch readiness")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let manager = SpaceManager.shared
            guard !shouldDeferOpenTabUntilLaunchIsReady(manager),
                  ChromiumLauncher.sharedInstance().bridge != nil else {
                retryOpenLiveTabAfterLaunch(
                    address,
                    spaceId: spaceId,
                    attemptsRemaining: attemptsRemaining - 1
                )
                return
            }

            if openLiveTab(address, spaceId: spaceId) == .failed {
                AppLogWarn("[PhiScripting] deferred open tab could not be routed")
            }
        }
    }

    private static func retryOpenLiveTabWhenWindowIsReady(
        _ openWhenReady: @escaping () -> Bool,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else {
            AppLogWarn("[PhiScripting] open tab timed out waiting for a browser window")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !openWhenReady() else { return }
            retryOpenLiveTabWhenWindowIsReady(
                openWhenReady,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private static func createLiveWindow(
        _ kind: PhiScriptingWindowKind
    ) -> PhiScriptingOperationResult {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            return .failed
        }
        switch kind {
        case .normal:
            let manager = SpaceManager.shared
            let userSpaces = manager.userSpaces
            guard let spaceId = [manager.activeSpaceId, manager.persistedActiveSpaceId]
                .compactMap({ $0 })
                .first(where: { candidate in
                    userSpaces.contains(where: { $0.spaceId == candidate })
                }) ?? userSpaces.first?.spaceId else {
                return .failed
            }
            let slot = manager.createSlot(initialSpaceId: spaceId)
            slot.activate(spaceId: spaceId, onActivationFailed: {
                manager.reclaimMintedSlot(slot, mintedForThisAttempt: true)
            })
            return .accepted
        case .incognito:
            return bridge.createBrowser(
                withWindowType: .incognito,
                profileId: nil,
                hidden: false
            ) != nil ? .completed : .failed
        }
    }

    private static func liveTab(
        windowId: String,
        tabId: String
    ) -> (controller: MainBrowserWindowController, tab: Tab)? {
        guard let numericWindowId = Int(windowId),
              let numericTabId = Int(tabId),
              let controller = MainBrowserWindowControllersManager.shared.controller(for: numericWindowId),
              controller.browserType == .normal,
              SpaceManager.shared.userSpaces.contains(where: { $0.spaceId == controller.spaceId }),
              let tab = controller.browserState.tabs.first(where: { $0.guid == numericTabId }) else {
            return nil
        }
        return (controller, tab)
    }
}

enum PhiScriptingJSON {
    static func string(from object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":{\"code\":\"serialization_failed\",\"message\":\"Phi could not serialize the scripting response.\"},\"ok\":false,\"schemaVersion\":1}"
        }
        return string
    }
}
