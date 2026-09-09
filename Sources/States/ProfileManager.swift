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

/// One default-search-provider candidate for a profile, projected from
/// Chromium's TemplateURLService. `id` is the engine's stable sync GUID — the
/// wire identity used to set the default.
struct SearchEngineInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let keyword: String
    let isDefault: Bool
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

    /// Profiles a user picker should offer: every profile except the agent's
    /// auto-created fallback, which belongs to the agent (see
    /// `AgentSpaceManager.ensureAgentFallbackProfile`). The one list every
    /// user-facing profile picker draws from.
    var userAssignableProfiles: [PhiBrowserProfile] {
        profiles.filter {
            !PhiPreferences.AgentSpaces.isAgentFallbackProfile(
                profileId: $0.profileId, displayName: $0.displayName)
        }
    }

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
        let decodedProfiles = raw.compactMap(Self.decode(_:))
        profiles = decodedProfiles
        persistDisplayNamesToLocalStore(decodedProfiles)
    }

    /// Convenience lookup — nil if the basename isn't known. Most callers
    /// only need the displayName for UI labelling.
    func profile(for profileId: String) -> PhiBrowserProfile? {
        profiles.first(where: { $0.profileId == profileId })
    }

    /// True when some existing profile already uses `name` (compared
    /// case-insensitively, after trimming). Pass `excluding` while renaming so
    /// a profile isn't flagged as a duplicate of itself. Chromium itself allows
    /// duplicate profile names; this is a Phi-side guard so the create / rename
    /// prompts can keep display names unique — two identically named profiles
    /// are indistinguishable in menus and pickers.
    func displayNameExists(_ name: String, excluding profileId: String? = nil) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return profiles.contains {
            $0.profileId != profileId &&
            $0.displayName.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    // MARK: - Mutations

    /// Creates a new on-disk profile. Completion fires on the main queue with
    /// the new profileId, or nil on failure (including an empty or duplicate
    /// name). Refreshes the published list before completion fires.
    ///
    /// The create prompts grey out their confirm button on a live duplicate
    /// check, but that's UI state — re-check uniqueness here at submit time so a
    /// profile list that went stale (or changed while the prompt was open) can't
    /// slip a duplicate through. `refresh()` first so the check sees the latest.
    ///
    /// Limitation: this is a check-then-act guard, not an authoritative
    /// cross-flight uniqueness constraint — the pending name isn't reserved
    /// during the async bridge create. Several non-modal callers exist today (the
    /// agent fallback profile, the `agentSpace.profiles.create` extension message,
    /// user-data import repair, and the sync layer's per-round account profile
    /// auto-create), so two same-name creates CAN interleave through this window.
    /// The consequence is a DUPLICATE DISPLAY NAME and nothing worse: a Profile's
    /// identity is its account-global uuid, not its name, so no binding is
    /// affected and the suffixing callers do is best-effort disambiguation, not a
    /// uniqueness guarantee. Guaranteeing it would need a pending-name
    /// reservation here or Chromium-side enforcement.
    func createProfile(displayName: String,
                       completion: @escaping (String?) -> Void) {
        refresh()
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // `excluding:` spelled out, not defaulted: the one-argument
        // `LocalProfileCreating` witness below is `@MainActor` (it witnesses a
        // `@MainActor` requirement), so a bare `displayNameExists(trimmed)` binds
        // to that overload instead and this nonisolated method stops compiling.
        guard !trimmed.isEmpty, !displayNameExists(trimmed, excluding: nil) else {
            completion(nil)
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.createProfile(withDisplayName: trimmed) { [weak self] newId in
            DispatchQueue.main.async {
                self?.refresh()
                completion(newId)
            }
        }
    }

    // Note: mirroring the OOBE iCloud Passwords choice onto newly created
    // profiles is handled Chromium-side (PhiICloudPasswordsExternalLoader),
    // which reads `autoInstallICloudPasswords` through the bridge delegate.
    // The Default profile keeps the Mac-driven OOBE install flow.

    /// One-time backfill for users who completed OOBE before the
    /// `autoInstallICloudPasswords` preference existed. If the choice was never
    /// recorded AND there is exactly one (default) profile whose enabled
    /// extensions already include iCloud Passwords, adopt it as the choice so
    /// new profiles inherit it. Driven by the extensions-loaded signal so the
    /// default profile's extensions are known; idempotent + self-healing.
    func backfillICloudPasswordsPrefIfNeeded(installedExtensionIds: [String]) {
        let pref = PhiPreferences.PasswordManagerSettings.autoInstallICloudPasswords
        guard !pref.isSet else { return }
        refresh()
        guard profiles.count == 1 else { return }
        guard installedExtensionIds.contains(PhiExtensionID.icloudPasswords) else { return }
        pref.save(true)
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

    /// Renames a profile's display name. Completion fires on the main queue with
    /// success/error (failing on an empty or duplicate name). Refreshes the
    /// published list before completion fires so subscribers observe the new name.
    ///
    /// Same submit-time guard as `createProfile`: the rename prompt greys out its
    /// confirm button live, but re-check uniqueness here so a stale list can't
    /// commit a duplicate.
    func renameProfile(_ profileId: String,
                       to displayName: String,
                       completion: @escaping (Bool, String?) -> Void) {
        refresh()
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !displayNameExists(trimmed, excluding: profileId) else {
            completion(false, nil)
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.renameProfile(profileId, toDisplayName: trimmed) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.refresh()
                completion(success, error)
            }
        }
    }

    private func persistDisplayNamesToLocalStore(_ profiles: [PhiBrowserProfile]) {
        var displayNamesByProfileId: [String: String] = [:]
        for profile in profiles {
            displayNamesByProfileId[profile.profileId] = profile.displayName
        }
        Task { @MainActor in
            AccountController.shared.account?.localStorage.upsertProfileDisplayNames(displayNamesByProfileId)
        }
    }

    // MARK: - Per-profile settings

    /// Lists a profile's search engines (default-search-provider candidates).
    /// Completion fires on the main queue; empty on failure. May load the
    /// profile first, so the callback can be delayed for an off profile.
    func searchEngines(forProfile profileId: String,
                       completion: @escaping ([SearchEngineInfo]) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion([])
            return
        }
        bridge.listSearchEngines(profileId) { raw in
            DispatchQueue.main.async {
                completion((raw ?? []).compactMap(Self.decodeEngine(_:)))
            }
        }
    }

    /// Sets a profile's default search engine (by sync GUID). Completion fires
    /// on the main queue with success/error.
    func setDefaultSearchEngine(_ engineId: String,
                                forProfile profileId: String,
                                completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.setDefaultSearchEngine(profileId, engineId: engineId) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    /// Reads a profile's default download directory. Completion fires on the
    /// main queue; nil on failure.
    func downloadLocation(forProfile profileId: String,
                          completion: @escaping (String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.getDownloadLocation(profileId) { path in
            DispatchQueue.main.async { completion(path) }
        }
    }

    /// Sets a profile's default download directory. Completion fires on the main
    /// queue with success/error.
    func setDownloadLocation(_ path: String,
                             forProfile profileId: String,
                             completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.setDownloadLocation(profileId, path: path) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    /// Opens one of a profile's data/settings pages ("privacy", "passwords",
    /// "payments", "notifications", "clearBrowserData") in a browser window for
    /// that profile. Completion fires on the main queue with success/error.
    func openDataPage(_ page: String,
                      forProfile profileId: String,
                      completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.openProfileDataPage(profileId, page: page) { success, error in
            DispatchQueue.main.async { completion(success, error) }
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

    private static func decodeEngine(_ dict: [String: Any]) -> SearchEngineInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }
        let keyword = dict["keyword"] as? String ?? ""
        let isDefault = (dict["isDefault"] as? NSNumber)?.boolValue ?? false
        return SearchEngineInfo(id: id, name: name, keyword: keyword, isDefault: isDefault)
    }
}

/// §3.6's injection point into the key layer: `SyncKeyController` creates local
/// Chromium profiles for account profiles that have no counterpart on this Mac,
/// and reaches the bridge only through these three members.
extension ProfileManager: LocalProfileCreating {
    /// Never the whole `profiles` list: the agent fallback profile is in that one
    /// and must never be handed to the account.
    var userAssignableProfileIds: [(profileId: String, displayName: String)] {
        userAssignableProfiles.map { ($0.profileId, $0.displayName) }
    }

    /// The key layer only ever asks the unqualified question; `excluding:` is the
    /// rename prompt's parameter and has no meaning here.
    func displayNameExists(_ name: String) -> Bool {
        displayNameExists(name, excluding: nil)
    }

    /// `createProfile`'s completion, as an `await`. The completion fires on the
    /// main queue after `refresh()`, so the published list is already current.
    func createProfile(displayName: String) async -> String? {
        await withCheckedContinuation { continuation in
            createProfile(displayName: displayName) { continuation.resume(returning: $0) }
        }
    }
}
