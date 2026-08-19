// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

enum PinnedTabTransferError: LocalizedError, Sendable, Equatable {
    case sourceNotFound(String)
    case splitPartnerNotFound(String)
    case emptyCreation
    case invalidURL(Int)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let guid):
            return "Pinned tab \(guid) is no longer in the active source scope."
        case .splitPartnerNotFound(let guid):
            return "Pinned split partner \(guid) is no longer in the active source scope."
        case .emptyCreation:
            return "No tabs were supplied for the pinned-tab transfer."
        case .invalidURL(let tabId):
            return "Tab \(tabId) does not have a valid URL for pinning."
        }
    }
}

struct PinnedTabTransferResult: Sendable, Equatable {
    let guidMapping: [String: String]
    let primaryGuid: String
    let isSplit: Bool
}

struct PinnedTabCreationInput: Sendable, Equatable {
    let tabId: Int
    let title: String
    let url: String
    let partnerTabId: Int?
}

struct PinnedTabCreationResult: Sendable, Equatable {
    let guidByTabId: [Int: String]
    let primaryTabId: Int
    let isSplit: Bool
}

private struct PinnedTabTransferOwner: Equatable {
    let profileId: String?
    let spaceId: String?
}

extension LocalStore {
    /// Moves an existing pinned record to the target window's owner in one
    /// SwiftData transaction. Shared owners only reorder the existing physical
    /// rows; Space-owned records are copied with fresh guids and deleted from
    /// the source only after the complete target unit has been materialized.
    func transferPinnedTab(
        guid: String,
        sourceProfileId: String,
        sourceSpaceId: String,
        targetProfileId: String,
        targetSpaceId: String,
        partnerGuidHint: String? = nil,
        destinationIndex: Int,
        destinationIndexIncludesSourceUnit: Bool = false
    ) async throws -> PinnedTabTransferResult {
        try await performBackgroundWriteAndWaitThrowing { context in
            let scope = try self.pinnedTabScope(in: context)
            let sourceOwner = Self.pinnedTransferOwner(
                scope: scope,
                profileId: sourceProfileId,
                spaceId: sourceSpaceId
            )
            let targetOwner = Self.pinnedTransferOwner(
                scope: scope,
                profileId: targetProfileId,
                spaceId: targetSpaceId
            )
            let sourceTabs = try self.pinnedTabs(
                profileId: sourceProfileId,
                spaceId: sourceSpaceId,
                scope: scope,
                in: context
            )
            guard let source = sourceTabs.first(where: { $0.guid == guid }) else {
                throw PinnedTabTransferError.sourceNotFound(guid)
            }

            let transferUnit = try Self.pinnedTransferUnit(
                containing: source,
                partnerGuidHint: partnerGuidHint,
                in: sourceTabs
            )
            if transferUnit.count == 2 {
                transferUnit[0].splitPartnerGuid = transferUnit[1].guid
                transferUnit[1].splitPartnerGuid = transferUnit[0].guid
            }
            let sourceGuids = Set(transferUnit.map(\.guid))
            let targetTabs = try self.pinnedTabs(
                profileId: targetProfileId,
                spaceId: targetSpaceId,
                scope: scope,
                in: context
            )
            let now = Date()

            if sourceOwner == targetOwner {
                var reordered = targetTabs.filter { !sourceGuids.contains($0.guid) }
                var resolvedDestinationIndex = destinationIndex
                if destinationIndexIncludesSourceUnit {
                    let removedBeforeDestination = targetTabs[..<min(max(destinationIndex, 0), targetTabs.count)]
                        .filter { sourceGuids.contains($0.guid) }
                        .count
                    resolvedDestinationIndex -= removedBeforeDestination
                }
                let insertionIndex = min(max(resolvedDestinationIndex, 0), reordered.count)
                reordered.insert(contentsOf: transferUnit, at: insertionIndex)
                Self.reindexPinnedTabs(reordered, updatedAt: now)
                return PinnedTabTransferResult(
                    guidMapping: Dictionary(uniqueKeysWithValues: transferUnit.map { ($0.guid, $0.guid) }),
                    primaryGuid: guid,
                    isSplit: transferUnit.count == 2
                )
            }

            let guidMapping = Dictionary(uniqueKeysWithValues: transferUnit.map {
                ($0.guid, UUID().uuidString)
            })
            var copiedTabs: [TabDataModel] = []
            copiedTabs.reserveCapacity(transferUnit.count)
            for sourceTab in transferUnit {
                guard let newGuid = guidMapping[sourceTab.guid] else {
                    throw PinnedTabTransferError.sourceNotFound(sourceTab.guid)
                }
                let copied = Self.copyPinnedTab(sourceTab, newGuid: newGuid)
                try self.applyCurrentPinnedTabOwner(
                    profileId: targetProfileId,
                    spaceId: targetSpaceId,
                    to: copied,
                    in: context
                )
                context.insert(copied)
                copiedTabs.append(copied)
            }

            if copiedTabs.count == 2 {
                copiedTabs[0].splitPartnerGuid = copiedTabs[1].guid
                copiedTabs[1].splitPartnerGuid = copiedTabs[0].guid
            }

            var reorderedTarget = targetTabs
            let insertionIndex = min(max(destinationIndex, 0), reorderedTarget.count)
            reorderedTarget.insert(contentsOf: copiedTabs, at: insertionIndex)
            Self.reindexPinnedTabs(reorderedTarget, updatedAt: now)

            let remainingSource = sourceTabs.filter { !sourceGuids.contains($0.guid) }
            Self.reindexPinnedTabs(remainingSource, updatedAt: now)
            for sourceTab in transferUnit {
                context.delete(sourceTab)
            }

            return PinnedTabTransferResult(
                guidMapping: guidMapping,
                primaryGuid: guidMapping[guid] ?? guid,
                isSplit: transferUnit.count == 2
            )
        }
    }

