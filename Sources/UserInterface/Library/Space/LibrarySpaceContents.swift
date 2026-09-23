// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// A card's store subscription. Persisted models are copied on delivery, never
/// retained by views across account changes or store teardown.
@MainActor
final class LibrarySpaceContents: ObservableObject {
    struct Item: Identifiable {
        let pin: Tab
        let secondaryPin: Tab?
        var id: String { pin.guidInLocalDB! }
        var title: String { pin.title }
        var secondaryID: String? { secondaryPin?.guidInLocalDB }
    }

    // Actions resolve IDs against this exact source collection.
    let scope: BookmarkManagementScope
    let storeIdentifier: UUID
    @Published private(set) var pins: [Item] = []
    let bookmarkManager: BookmarkManager
    private(set) weak var store: LocalStore?
    private var subscriptions = Set<AnyCancellable>()

    init(store: LocalStore, space: Space) {
        self.store = store
        scope = BookmarkManagementScope(accountId: store.account.userID,
                                        profileId: space.profileId, spaceId: space.spaceId)
        storeIdentifier = store.identifier
        bookmarkManager = BookmarkManager(store: store, scope: scope)
        store.pinnedTabsPublisher(for: space.profileId, spaceId: space.spaceId)
            .sink { [weak self] models in
                guard let self else { return }
                pins = Self.pinnedItems(models)
                AppLogInfo("[LibrarySpaces] contents.pins space=\(scope.spaceId) sourceRows=\(models.count) displayedRows=\(pins.count)")
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: LocalStore.willCloseNotification, object: store)
            .sink { [weak self] _ in
                self?.store = nil
                self?.subscriptions.removeAll()
                self?.pins = []
            }
            .store(in: &subscriptions)
    }

    static func pinnedItems(_ models: [TabDataModel]) -> [Item] {
        let sorted = models.sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
        let byID = Dictionary(sorted.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
        var consumed = Set<String>()
        return sorted.compactMap { model in
            guard consumed.insert(model.guid).inserted else { return nil }
            let linked = model.splitPartnerGuid.flatMap { byID[$0] }
                ?? sorted.first { $0.splitPartnerGuid == model.guid }
            let partner = linked.flatMap { consumed.contains($0.guid) ? nil : $0 }
            if let partner { consumed.insert(partner.guid) }
            return Item(pin: Tab(with: model), secondaryPin: partner.map { Tab(with: $0) })
        }
    }

}
