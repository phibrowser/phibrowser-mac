// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// The three Privacy pane toggles.
enum ContentBlockingCategory {
    case ads, cookieBanners, trackers

    var bridgeValue: PhiContentBlockingCategory {
        switch self {
        case .ads: return .ads
        case .cookieBanners: return .cookieBanners
        case .trackers: return .trackers
        }
    }
}

/// One catalog filter list as shown in the Advanced sheet. `title` and
/// `description` are Mac-side strings keyed by the list id.
struct ContentBlockingList: Identifiable, Hashable {
    let id: String
    /// One of "ads", "trackers", "cookies", "regional", "phi", "custom".
    let category: String
    let title: String
    let description: String
    let homepage: URL?
    let license: String
    var checked: Bool
    /// The catalog recommends this list (it is used as soon as downloaded).
    var isRecommended = false
    /// True for lists the user added; `title` is then the user's name.
    var isCustom = false
    /// The download URL of a custom list; nil for pasted rules.
    var sourceURL: URL? = nil
    /// Whether the list's text is on disk. Downloaded lists start out
    /// unavailable until the user downloads them.
    var available = true
    /// A download the user asked for is in progress; `downloadedBytes` of
    /// `totalBytes` so far (`totalBytes` nil when the server gave no size).
    var isDownloading = false
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64? = nil
    /// When the list was last downloaded or confirmed current; nil if never.
    var fetchedAt: Date? = nil
    /// The last download failure, empty when the last fetch succeeded.
    var lastError = ""
}

/// A profile's content blocking state as read through the bridge.
struct ContentBlockingState: Equatable {
    enum Status: String {
        case active, building, degraded, disabled
        /// A toggle is on but none of its lists is downloaded; downloads are
        /// explicit user actions, so this waits for one.
        case noLists = "no_lists"
    }

    var blockAds: Bool
    var blockCookieBanners: Bool
    var blockTrackers: Bool
    var lists: [ContentBlockingList]
    var siteExceptions: [String]
    var status: Status
    var statusDetail: String
    /// Requests blocked for the profile since it was loaded. Session-only.
    var sessionBlockedCount: Int = 0
    /// One line about the published rule set; empty while none is.
    var lastBuildLog: String = ""
}

/// The four bridge calls the facade needs, so tests can substitute a fake
/// without implementing the whole `PhiChromiumBridgeProtocol`.
protocol ContentBlockingBridging {
    func getContentBlockingSettings(_ profileId: String,
                                    completion: @escaping ((any PhiContentBlockingSettings)?, String?) -> Void)
    func setContentBlockingCategory(_ profileId: String,
                                    category: PhiContentBlockingCategory,
                                    enabled: Bool,
                                    completion: @escaping (Bool, String?) -> Void)
    func setContentBlockingList(_ profileId: String,
                                listId: String,
                                enabled: Bool,
                                completion: @escaping (Bool, String?) -> Void)
    func setContentBlockingSiteException(_ profileId: String,
                                         domain: String,
                                         enabled: Bool,
                                         completion: @escaping (Bool, String?) -> Void)
    /// The domain a site exception for the page at `url` is keyed by, as
    /// Chromium computes it. Empty when the URL is not a site or the bridge
    /// cannot say.
    func contentBlockingSiteExceptionDomain(forURL url: String) -> String
    /// Adds a custom list from `url` or `rules` (exactly one non-nil) and
    /// reports the new id, or an error.
    func addContentBlockingCustomList(_ profileId: String,
                                      name: String,
                                      url: String?,
                                      rules: String?,
                                      completion: @escaping (String?, String?) -> Void)
    func removeContentBlockingCustomList(_ profileId: String,
                                         listId: String,
                                         completion: @escaping (Bool, String?) -> Void)
    func refreshContentBlockingLists(_ profileId: String,
                                     completion: @escaping (Bool, String?) -> Void)
    /// Downloads the given lists now, checked or not. Chromium never fetches
    /// a list on its own; this is the user's action.
    func downloadContentBlockingLists(_ profileId: String,
                                      listIds: [String],
                                      completion: @escaping (Bool, String?) -> Void)
    /// Deletes a list's downloaded text; Chromium also unchecks it.
    func deleteContentBlockingListDownload(_ profileId: String,
                                           listId: String,
                                           completion: @escaping (Bool, String?) -> Void)
}

