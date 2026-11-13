// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum OmniboxNativeDispatchEffect: String, Sendable {
    case focusedExisting = "focused_existing"
    case createdTab = "created_tab"
    case openedSplit = "opened_split"
}

extension BrowserState {

    @MainActor
    func decorateOmniboxSnapshot(_ snapshot: OmniboxNativeSearchSnapshot,
                                 ticket: OmniboxQueryTicket) throws -> OmniboxNativeSearchSnapshot {
        // Split panes support commands, but native bookmark/pin dispatch remains
        // unavailable until the focused tab is standalone.
        if let tab = focusingTab, splitGroup(forTabId: tab.guid) != nil {
            guard ticket.isValid(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) else {
                throw OmniboxNativeQueryError.unavailable
            }
            return .init(mutationEpoch: snapshot.mutationEpoch, pinScope: snapshot.pinScope,
                         bookmarks: .init(status: .unavailable, entities: []),
                         pins: .init(status: .unavailable, entities: []),
                         commands: omniboxCommandCatalog())
        }
        // Only actual bound tabs are candidates for runtime decoration. Closed
        // entities do not repeatedly scan the bookmark cache during this pass.
        let liveIDs = Set(tabs.compactMap { $0.guidInLocalDB })
        var decorated = try snapshot.excluding(entityID: focusingTab?.guidInLocalDB).withRuntimeMetadata(ticket: ticket) { entity in
            if entity.isSplit { return (isOmniboxSplitOpen(entity), nil) }
            guard liveIDs.contains(entity.entityID),
                  case .focus(let tabID) = omniboxRuntimeAction(for: entity),
                  let tab = tabs.first(where: { $0.guid == tabID }) else { return (false, nil) }
            return (true, tab.url)
        }
        decorated.commands = omniboxCommandCatalog()
        let keys = Set((decorated.bookmarks.entities + decorated.pins.entities).map { "\($0.kind.rawValue):\($0.entityID)" })
        decorated.learning = omniboxLearningStore.snapshotEntries(for: keys)
        // Learning is optional: never let it push the snapshot over its limit.
        if (try? decorated.encoded()) == nil { decorated.learning = nil }
        return decorated
    }

    /// Called once a native selection has been accepted.
    @MainActor
    func recordOmniboxSelection(_ entity: OmniboxNativeEntity, learningText: String) {
        omniboxLearningStore.record(text: learningText, kind: entity.kind, entityID: entity.entityID)
    }

    /// An ordinary row was chosen while native rows were shown.
    @MainActor
    func recordOmniboxOrdinaryChoice(learningText: String) {
        omniboxLearningStore.record(text: learningText, kind: nil, entityID: nil)
    }

    @MainActor
    private var omniboxLearningStore: OmniboxLearningStore {
        .store(directory: localStore.account.userDataStorage, profileID: profileId)
    }

    /// Eligibility is checked before touching lazy account/bookmark objects.
    @MainActor
    func currentOmniboxNativeScope() -> OmniboxNativeContextAuthority.Scope? {
        guard !isIncognito, !isKioskWindow, !isAgentSpace,
              !PhiChromiumCoordinator.shared.isBackupImportInProgress,
              ApplicationState.shared.canUseBrowser,
              !ApplicationState.shared.isOmniboxAuthorityTransitioning,
              !SpaceSessionControllersManager.shared.isGuestTransitionInteractionBlocked,
              let controller = windowController, controller.browserState === self,
              !controller.isDormant, controller.isPresentedOrLegacy,
              controller.lifecycleWindow != nil,
              !localStore.isClosedForAccountDirectoryRemoval, localStore.container != nil,
              SpaceManager.shared.acceptsStoreAction(from: localStore.identifier),
              groupOverviewState == nil, pendingSplitPreview == nil,
              visiblePeek(focusingTab: focusingTab) == nil else { return nil }
        if let tab = focusingTab,
           tab.groupToken != nil || tabsAwaitingSplit.contains(tab.guid) ||
            pendingSplitPartnerByCustomGuid.values.contains(where: { $0.partnerTabIds(in: self).contains(tab.guid) }) {
            return nil
        }
        guard let account = AccountController.shared.localDataAccount,
              localStore.account === account else { return nil }
        let access: OmniboxNativeContextAuthority.Scope.Access
        switch ApplicationState.shared.browserAccessState {
        case .guest: access = .guest
        case .signedIn: access = .signedIn
        case .loginRequired: return nil
        }
        return .init(windowID: windowId, accountID: account.userID, storeID: localStore.identifier,
                     profileID: profileId, spaceID: spaceId, access: access,
                     targetID: focusingTab?.guid, stateIdentity: ObjectIdentifier(self))
    }