    /// Persists one normal tab, or both panes of a live normal split, directly
    /// in the target window's active owner. The caller updates Chromium custom
    /// values only after this transaction succeeds.
    func createPinnedTabsForCrossWindowDrop(
        _ inputs: [PinnedTabCreationInput],
        targetProfileId: String,
        targetSpaceId: String,
        destinationIndex: Int
    ) async throws -> PinnedTabCreationResult {
        guard let primaryInput = inputs.first else {
            throw PinnedTabTransferError.emptyCreation
        }

        return try await performBackgroundWriteAndWaitThrowing { context in
            let scope = try self.pinnedTabScope(in: context)
            let targetTabs = try self.pinnedTabs(
                profileId: targetProfileId,
                spaceId: targetSpaceId,
                scope: scope,
                in: context
            )
            let parsedURLs = try Dictionary(uniqueKeysWithValues: inputs.map { input in
                guard let url = URL(string: input.url) else {
                    throw PinnedTabTransferError.invalidURL(input.tabId)
                }
                return (input.tabId, url)
            })
            let guidByTabId = Dictionary(uniqueKeysWithValues: inputs.map {
                ($0.tabId, UUID().uuidString)
            })
            let now = Date()
            var createdTabs: [TabDataModel] = []
            createdTabs.reserveCapacity(inputs.count)

            for input in inputs {
                guard let url = parsedURLs[input.tabId],
                      let guid = guidByTabId[input.tabId] else {
                    throw PinnedTabTransferError.invalidURL(input.tabId)
                }
                let model = TabDataModel(
                    title: input.title,
                    guid: guid,
                    index: 0,
                    url: url,
                    favicon: nil,
                    createdDate: now,
                    updatedDate: now
                )
                model.dataType = .pinnedTab
                model.isOpenned = false
                model.isCreatedByChromium = false
                model.pinLineageId = guid
                try self.applyCurrentPinnedTabOwner(
                    profileId: targetProfileId,
                    spaceId: targetSpaceId,
                    to: model,
                    in: context
                )
                context.insert(model)
                createdTabs.append(model)
            }

            for (input, model) in zip(inputs, createdTabs) {
                if let partnerTabId = input.partnerTabId {
                    guard let partnerGuid = guidByTabId[partnerTabId] else {
                        throw PinnedTabTransferError.splitPartnerNotFound(String(partnerTabId))
                    }
                    model.splitPartnerGuid = partnerGuid
                }
            }

            var reordered = targetTabs
            let insertionIndex = min(max(destinationIndex, 0), reordered.count)
            reordered.insert(contentsOf: createdTabs, at: insertionIndex)
            Self.reindexPinnedTabs(reordered, updatedAt: now)

            return PinnedTabCreationResult(
                guidByTabId: guidByTabId,
                primaryTabId: primaryInput.tabId,
                isSplit: inputs.count == 2
            )
        }
    }