/// Adapts the live Chromium bridge to `ContentBlockingBridging`. Every call
/// is guarded with `responds(to:)` so a Mac client running against a
/// Chromium framework that predates these methods degrades to "unavailable"
/// instead of crashing (header/framework skew).
struct LiveContentBlockingBridge: ContentBlockingBridging {
    let bridge: any PhiChromiumBridgeProtocol

    private func supports(_ selector: Selector) -> Bool {
        (bridge as AnyObject).responds(to: selector)
    }

    func getContentBlockingSettings(_ profileId: String,
                                    completion: @escaping ((any PhiContentBlockingSettings)?, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.getContentBlockingSettings(_:completion:))) else {
            completion(nil, "bridge too old")
            return
        }
        bridge.getContentBlockingSettings(profileId, completion: completion)
    }

    func setContentBlockingCategory(_ profileId: String,
                                    category: PhiContentBlockingCategory,
                                    enabled: Bool,
                                    completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.setContentBlockingCategory(_:category:enabled:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.setContentBlockingCategory(profileId, category: category, enabled: enabled,
                                          completion: completion)
    }

    func setContentBlockingList(_ profileId: String,
                                listId: String,
                                enabled: Bool,
                                completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.setContentBlockingList(_:listId:enabled:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.setContentBlockingList(profileId, listId: listId, enabled: enabled,
                                      completion: completion)
    }

    func setContentBlockingSiteException(_ profileId: String,
                                         domain: String,
                                         enabled: Bool,
                                         completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.setContentBlockingSiteException(_:domain:enabled:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.setContentBlockingSiteException(profileId, domain: domain, enabled: enabled,
                                               completion: completion)
    }

    func contentBlockingSiteExceptionDomain(forURL url: String) -> String {
        guard supports(#selector(PhiChromiumBridgeProtocol.contentBlockingSiteExceptionDomain(forURL:))) else {
            return ""
        }
        return bridge.contentBlockingSiteExceptionDomain(forURL: url)
    }

    func addContentBlockingCustomList(_ profileId: String,
                                      name: String,
                                      url: String?,
                                      rules: String?,
                                      completion: @escaping (String?, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.addContentBlockingCustomList(_:name:url:rules:completion:))) else {
            completion(nil, "bridge too old")
            return
        }
        bridge.addContentBlockingCustomList(profileId, name: name, url: url, rules: rules,
                                            completion: completion)
    }

    func removeContentBlockingCustomList(_ profileId: String,
                                         listId: String,
                                         completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.removeContentBlockingCustomList(_:listId:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.removeContentBlockingCustomList(profileId, listId: listId, completion: completion)
    }

    func refreshContentBlockingLists(_ profileId: String,
                                     completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.refreshContentBlockingLists(_:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.refreshContentBlockingLists(profileId, completion: completion)
    }

    func downloadContentBlockingLists(_ profileId: String,
                                      listIds: [String],
                                      completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.downloadContentBlockingLists(_:listIds:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.downloadContentBlockingLists(profileId, listIds: listIds, completion: completion)
    }

    func deleteContentBlockingListDownload(_ profileId: String,
                                           listId: String,
                                           completion: @escaping (Bool, String?) -> Void) {
        guard supports(#selector(PhiChromiumBridgeProtocol.deleteContentBlockingListDownload(_:listId:completion:))) else {
            completion(false, "bridge too old")
            return
        }
        bridge.deleteContentBlockingListDownload(profileId, listId: listId, completion: completion)
    }
}

extension Notification.Name {
    /// Posted by `PhiChromiumCoordinator` when Chromium reports that a
    /// profile's content blocking generation or status changed. `object` is
    /// the profile id (`String`).
    static let contentBlockingStatusChanged = Notification.Name("phi.contentBlocking.statusChanged")
}

/// The single Mac-side accessor for a profile's content blocking settings.
///
/// The state lives in Chromium prefs and the Profile's rule generation; this
/// facade reads and writes it through the bridge and keeps a published copy
/// for views. Writes update `state` optimistically and revert when the
/// bridge reports failure. Views never touch the bridge directly.
final class ContentBlockingSettings: ObservableObject {
    @Published private(set) var state: ContentBlockingState?

    let profileId: String
    private let bridge: ContentBlockingBridging?
    private var statusObserver: NSObjectProtocol?

    init(profileId: String,
         bridge: ContentBlockingBridging? = ChromiumLauncher.sharedInstance().bridge.map(LiveContentBlockingBridge.init),
         notificationCenter: NotificationCenter = .default) {
        self.profileId = profileId
        self.bridge = bridge
        statusObserver = notificationCenter.addObserver(
            forName: .contentBlockingStatusChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? String) == self.profileId else { return }
            self.refresh()
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    /// Re-reads the state from Chromium. Leaves `state` nil while the bridge
    /// is unavailable or the profile is unknown.
    func refresh() {
        guard let bridge else {
            state = nil
            return
        }
        bridge.getContentBlockingSettings(profileId) { [weak self] settings, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = settings.map(Self.projected)
            }
        }
    }

    func setCategory(_ category: ContentBlockingCategory,
                     enabled: Bool,
                     completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge, var updated = state else {
            completion(false)
            return
        }
        let previous = state
        switch category {
        case .ads: updated.blockAds = enabled
        case .cookieBanners: updated.blockCookieBanners = enabled
        case .trackers: updated.blockTrackers = enabled
        }
        state = updated
        bridge.setContentBlockingCategory(profileId, category: category.bridgeValue,
                                          enabled: enabled) { [weak self] success, _ in
            DispatchQueue.main.async {
                if !success { self?.state = previous }
                completion(success)
            }
        }
    }

    func setList(_ id: String,
                 checked: Bool,
                 completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge, var updated = state,
              let index = updated.lists.firstIndex(where: { $0.id == id }) else {
            completion(false)
            return
        }
        let previous = state
        updated.lists[index].checked = checked
        state = updated
        bridge.setContentBlockingList(profileId, listId: id, enabled: checked) { [weak self] success, _ in
            DispatchQueue.main.async {
                if !success { self?.state = previous }
                completion(success)
            }
        }
    }

    func setSiteException(_ domain: String,
                          enabled: Bool,
                          completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge, var updated = state, !domain.isEmpty else {
            completion(false)
            return
        }
        let previous = state
        updated.siteExceptions.removeAll { $0 == domain }
        if enabled { updated.siteExceptions.append(domain) }
        state = updated
        bridge.setContentBlockingSiteException(profileId, domain: domain,
                                               enabled: enabled) { [weak self] success, _ in
            DispatchQueue.main.async {
                if !success { self?.state = previous }
                completion(success)
            }
        }
    }

    /// Adds a custom list and re-reads the state once Chromium accepted it.
    /// `completion` gets the error message on failure.
    func addCustomList(name: String,
                       url: String?,
                       rules: String?,
                       completion: @escaping (String?) -> Void) {
        guard let bridge else {
            completion("bridge unavailable")
            return
        }
        bridge.addContentBlockingCustomList(profileId, name: name, url: url, rules: rules) { [weak self] _, error in
            DispatchQueue.main.async {
                if error == nil { self?.refresh() }
                completion(error)
            }
        }
    }

    /// Removes a custom list; the row disappears optimistically and comes
    /// back if Chromium refuses.
    func removeCustomList(_ id: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge, var updated = state else {
            completion(false)
            return
        }
        let previous = state
        updated.lists.removeAll { $0.id == id }
        state = updated
        bridge.removeContentBlockingCustomList(profileId, listId: id) { [weak self] success, _ in
            DispatchQueue.main.async {
                if !success { self?.state = previous }
                completion(success)
            }
        }
    }

    /// Downloads the given lists now. Their rows show "Downloading…" until
    /// the state is re-read after Chromium reports the change.
    func downloadLists(_ ids: [String], completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge, var updated = state, !ids.isEmpty else {
            completion(false)
            return
        }
        let previous = state
        for index in updated.lists.indices where ids.contains(updated.lists[index].id) {
            updated.lists[index].isDownloading = true
            updated.lists[index].lastError = ""
        }
        state = updated
        bridge.downloadContentBlockingLists(profileId, listIds: ids) { [weak self] success, _ in
            DispatchQueue.main.async {
                if !success { self?.state = previous }
                completion(success)
            }
        }
    }

    func downloadList(_ id: String, completion: @escaping (Bool) -> Void = { _ in }) {
        downloadLists([id], completion: completion)
    }

    /// Deletes a list's downloaded text; the row shows it unchecked and not
    /// downloaded right away and reverts if Chromium refuses.
    func deleteListDownload(_ id: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge, var updated = state,
              let index = updated.lists.firstIndex(where: { $0.id == id }) else {
            completion(false)
            return
        }
        let previous = state
        updated.lists[index].available = false
        updated.lists[index].isDownloading = false
        updated.lists[index].checked = false
        updated.lists[index].fetchedAt = nil
        updated.lists[index].lastError = ""
        state = updated
        bridge.deleteContentBlockingListDownload(profileId, listId: id) { [weak self] success, _ in
            DispatchQueue.main.async {
                if !success { self?.state = previous }
                completion(success)
            }
        }
    }

    /// Downloads the enabled lists again now.
    func refreshLists(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let bridge else {
            completion(false)
            return
        }
        bridge.refreshContentBlockingLists(profileId) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// The exception key for the page at `url`, or nil when the page is not
    /// a site (chrome://, file:, an empty URL) or the bridge is unavailable.
    func siteExceptionDomain(forURL url: String) -> String? {
        guard let bridge else { return nil }
        let domain = bridge.contentBlockingSiteExceptionDomain(forURL: url)
        return domain.isEmpty ? nil : domain
    }

    // MARK: - Projection

    static func projected(_ settings: any PhiContentBlockingSettings) -> ContentBlockingState {
        ContentBlockingState(
            blockAds: settings.blockAds,
            blockCookieBanners: settings.blockCookieBanners,
            blockTrackers: settings.blockTrackers,
            lists: settings.lists.map { info in
                ContentBlockingList(
                    id: info.listId,
                    category: info.category,
                    title: info.custom ? info.name : ContentBlockingListStrings.title(for: info.listId),
                    description: info.custom ? "" : ContentBlockingListStrings.description(for: info.listId),
                    homepage: info.homepage.isEmpty ? nil : URL(string: info.homepage),
                    license: info.license,
                    checked: info.checked,
                    isRecommended: info.defaultChecked && !info.custom,
                    isCustom: info.custom,
                    sourceURL: info.sourceURL.isEmpty ? nil : URL(string: info.sourceURL),
                    available: info.available,
                    isDownloading: info.downloading,
                    downloadedBytes: info.downloadedBytes,
                    totalBytes: info.totalBytes >= 0 ? info.totalBytes : nil,
                    fetchedAt: info.fetchedAt > 0 ? Date(timeIntervalSince1970: info.fetchedAt) : nil,
                    lastError: info.lastError)
            },
            siteExceptions: settings.siteExceptions,
            status: ContentBlockingState.Status(rawValue: settings.status) ?? .disabled,
            statusDetail: settings.statusDetail,
            sessionBlockedCount: Int(clamping: settings.sessionBlockedCount),
            lastBuildLog: settings.lastBuildLog)
    }
}

/// Mac-side titles and descriptions for the catalog lists, keyed by list id.
/// Unknown ids (a newer Chromium catalog) fall back to the id itself.
enum ContentBlockingListStrings {
    static func title(for id: String) -> String {
        switch id {
        case "easylist":
            return NSLocalizedString("settings.privacy.contentBlocking.list.easylist.title", value: "EasyList", comment: "Privacy settings - Name of the EasyList ad filter list")
        case "easyprivacy":
            return NSLocalizedString("settings.privacy.contentBlocking.list.easyprivacy.title", value: "EasyPrivacy", comment: "Privacy settings - Name of the EasyPrivacy tracker filter list")
        case "easylist-cookie":
            return NSLocalizedString("settings.privacy.contentBlocking.list.easylistCookie.title", value: "EasyList - Cookie Notices", comment: "Privacy settings - Name of the EasyList cookie notice filter list")
        case "adguard-german":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardGerman.title", value: "AdGuard German (Deutsch)", comment: "Privacy settings - Name of the AdGuard German regional filter list")
        case "adguard-french":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardFrench.title", value: "AdGuard French (Français)", comment: "Privacy settings - Name of the AdGuard French regional filter list")
        case "adguard-dutch":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardDutch.title", value: "AdGuard Dutch (Nederlands)", comment: "Privacy settings - Name of the AdGuard Dutch regional filter list")
        case "adguard-spanish":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardSpanish.title", value: "AdGuard Spanish/Portuguese (Español/Português)", comment: "Privacy settings - Name of the AdGuard Spanish and Portuguese regional filter list")
        case "adguard-chinese":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardChinese.title", value: "AdGuard Chinese (中文)", comment: "Privacy settings - Name of the AdGuard Chinese regional filter list")
        case "adguard-japanese":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardJapanese.title", value: "AdGuard Japanese (日本語)", comment: "Privacy settings - Name of the AdGuard Japanese regional filter list")
        case "phi-specific":
            return NSLocalizedString("settings.privacy.contentBlocking.list.phiSpecific.title", value: "Phi Blocklists", comment: "Privacy settings - Name of Phi's own first-party filter list")
        default:
            return id
        }
    }

    static func description(for id: String) -> String {
        switch id {
        case "easylist":
            return NSLocalizedString("settings.privacy.contentBlocking.list.easylist.desc", value: "The most widely used list of ad servers and ad elements.", comment: "Privacy settings - Description of the EasyList ad filter list")
        case "easyprivacy":
            return NSLocalizedString("settings.privacy.contentBlocking.list.easyprivacy.desc", value: "Blocks tracking scripts, beacons and analytics.", comment: "Privacy settings - Description of the EasyPrivacy tracker filter list")
        case "easylist-cookie":
            return NSLocalizedString("settings.privacy.contentBlocking.list.easylistCookie.desc", value: "Hides cookie consent banners and unlocks scrolling behind them.", comment: "Privacy settings - Description of the EasyList cookie notice filter list")
        case "adguard-german":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardGerman.desc", value: "Ads and trackers on German websites.", comment: "Privacy settings - Description of the AdGuard German regional filter list")
        case "adguard-french":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardFrench.desc", value: "Ads and trackers on French websites.", comment: "Privacy settings - Description of the AdGuard French regional filter list")
        case "adguard-dutch":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardDutch.desc", value: "Ads and trackers on Dutch websites.", comment: "Privacy settings - Description of the AdGuard Dutch regional filter list")
        case "adguard-spanish":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardSpanish.desc", value: "Ads and trackers on Spanish and Portuguese websites.", comment: "Privacy settings - Description of the AdGuard Spanish and Portuguese regional filter list")
        case "adguard-chinese":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardChinese.desc", value: "Ads and trackers on Chinese websites.", comment: "Privacy settings - Description of the AdGuard Chinese regional filter list")
        case "adguard-japanese":
            return NSLocalizedString("settings.privacy.contentBlocking.list.adguardJapanese.desc", value: "Ads and trackers on Japanese websites.", comment: "Privacy settings - Description of the AdGuard Japanese regional filter list")
        case "phi-specific":
            return NSLocalizedString("settings.privacy.contentBlocking.list.phiSpecific.desc", value: "Fixes and rules maintained by Phi. Keep this on unless a site misbehaves.", comment: "Privacy settings - Description of Phi's own first-party filter list")
        default:
            return ""
        }
    }
}
