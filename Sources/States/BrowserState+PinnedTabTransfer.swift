// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum CrossWindowPinnedDropError: LocalizedError {
    case incompatibleWindows
    case tabNotFound(Int)
    case missingWebContents(Int)
    case invalidURL(Int)

    var errorDescription: String? {
        switch self {
        case .incompatibleWindows:
            return "The source and target windows cannot exchange tabs."
        case .tabNotFound(let tabId):
            return "Tab \(tabId) is no longer available in the source window."
        case .missingWebContents(let tabId):
            return "Tab \(tabId) no longer has web contents to move."
        case .invalidURL(let tabId):
            return "Tab \(tabId) does not have a URL that can be pinned."
        }
    }
}

extension BrowserState {
    /// Commits the persisted pinned unit to the target owner before retargeting
    /// any live Chromium tabs. A closed pinned tab completes as a storage-only
    /// move; a live split uses either pane's wrapper to move both panes.
    @MainActor
    func commitCrossWindowPinnedDrop(
        pinnedGuid: String,
        to targetState: BrowserState,
        destinationIndex: Int,
        destinationIndexIncludesSourceUnit: Bool = false
    ) async throws {
        guard targetState.canAcceptCrossWindowDrag(from: self) else {
            throw CrossWindowPinnedDropError.incompatibleWindows
        }

        var liveTabsByPinnedGuid: [String: Tab] = [:]
        for tab in tabs {
            guard let localGuid = tab.guidInLocalDB else { continue }
            liveTabsByPinnedGuid[localGuid] = tab
        }
        var anticipatedTransferGuids = [pinnedGuid]
        var partnerGuidHint: String?
        if let sourcePinned = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
           let pair = pinnedSplitDBPair(forPinnedTab: sourcePinned) {
            anticipatedTransferGuids = [pinnedGuid, pair.0, pair.1]
            partnerGuidHint = pair.0 == pinnedGuid ? pair.1 : pair.0
        }
        var seenAnticipatedGuids = Set<String>()
        let anticipatedLiveTabs = anticipatedTransferGuids.compactMap { guid -> Tab? in
            guard seenAnticipatedGuids.insert(guid).inserted else { return nil }
            return liveTabsByPinnedGuid[guid]
        }
        if !anticipatedLiveTabs.isEmpty,
           anticipatedLiveTabs.allSatisfy({ $0.webContentWrapper == nil }) {
            throw CrossWindowPinnedDropError.missingWebContents(
                anticipatedLiveTabs.first?.guid ?? -1
            )
        }
        let result = try await targetState.localStore.transferPinnedTab(
            guid: pinnedGuid,
            sourceProfileId: profileId,
            sourceSpaceId: spaceId,
            targetProfileId: targetState.profileId,
            targetSpaceId: targetState.spaceId,
            partnerGuidHint: partnerGuidHint,
            destinationIndex: destinationIndex,
            destinationIndexIncludesSourceUnit: destinationIndexIncludesSourceUnit
        )

        for (oldGuid, newGuid) in result.guidMapping where oldGuid != newGuid {
            migrateAIChatTab(fromIdentifier: oldGuid, toIdentifier: newGuid)
            guard let liveTab = liveTabsByPinnedGuid[oldGuid] else { continue }
            liveTab.guidInLocalDB = newGuid
            liveTab.webContentWrapper?.updateTabCustomValue(newGuid)
        }

        let draggedLiveHandle = liveTabsByPinnedGuid[pinnedGuid].flatMap { tab in
            tab.webContentWrapper == nil ? nil : tab
        }
        let moveHandle = draggedLiveHandle
            ?? result.guidMapping.keys.compactMap { guid -> Tab? in
                guard let tab = liveTabsByPinnedGuid[guid],
                      tab.webContentWrapper != nil else { return nil }
                return tab
            }.first
        guard let moveHandle else { return }
        guard let wrapper = moveHandle.webContentWrapper else {
            throw CrossWindowPinnedDropError.missingWebContents(moveHandle.guid)
        }
        wrapper.moveSplit(
            toWindow: targetState.windowId.int64Value,
            at: max(0, targetState.tabs.count)
        )
    }

    /// Pins a normal source tab directly into the target owner. When the tab is
    /// one pane of a live split, both panes are persisted and retargeted as one
    /// unit before Chromium moves the split to the destination window.
    @MainActor
    func commitCrossWindowNormalTabDropToPinned(
        tabId: Int,
        to targetState: BrowserState,
        destinationIndex: Int
    ) async throws {
        guard targetState.canAcceptCrossWindowDrag(from: self) else {
            throw CrossWindowPinnedDropError.incompatibleWindows
        }
        guard let sourceTab = tabs.first(where: { $0.guid == tabId }) else {
            throw CrossWindowPinnedDropError.tabNotFound(tabId)
        }
        guard let moveWrapper = sourceTab.webContentWrapper else {
            throw CrossWindowPinnedDropError.missingWebContents(tabId)
        }

        let splitGroup = splitGroup(forTabId: tabId).flatMap { $0.isPinned ? nil : $0 }
        let transferTabs: [Tab]
        if let splitGroup {
            guard let primary = tabs.first(where: { $0.guid == splitGroup.primaryTabId }),
                  let secondary = tabs.first(where: { $0.guid == splitGroup.secondaryTabId }) else {
                throw CrossWindowPinnedDropError.tabNotFound(tabId)
            }
            transferTabs = [primary, secondary]
        } else {
            transferTabs = [sourceTab]
        }

        let inputs = try transferTabs.map { tab -> PinnedTabCreationInput in
            guard let url = tab.url, !url.isEmpty else {
                throw CrossWindowPinnedDropError.invalidURL(tab.guid)
            }
            let partnerTabId: Int?
            if let splitGroup {
                partnerTabId = splitGroup.partnerTabId(of: tab.guid)
            } else {
                partnerTabId = nil
            }
            return PinnedTabCreationInput(
                tabId: tab.guid,
                title: tab.title,
                url: url,
                partnerTabId: partnerTabId,
                layout: splitGroup?.layout.rawValue
            )
        }
        let result = try await targetState.localStore.createPinnedTabsForCrossWindowDrop(
            inputs,
            targetProfileId: targetState.profileId,
            targetSpaceId: targetState.spaceId,
            destinationIndex: destinationIndex
        )

        applyCrossWindowPinnedIdentifiers(
            result.guidByTabId,
            splitId: splitGroup?.id
        )
        moveWrapper.moveSplit(
            toWindow: targetState.windowId.int64Value,
            at: max(0, targetState.tabs.count)
        )
    }
}
