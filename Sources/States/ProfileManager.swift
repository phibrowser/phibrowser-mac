// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation

/// One row from the Chromium-side profile attributes store, projected to
/// Swift. `profileId` is the on-disk basename and the wire identifier used
/// in every bridge call. `isInUse` reflects whether a live Chromium Browser
/// is currently bound to this profile (orthogonal to whether a `SpaceModel`
/// references it — that check lives on `SpaceManager`).
struct PhiBrowserProfile: Hashable, Identifiable {
    let profileId: String
    let displayName: String
    let isLoaded: Bool
    let isInUse: Bool

    var id: String { profileId }
}

/// App-scoped owner of the Chromium profile list. The actual profile data
/// lives in Chromium's `ProfileAttributesStorage`; this class is a thin Swift
/// projection plus a publisher so views can observe changes.
///
/// CRUD goes through the bridge (`createProfileWithDisplayName:completion:`,
/// `deleteProfile:completion:`); after each mutation the manager refreshes
/// its cache so subscribers see the new shape. Lazy profile loading
/// (`ensureProfileLoaded:`) is driven from `SpaceManager.activate` and
/// doesn't change the published list.
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [PhiBrowserProfile] = []

    private init() {
        refresh()
    }

    // MARK: - Read

    /// Pulls the latest profile list from the bridge. Synchronous and
    /// cheap (Chromium-side just reads from in-memory ProfileAttributesStorage).
    /// Safe to call repeatedly on the main thread.
    func refresh() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            // Bridge not up yet at very early launch; `profiles` stays empty
            // and the first post-launch `refresh()` (driven by any UI that
            // needs profiles) will populate it.
            return
        }
        let raw = bridge.listProfiles()
        profiles = raw.compactMap(Self.decode(_:))
    }

    /// Convenience lookup — nil if the basename isn't known. Most callers
    /// only need the displayName for UI labelling.
    func profile(for profileId: String) -> PhiBrowserProfile? {
        profiles.first(where: { $0.profileId == profileId })
    }

    // MARK: - Mutations

    /// Creates a new on-disk profile. Completion fires on the main queue
    /// with the new profileId, or nil on failure. Refreshes the published
    /// list before completion fires.
    func createProfile(displayName: String,
                       completion: @escaping (String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.createProfile(withDisplayName: displayName) { [weak self] newId in
            DispatchQueue.main.async {
                self?.refresh()
                completion(newId)
            }
        }
    }

    /// Schedules a profile for deletion. Completion fires on the main queue
    /// with success/error. The caller (UI) is expected to refuse the action
    /// up front when any Space is bound to this profile — see
    /// `SpaceManager.spaces`; the bridge enforces it as a backstop.
    func deleteProfile(_ profileId: String,
                       completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.deleteProfile(profileId) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.refresh()
                completion(success, error)
            }
        }
    }

    // MARK: - Wire decoding

    private static func decode(_ dict: [String: Any]) -> PhiBrowserProfile? {
        guard let id = dict["profileId"] as? String,
              let name = dict["displayName"] as? String else {
            return nil
        }
        let loaded = (dict["isLoaded"] as? NSNumber)?.boolValue ?? false
        let inUse = (dict["isInUse"] as? NSNumber)?.boolValue ?? false
        return PhiBrowserProfile(
            profileId: id,
            displayName: name,
            isLoaded: loaded,
            isInUse: inUse
        )
    }
}
