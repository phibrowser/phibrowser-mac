// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

private struct PinnedTabScopeSyncVariant: Equatable {
    let lineageId: String
    let url: String?
    let title: String?
    let favicon: Data?
    let partnerLineageId: String?
    let partnerURL: String?
    let partnerTitle: String?
    let partnerFavicon: Data?
    let layout: SplitLayout?
}

extension BrowserState {
    /// Matches a complete fetched pinned collection against the runtime
    /// collection that preceded a scope migration. Matching the whole set is
    /// important: a greedy lineage fallback can consume the only runtime tab
    /// that exactly represents a later divergent variant and navigate its live
    /// WebContents to the wrong saved URL.
    func pinnedTabScopeSyncMatches(
        localTabs: [Tab],
        existingTabs: [Tab]
    ) -> [Int: Tab] {
        var matches: [Int: Int] = [:]
        var unmatchedLocal = Set(localTabs.indices)
        var unmatchedExisting = Set(existingTabs.indices)

        func assignMatches(where predicate: (Tab, Tab) -> Bool) {
            for localIndex in localTabs.indices where unmatchedLocal.contains(localIndex) {
                guard let existingIndex = existingTabs.indices.first(where: {
                    unmatchedExisting.contains($0) && predicate(localTabs[localIndex], existingTabs[$0])
                }) else {
                    continue
                }
                matches[localIndex] = existingIndex
                unmatchedLocal.remove(localIndex)
                unmatchedExisting.remove(existingIndex)
            }
        }

        // An unchanged physical row is always the strongest match.
        assignMatches { local, existing in
            guard let localGuid = local.guidInLocalDB else { return false }
            return existing.guidInLocalDB == localGuid
        }

        // Scope migration replaces physical guids. Match the full logical
        // variant next, including the split partner's content, so two split
        // variants whose unchanged pane looks identical cannot cross-bind.
        assignMatches { local, existing in
            guard let localVariant = self.pinnedTabScopeSyncVariant(for: local, in: localTabs),
                  let existingVariant = self.pinnedTabScopeSyncVariant(for: existing, in: existingTabs) else {
                return false
            }
            return localVariant == existingVariant
        }

        // Lineage alone is safe only when exactly one unmatched row exists on
        // each side. Any larger group represents divergent variants and must
        // remain unmatched rather than binding an arbitrary live tab.
        let remainingLineages = Set(unmatchedLocal.compactMap { localTabs[$0].pinnedLineageId })
        for lineageId in remainingLineages {
            let localIndices = unmatchedLocal.filter {
                localTabs[$0].pinnedLineageId == lineageId
            }
            let existingIndices = unmatchedExisting.filter {
                existingTabs[$0].pinnedLineageId == lineageId
            }
            guard localIndices.count == 1,
                  existingIndices.count == 1,
                  let localIndex = localIndices.first,
                  let existingIndex = existingIndices.first else {
                continue
            }
            matches[localIndex] = existingIndex
            unmatchedLocal.remove(localIndex)
            unmatchedExisting.remove(existingIndex)
        }

        return matches.reduce(into: [:]) { result, pair in
            result[pair.key] = existingTabs[pair.value]
        }
    }

    private func pinnedTabScopeSyncVariant(
        for tab: Tab,
        in collection: [Tab]
    ) -> PinnedTabScopeSyncVariant? {
        guard let lineageId = tab.pinnedLineageId else { return nil }
        let partner = tab.splitPartnerGuid.flatMap { partnerGuid in
            collection.first(where: { $0.guidInLocalDB == partnerGuid })
        }
        return PinnedTabScopeSyncVariant(
            lineageId: lineageId,
            url: tab.pinnedUrl ?? tab.url,
            title: tab.storedTitle,
            favicon: tab.cachedFaviconData,
            partnerLineageId: partner?.pinnedLineageId,
            partnerURL: partner.flatMap { $0.pinnedUrl ?? $0.url },
            partnerTitle: partner?.storedTitle,
            partnerFavicon: partner?.cachedFaviconData,
            layout: tab.splitLayout ?? partner?.splitLayout
        )
    }

    /// Retargets both the sidebar record and its live Chromium tab before the
    /// normal open-state sync. This keeps the current WebContents attached
    /// when a scope migration replaces the physical database row.
    func rebindPinnedTabAfterScopeMigrationIfNeeded(
        _ existing: Tab,
        to localTab: Tab
    ) {
        guard let oldGuid = existing.guidInLocalDB,
              let newGuid = localTab.guidInLocalDB,
              oldGuid != newGuid else { return }

        migrateAIChatTab(fromIdentifier: oldGuid, toIdentifier: newGuid)
        existing.guidInLocalDB = newGuid
        existing.pinnedLineageId = localTab.pinnedLineageId
        existing.setFaviconSnapshotUpdater { [weak self] data in
            self?.localStore.updateTabFavicon(newGuid, favicon: data)
        }
        if let liveTab = tabs.first(where: { $0.guidInLocalDB == oldGuid }) {
            liveTab.guidInLocalDB = newGuid
            liveTab.pinnedLineageId = localTab.pinnedLineageId
            liveTab.webContentWrapper?.updateTabCustomValue(newGuid)
        }
    }
}