    /// Called only after the FIFO has revalidated the persisted entity. This
    /// function is synchronous: no dormant queue, deferred Task or nested write.
    @MainActor
    func dispatchOmniboxEntity(_ entity: OmniboxNativeEntity,
                              binding: OmniboxNativeContextAuthority.Binding,
                              ticket: OmniboxQueryTicket,
                              isBindingCurrent: () -> Bool) -> OmniboxNativeDispatchEffect? {
        guard ticket.isValid(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds),
              isBindingCurrent(), currentOmniboxNativeScope() == binding.scope else {
            AppLogDebug("[OmniboxNative] dispatch rejected: binding or scope changed")
            return nil
        }
        if let tab = focusingTab, splitGroup(forTabId: tab.guid) != nil { return nil }
        if entity.isSplit {
            guard openOmniboxSplit(entity) else {
                AppLogDebug("[OmniboxNative] dispatch rejected: split unavailable kind=\(entity.kind.rawValue)")
                return nil
            }
            return .openedSplit
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.createOmniboxEntityTab(url:windowId:customGuid:))),
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.activateOmniboxEntityTab(tabId:windowId:expectedCustomGuid:))) else {
            AppLogDebug("[OmniboxNative] dispatch rejected: bridge unavailable")
            return nil
        }
        guard let action = omniboxRuntimeAction(for: entity) else {
            AppLogDebug("[OmniboxNative] dispatch rejected: no runtime action kind=\(entity.kind.rawValue)")
            return nil
        }
        let submitted: Bool
        let effect: OmniboxNativeDispatchEffect
        switch action {
        case .focus(let tabID):
            submitted = bridge.activateOmniboxEntityTab(tabId: Int64(tabID), windowId: Int64(windowId),
                                                       expectedCustomGuid: entity.entityID)
            effect = .focusedExisting
        case .create(let bound):
            submitted = bridge.createOmniboxEntityTab(url: entity.url, windowId: Int64(windowId),
                                                     customGuid: bound ? entity.entityID : nil)
            effect = .createdTab
        }
        guard submitted else {
            AppLogDebug("[OmniboxNative] dispatch rejected: bridge refused \(action)")
            return nil
        }
        // A successful bridge call can synchronously rebind or close this
        // surface. Only current state receives follow-up native housekeeping.
        if isBindingCurrent(), currentOmniboxNativeScope() == binding.scope {
            localStore.updateLastSeen(entity.entityID)
            clearMultiSelection()
            if case .focus(let tabID) = action, let tab = tabs.first(where: { $0.guid == tabID }) {
                focuseTab(tab)
            }
        }
        return effect
    }

    @MainActor
    private func omniboxRuntimeAction(for entity: OmniboxNativeEntity) -> OmniboxNativeRuntimeBinding.Action? {
        typealias Binding = OmniboxNativeRuntimeBinding
        let isPin = entity.kind == .pin
        let pinCache = pinnedTabs.filter { $0.guidInLocalDB == entity.entityID }
        let bookmarkCache = bookmarkManager.getAllBookmarks().filter { $0.guid == entity.entityID }
        // The Chromium custom value carries a physical ID without a kind. A
        // corrupt cross-kind collision cannot be safely bound by this action.
        guard isPin ? bookmarkCache.isEmpty : pinCache.isEmpty else {
            AppLogDebug("[OmniboxNative] resolve failed: cross-kind id collision \(entity.entityID)")
            return nil
        }
        let pendingBookmarkSplit = pendingPrimarySplitTargetByGuid.values.contains {
            $0.boundBookmarkGuid == entity.entityID
        } || pendingSplitPartnerByCustomGuid.values.contains {
            $0.boundBookmarkGuid == entity.entityID
        }
        let live = tabs.filter { $0.guidInLocalDB == entity.entityID }.map { tab in
            Binding(tabID: tab.guid, wrapper: tab.webContentWrapper.map(ObjectIdentifier.init),
                    isOpen: tab.isOpenned,
                    unsupported: (!isPin && tab.isPinned) || tab.windowId != windowId ||
                        tab.groupToken != nil || splitGroup(forTabId: tab.guid) != nil ||
                        tabsAwaitingSplit.contains(tab.guid) || Self.isPeekTabGuid(tab.guidInLocalDB) ||
                        pendingSplitPartnerByCustomGuid.values.contains(where: { $0.partnerTabIds(in: self).contains(tab.guid) }))
        }
        let cache: [Binding]
        if isPin {
            let incomingSplit = pinnedTabs.contains { $0.splitPartnerGuid == entity.entityID }
            cache = pinCache.map { tab in
                Binding(tabID: tab.guid, wrapper: tab.webContentWrapper.map(ObjectIdentifier.init),
                        isOpen: tab.isOpenned,
                        unsupported: !tab.isPinned || tab.splitPartnerGuid != nil || !tab.splitPaneGuids.isEmpty ||
                            incomingSplit ||
                            pendingPinnedSplitRecreateGuids.contains(entity.entityID) ||
                            pendingSplitAfterPinnedOpen.contains(entity.entityID))
            }
        } else {
            cache = bookmarkCache.map { bookmark in
                Binding(tabID: bookmark.chromiumTabGuid,
                        wrapper: bookmark.webContentWrapper.map(ObjectIdentifier.init),
                        isOpen: bookmark.isOpened,
                        unsupported: bookmark.isFolder || bookmark.secondaryUrl != nil || pendingBookmarkSplit ||
                            splitBookmarkBindings[entity.entityID] != nil)
            }
        }
        let action = Binding.resolve(cache: cache, live: live, isPin: isPin, traditional: layoutMode.isTraditional)
        if action == nil {
            let describe = { (items: [Binding]) in
                items.map { "tab=\($0.tabID) open=\($0.isOpen) unsupported=\($0.unsupported) " +
                    "wrapper=\($0.wrapper.map { String(describing: $0) } ?? "nil")" }
            }
            AppLogDebug("[OmniboxNative] resolve failed kind=\(entity.kind.rawValue) id=\(entity.entityID) " +
                "traditional=\(layoutMode.isTraditional) cache=\(describe(cache)) live=\(describe(live))")
        }
        return action
    }

    @MainActor
    private func isOmniboxSplitOpen(_ entity: OmniboxNativeEntity) -> Bool {
        switch entity.kind {
        case .pin:
            guard let tab = tabs.first(where: { $0.guidInLocalDB == entity.entityID }) else { return false }
            return splitGroup(forTabId: tab.guid) != nil
        case .bookmark:
            guard let splitID = splitBookmarkBindings[entity.entityID] else { return false }
            return splits.contains { $0.id == splitID }
        }
    }

    /// Opens or focuses a split through the sidebar's own paths, focusing the
    /// first pane. A split still being created is refused.
    @MainActor
    private func openOmniboxSplit(_ entity: OmniboxNativeEntity) -> Bool {
        switch entity.kind {
        case .pin:
            guard let pin = pinnedTabs.first(where: { $0.guidInLocalDB == entity.entityID }), pin.isPinned,
                  let members = pinnedSplitDBGuids(forPinnedTab: pin),
                  !members.contains(where: {
                      pendingPinnedSplitRecreateGuids.contains($0) || pendingSplitAfterPinnedOpen.contains($0)
                  }),
                  !tabs.contains(where: { tab in
                      guard let id = tab.guidInLocalDB, members.contains(id) else { return false }
                      return tab.windowId != windowId || tab.groupToken != nil || tabsAwaitingSplit.contains(tab.guid)
                  }) else { return false }
            members.forEach { localStore.updateLastSeen($0) }
            clearMultiSelection()
            openPinnedSplit(dbGuids: members, focusGuid: nil)
            return true
        case .bookmark:
            let pending = pendingPrimarySplitTargetByGuid.values.contains { $0.boundBookmarkGuid == entity.entityID } ||
                pendingSplitPartnerByCustomGuid.values.contains { $0.boundBookmarkGuid == entity.entityID }
            guard !pending,
                  let bookmark = bookmarkManager.getAllBookmarks().first(where: { $0.guid == entity.entityID }),
                  !bookmark.isFolder, bookmark.secondaryUrl?.isEmpty == false else { return false }
            openBookmark(bookmark)
            return true
        }
    }
}