    private static func pinnedTransferOwner(
        scope: PinnedTabScope,
        profileId: String,
        spaceId: String
    ) -> PinnedTabTransferOwner {
        switch scope {
        case .space:
            return PinnedTabTransferOwner(profileId: profileId, spaceId: spaceId)
        case .profile:
            return PinnedTabTransferOwner(profileId: profileId, spaceId: nil)
        case .app:
            return PinnedTabTransferOwner(profileId: nil, spaceId: nil)
        }
    }

    private static func pinnedTransferUnit(
        containing source: TabDataModel,
        partnerGuidHint: String?,
        in sourceTabs: [TabDataModel]
    ) throws -> [TabDataModel] {
        if let partnerGuidHint {
            guard partnerGuidHint != source.guid,
                  let hintedPartner = sourceTabs.first(where: { $0.guid == partnerGuidHint }),
                  source.splitPartnerGuid == nil || source.splitPartnerGuid == partnerGuidHint,
                  hintedPartner.splitPartnerGuid == nil || hintedPartner.splitPartnerGuid == source.guid else {
                throw PinnedTabTransferError.splitPartnerNotFound(partnerGuidHint)
            }
            return [source, hintedPartner].sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.guid < $1.guid
            }
        }

        let partner: TabDataModel?
        if let partnerGuid = source.splitPartnerGuid {
            guard let exactPartner = sourceTabs.first(where: { $0.guid == partnerGuid }) else {
                throw PinnedTabTransferError.splitPartnerNotFound(partnerGuid)
            }
            partner = exactPartner
        } else {
            partner = sourceTabs.first(where: { $0.splitPartnerGuid == source.guid })
        }

        guard let partner else { return [source] }
        return [source, partner].sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.guid < $1.guid
        }
    }

    private static func copyPinnedTab(
        _ source: TabDataModel,
        newGuid: String
    ) -> TabDataModel {
        let copied = TabDataModel(
            title: source.title,
            guid: newGuid,
            index: source.index,
            url: source.url,
            favicon: source.favicon,
            createdDate: source.createdDate,
            updatedDate: source.updatedDate
        )
        copied.type = source.type
        copied.overrideTitle = source.overrideTitle
        copied.isOpenned = source.isOpenned
        copied.isCreatedByChromium = source.isCreatedByChromium
        copied.needUpdateMetaData = source.needUpdateMetaData
        copied.source = source.source
        copied.secondaryUrl = source.secondaryUrl
        copied.secondaryTitle = source.secondaryTitle
        copied.lastSeen = source.lastSeen
        copied.icon = source.icon
        copied.pinLineageId = source.pinLineageId ?? source.guid
        return copied
    }

    private static func reindexPinnedTabs(
        _ tabs: [TabDataModel],
        updatedAt: Date
    ) {
        for (index, tab) in tabs.enumerated() {
            tab.index = index
            tab.updatedDate = updatedAt
        }
    }
}
