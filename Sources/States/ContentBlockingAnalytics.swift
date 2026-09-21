// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Content blocking fields of the launch-time `user_defaults_snapshot`.
///
/// The switches live in Chromium's profile prefs, which are not readable when
/// the snapshot is captured (before Chromium starts). `ContentBlockingSettings`
/// therefore mirrors the switches into UserDefaults every time it learns them,
/// and the snapshot reads the mirror. The switches change only through that
/// facade, so the mirror does not drift. The snapshot reports three booleans,
/// true when any profile has the switch on; never a list, URL or site.
enum ContentBlockingAnalytics {
    static let mirrorDefaultsKey = "metrics.contentBlocking.switchesByProfile"

    private static let ads = "ads"
    private static let cookieBanners = "cookie_banners"
    private static let trackers = "trackers"

    /// Records `profileId`'s switches. `knownProfileIds`, when available,
    /// prunes profiles that no longer exist.
    static func mirror(_ state: ContentBlockingState,
                       profileId: String,
                       knownProfileIds: Set<String>? = nil,
                       defaults: UserDefaults = .standard) {
        var mirrored = storedSwitches(in: defaults)
        mirrored[profileId] = [
            ads: state.blockAds,
            cookieBanners: state.blockCookieBanners,
            trackers: state.blockTrackers,
        ]
        if let knownProfileIds, !knownProfileIds.isEmpty {
            mirrored = mirrored.filter { $0.key == profileId || knownProfileIds.contains($0.key) }
        }
        defaults.set(mirrored, forKey: mirrorDefaultsKey)
    }

    static func snapshotProperties(defaults: UserDefaults = .standard) -> [String: Any] {
        let profiles = storedSwitches(in: defaults).values
        func anyOn(_ key: String) -> Bool { profiles.contains { $0[key] == true } }
        return [
            "block_ads_enabled": anyOn(ads),
            "block_cookie_banners_enabled": anyOn(cookieBanners),
            "block_trackers_enabled": anyOn(trackers),
        ]
    }

    private static func storedSwitches(in defaults: UserDefaults) -> [String: [String: Bool]] {
        defaults.dictionary(forKey: mirrorDefaultsKey) as? [String: [String: Bool]] ?? [:]
    }
}
