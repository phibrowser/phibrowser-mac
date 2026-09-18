// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// View model of the Privacy pane: which profile the pane edits and the
/// facade for it. Content blocking is per profile; the pane starts on the
/// active Space's profile and offers a picker when there is more than one
/// user-assignable profile.
final class PrivacySettingsModel: ObservableObject {
    @Published private(set) var selectedProfileId: String?
    @Published private(set) var settings: ContentBlockingSettings?

    private let makeSettings: (String) -> ContentBlockingSettings
    private var cancellable: AnyCancellable?

    init(makeSettings: @escaping (String) -> ContentBlockingSettings = { ContentBlockingSettings(profileId: $0) }) {
        self.makeSettings = makeSettings
    }

    /// Picks the profile to edit: the active Space's profile when it is a
    /// regular, user-assignable one; else the default profile; else the first.
    static func initialProfileId(profiles: [PhiBrowserProfile],
                                 activeProfileId: String?) -> String? {
        let ids = profiles.map(\.profileId)
        if let activeProfileId, ids.contains(activeProfileId),
           activeProfileId != SpaceManager.incognitoProfileId {
            return activeProfileId
        }
        if ids.contains(LocalStore.defaultProfileId) {
            return LocalStore.defaultProfileId
        }
        return ids.first
    }

    /// Keeps the selection valid against `profiles`, selecting an initial
    /// profile when nothing valid is selected.
    func reconcile(profiles: [PhiBrowserProfile], activeProfileId: String?) {
        let ids = profiles.map(\.profileId)
        if let selected = selectedProfileId, ids.contains(selected) { return }
        select(Self.initialProfileId(profiles: profiles, activeProfileId: activeProfileId))
    }

    func select(_ profileId: String?) {
        guard profileId != selectedProfileId || settings == nil else { return }
        selectedProfileId = profileId
        cancellable = nil
        guard let profileId else {
            settings = nil
            return
        }
        let facade = makeSettings(profileId)
        settings = facade
        // Forward the facade's changes so views observing the model refresh.
        cancellable = facade.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        facade.refresh()
    }
}
