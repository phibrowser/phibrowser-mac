// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation

/// App-scoped owner of the Space list and per-window-group active-space
/// selection.
///
/// Each Space is backed at runtime by one `MainBrowserWindowController` *per
/// slot*. A slot (`SpaceWindowSlot`) is a user-perceived browser window — its
/// own active Space, its own set of dedicated Chromium NSWindows (one per
/// Space ever surfaced from this slot), its own swap animation. Multiple
/// slots can coexist, each independently showing the same or different
/// Spaces.
///
/// `SpaceManager` itself owns only strictly-global state:
///   1. the persisted list of Spaces (`spaces`)
///   2. the registry of live slots (`slots`, `keySlot`)
///   3. Space mutation API (create/rename/recolor/changeIcon/delete/reorder)
///   4. per-Space theme overrides (applied across every slot)
///   5. account / login binding
///
/// Per-window state (active Space, visible window, swap state) lives on
/// `SpaceWindowSlot`. Callers that have a window context (sidebar pip taps,
/// `windowWillClose`) talk to the slot directly; only truly global concerns
/// (the Spaces list, mutations, themes) go through the singleton.
final class SpaceManager: ObservableObject {
    static let shared = SpaceManager()

    @Published private(set) var spaces: [SpaceModel] = []

    /// Live slots, one per user-perceived browser window. A slot is created
    /// when a new Chromium window can't be matched to an existing slot's
    /// pending spawn intent, and destroyed when its last controller closes.
    private(set) var slots: [SpaceWindowSlot] = []

    /// Set once the "last slot closed" path has asked the app to quit. The
    /// window-driven cascade closes siblings via `NSWindow.close()`, which
    /// fires `windowWillClose` synchronously and re-enters `unregisterWindow`
    /// on the same stack; the recursive leaf can empty the slot map and reach
    /// the terminate branch before the outer frame's own `isEmpty` check runs
    /// it again. `NSApp.terminate(nil)` is not idempotent (it re-enters
    /// `applicationShouldTerminate`), so this flag makes the request fire at
    /// most once regardless of re-entrancy ordering.
    private var didRequestTerminate = false

    /// The slot whose window was most recently key. Used as the default
    /// destination for Chromium-initiated windows (Cmd+N from the menu bar)
    /// and for any caller that historically asked the singleton "what's
    /// active" without a window context.
    weak var keySlot: SpaceWindowSlot?

    /// Spawn intent recorded synchronously by `SpaceWindowSlot.activate`
    /// immediately *before* it calls `bridge.createBrowser`. Chromium's
    /// `BrowserList::OnBrowserAdded` observer fires `mainBrowserWindowCreated`
    /// **synchronously inside** `createBrowser`, so by the time
    /// `claimPendingSpawn` runs the slot hasn't had a chance to record the
    /// windowId-keyed intent yet. This singleton hint covers that race:
    /// the coordinator picks it up when the windowId-keyed lookup misses.
    /// Cleared by the slot after `createBrowser` returns; also consumed by
    /// `claimPendingSpawn` on the first hit. Exactly one spawn can be in
    /// flight at a time (Swift main-thread serial), so a singular slot is
    /// safe — concurrent spawns aren't possible.
    var currentSpawn: SpawnContext?

    struct SpawnContext {
        weak var slot: SpaceWindowSlot?
        let spaceId: String
        let inheritedFrame: NSRect?
        let inheritedSidebarWidth: CGFloat
        let inheritedSidebarCollapsed: Bool?
    }

    private weak var boundAccount: Account?
    private var cancellables = Set<AnyCancellable>()
    private var spacesCancellable: AnyCancellable?
    private var rulesCancellable: AnyCancellable?

    /// Most recent snapshot from `urlRulesPublisher`. Acts as a typed cache so
    /// `pushRoutingTableToChromium` doesn't hit the SwiftData main context on
    /// every slot lifecycle event (and lets `rules(forSpaceId:)` answer from
    /// memory). Updated only on the main thread via the publisher sink.
    private var cachedURLRules: [SpaceURLRule] = []

    /// Loaded once per bind from `AccountUserDefaults.slotsRestoreSnapshot`.
    /// Each entry describes one user-perceived slot at the moment of the
    /// previous session's last `registerWindow`: the spaceId per Chromium
    /// windowId and which Space was visible. `claimRestoredWindow` consults
    /// these to reattach Chromium-restored windows to their original Space
    /// instead of the persisted-active Space (which all restored windows
    /// would otherwise inherit and collapse into one Space's tab list).
    ///
    /// All windowIds in here are PREVIOUS-session ids. They are matched
    /// against the `restoredFromWindowId` Chromium reports for each
    /// session-restored window — never against current-run windowIds, which
    /// are allocated fresh every launch from a counter shared with tab ids
    /// and only coincide with the persisted ones by accident.
    private struct SlotRestoreEntry {
        let activeSpaceId: String?
        /// Previous-session Chromium windowId → spaceId for every window
        /// the slot owned.
        let windowMap: [Int: String]
    }
    private var restoreEntries: [SlotRestoreEntry] = []
    /// Previous-session windowId → index into `restoreEntries`. Entries are
    /// consumed by `claimRestoredWindow` on their first (and only possible)
    /// claim — Chromium replays each saved window at most once.
    private var restoreIndexByWindowId: [Int: Int] = [:]
    /// Index into `restoreEntries` → live slot created (or reused) for that
    /// entry during this launch. Lets multiple windows from the same saved
    /// slot reattach to the same `SpaceWindowSlot`.
    private var restoredSlotsByIndex: [Int: SpaceWindowSlot] = [:]

    /// One queued "reopen these tabs after the profile change lands" intent
    /// per Space, recorded by `changeProfile` before it closes the Space's
    /// windows. `handleSpacesUpdate` fires the respawn once the persisted
    /// write round-trips (the spawn path must read the NEW profileId from
    /// `spaces`); the spawn path then consumes the URLs in place of the
    /// default new-tab page — and only when the spawned profile matches the
    /// intent, so a premature manual re-activation that still spawns on the
    /// old profile leaves the intent queued instead of replaying tabs into
    /// a stale window.
    private struct PendingProfileChangeReopen {
        /// The Space's new profileId — both the respawn and consume key.
        let profileId: String
        let urls: [String]
        /// Slot to re-activate the Space in once the write lands; nil when
        /// the Space wasn't active in any slot (the URLs then replay on the
        /// next manual activation).
        weak var respawnSlot: SpaceWindowSlot?
    }
    private var pendingProfileChangeReopens: [String: PendingProfileChangeReopen] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLoginCompleted),
            name: .loginCompleted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccountChanged),
            name: .mainAccountChanged,
            object: nil
        )
        // Always bind eagerly so the persisted last-active Space is primed
        // before the very first Chromium window arrives. In login flows
        // where the real account isn't set yet, `defaultAccount` provides a
        // stable plist to read from; if/when login completes the
        // `.mainAccountChanged` observer re-binds to the real account.
        let initialAccount = AccountController.shared.account ?? AccountController.defaultAccount
        bind(to: initialAccount)
    }

    // MARK: - Public — read

    /// The persisted "last-active Space" used as the initial Space when a
    /// new slot is created. Reflects the most recent `slot.activate` call
    /// in any slot, or the value carried over from a previous session.
    var persistedActiveSpaceId: String? {
        boundAccount?.userDefaults
            .string(forKey: AccountUserDefaults.DefaultsKey.activeSpaceId.rawValue)
    }

    /// Convenience for code paths that historically asked the singleton
    /// without a window context. Returns the key slot's active Space when
    /// one exists, falling back to the persisted default.
    var activeSpaceId: String? {
        keySlot?.activeSpaceId ?? persistedActiveSpaceId
    }

    /// Currently-active Space of the key slot, derived from `activeSpaceId`.
    var activeSpace: SpaceModel? {
        guard let id = activeSpaceId else { return nil }
        return spaces.first { $0.spaceId == id }
    }

    // MARK: - Public — slot lifecycle

    /// Creates a new slot. Caller is responsible for handing the slot to a
    /// `MainBrowserWindowController` that will register itself. If
    /// `initialSpaceId` is nil, the slot starts on the persisted default
    /// (or the first known Space).
    @discardableResult
    func createSlot(initialSpaceId: String?) -> SpaceWindowSlot {
        let fallback = persistedActiveSpaceId ?? spaces.first?.spaceId
        let resolved = initialSpaceId ?? fallback
        let slot = SpaceWindowSlot(manager: self, initialSpaceId: resolved)
        slots.append(slot)
        if keySlot == nil {
            keySlot = slot
        }
        return slot
    }

    /// Drops a slot from the registry. Called by the slot itself when its
    /// last controller closes (see `SpaceWindowSlot.unregisterWindow`).
    func removeSlot(_ slot: SpaceWindowSlot) {
        slots.removeAll { $0 === slot }
        if keySlot === slot {
            keySlot = slots.last
        }
    }

    /// Asks the app to quit because the last slot just closed, exactly once.
    /// See `didRequestTerminate` for why re-entrant cascades can otherwise
    /// reach `NSApp.terminate(nil)` more than once.
    func requestTerminateForLastSlotClose() {
        guard !didRequestTerminate else { return }
        didRequestTerminate = true
        AppLogInfo("[SpaceManager] last slot removed; calling NSApp.terminate(nil)")
        NSApp.terminate(nil)
    }

    /// Walks every slot looking for one that recorded a pending spawn
    /// intent for `windowId`. Returns the (slot, spaceId) pair on the first
    /// match; the slot consumes the intent as a side effect.
    ///
    /// Used by `PhiChromiumCoordinator.mainBrowserWindowCreated` to attach
    /// an arriving Chromium window to the slot that requested it — even if
    /// the user clicked away to a different Space between request and
    /// async callback.
    func claimPendingSpawn(forWindowId windowId: Int) -> (slot: SpaceWindowSlot, spaceId: String)? {
        for slot in slots {
            if let spaceId = slot.consumePendingSpawnSpaceId(forWindowId: windowId) {
                return (slot, spaceId)
            }
        }
        // Sync-callback fallback: the slot couldn't have recorded the
        // windowId-keyed intent yet because `mainBrowserWindowCreated`
        // fires inside `bridge.createBrowser` (see `currentSpawn` doc).
        if let ctx = currentSpawn, let slot = ctx.slot {
            // Stash the frame/sidebar metadata against this windowId so
            // `slot.registerWindow` (which runs inside the controller init,
            // also inside `createBrowser`) finds it.
            slot.absorbCurrentSpawn(ctx: ctx, windowId: windowId)
            currentSpawn = nil
            return (slot, ctx.spaceId)
        }
        return nil
    }

    /// Looks a session-restored window up against the snapshot saved the
    /// last time this account had any window registered.
    /// `restoredFromWindowId` is the PREVIOUS session's windowId for the
    /// arriving window, reported by Chromium's session restore through the
    /// restore-aware `mainBrowserWindowCreated` variant (see
    /// `phi::ScopedRestoredFromWindowId` on the Chromium side). The
    /// current-run windowId is useless as a key here: it's allocated fresh
    /// every launch from a counter shared with tab ids, so it only matches
    /// the persisted snapshot by accident. Zero means "not a session-restore
    /// re-creation" and never claims — Cmd+N windows and other
    /// Chromium-initiated windows can no longer be misclaimed by stale
    /// snapshot entries.
    ///
    /// On a hit, returns the slot the previous session paired this window
    /// with — reusing the in-memory slot we already minted for a sibling
    /// window from the same saved slot, or creating a fresh one on first
    /// hit — together with the spaceId the window originally belonged to.
    /// The snapshot entry is consumed on claim: Chromium replays each saved
    /// window at most once, so any later lookup with the same id would be a
    /// stale match by definition.
    ///
    /// Used by `PhiChromiumCoordinator.mainBrowserWindowCreated` as the
    /// second-chance fallback after `claimPendingSpawn` misses: covers the
    /// cold-launch session-restore path where Chromium replays each saved
    /// window as a separate `mainBrowserWindowCreated` callback with no
    /// pending spawn intent. Without this hook every restored window
    /// would fall through to `keySlot.activeSpaceId` and collapse all
    /// tabs into that one Space.
    func claimRestoredWindow(forRestoredFromWindowId restoredFromWindowId: Int) -> (slot: SpaceWindowSlot, spaceId: String)? {
        guard restoredFromWindowId != 0,
              let index = restoreIndexByWindowId.removeValue(forKey: restoredFromWindowId),
              index < restoreEntries.count else { return nil }
        let entry = restoreEntries[index]
        guard let spaceId = entry.windowMap[restoredFromWindowId] else { return nil }
        if let existing = restoredSlotsByIndex[index] {
            return (existing, spaceId)
        }
        // First arrival from this saved slot — create the live slot now,
        // initialized to the originally-visible Space so the slot's
        // `registerWindow` later picks the right controller as visible
        // when that Space's window arrives.
        let initial = entry.activeSpaceId ?? spaceId
        let slot = createSlot(initialSpaceId: initial)
        restoredSlotsByIndex[index] = slot
        return (slot, spaceId)
    }

    /// Resolves the Space a normal window whose Chromium profile is
    /// `profileId` may be tagged with. A window must only be presented as a
    /// Space bound to its own profile: pinned tabs (and bookmarks) are
    /// loaded from the controller's profileId, so a mismatched pair
    /// displays another profile's pinned tabs inside the Space.
    ///
    /// Returns `preferred` when that Space is bound to `profileId`.
    /// Otherwise picks the active Space of the first slot (keySlot first)
    /// whose active Space is bound to `profileId` — the user's most
    /// relevant on-screen context for that profile — then the first Space
    /// in strip order bound to `profileId`. Falls back to `preferred`
    /// unchanged when `profileId` is empty or no known Space is bound to
    /// it; there is nothing more consistent to offer.
    ///
    /// Used by `PhiChromiumCoordinator.mainBrowserWindowCreated` on every
    /// resolution path. The spawn path requests the Space's own profile so
    /// this is a pass-through there; it corrects the Chromium-initiated
    /// paths (Cmd+N while the key slot shows another profile's Space,
    /// session-restore claim misses, first-restored-window reuse reporting
    /// restoredFromWindowId == 0).
    func spaceId(boundTo profileId: String, preferring preferred: String) -> String {
        guard !profileId.isEmpty else { return preferred }
        // `spaces` is fed by an async publisher chain (`bind`'s Task →
        // SwiftData publisher → main queue) and the first Chromium windows
        // of a launch reliably arrive before it delivers — checking the
        // cache alone would no-op exactly on the cold-launch path this
        // invariant exists for. Fall back to a direct main-context fetch;
        // every caller is on the main thread (Chromium's window-created
        // callback), the same assumption `applyTheme` makes.
        var known = spaces
        if known.isEmpty, let account = boundAccount {
            known = MainActor.assumeIsolated {
                account.localStorage.getAllSpaces()
            }
        }
        func boundProfileId(of spaceId: String?) -> String? {
            guard let spaceId else { return nil }
            return known.first(where: { $0.spaceId == spaceId })?.profileId
        }
        if boundProfileId(of: preferred) == profileId {
            return preferred
        }
        var orderedSlots: [SpaceWindowSlot] = []
        if let keySlot { orderedSlots.append(keySlot) }
        orderedSlots.append(contentsOf: slots.filter { $0 !== keySlot })
        let slotMatch = orderedSlots
            .compactMap { $0.activeSpaceId }
            .first(where: { boundProfileId(of: $0) == profileId })
        guard let resolved = slotMatch
                ?? known.first(where: { $0.profileId == profileId })?.spaceId else {
            AppLogWarn("[SpaceManager] No Space bound to profile \(profileId); keeping Space \(preferred)")
            return preferred
        }
        AppLogWarn("[SpaceManager] Space \(preferred) is not bound to profile \(profileId); re-resolved to \(resolved)")
        return resolved
    }

    /// Writes the current slot/window/Space layout to
    /// `AccountUserDefaults.slotsRestoreSnapshot`. Called from
    /// `SpaceWindowSlot.registerWindow` so the persisted snapshot always
    /// reflects the most recent live state — sufficient to reattach
    /// Chromium-restored windows next launch, even though unregister does
    /// not rewrite (cascade-close would otherwise drain the snapshot
    /// to empty right before `NSApp.terminate`).
    fileprivate func persistSlotsSnapshot() {
        guard let userDefaults = boundAccount?.userDefaults else { return }
        var dicts: [[String: Any]] = []
        for slot in slots {
            let windowMap = slot.snapshotWindowMap()
            guard !windowMap.isEmpty else { continue }
            var dict: [String: Any] = [:]
            // Plist keys must be strings; convert the windowId map.
            dict["windowMap"] = Dictionary(
                uniqueKeysWithValues: windowMap.map { (String($0.key), $0.value) }
            )
            if let active = slot.activeSpaceId {
                dict["activeSpaceId"] = active
            }
            dicts.append(dict)
        }
        userDefaults.set(dicts, forKey: AccountUserDefaults.DefaultsKey.slotsRestoreSnapshot.rawValue)
    }

    private func loadRestoreSnapshot() {
        restoreEntries.removeAll()
        restoreIndexByWindowId.removeAll()
        restoredSlotsByIndex.removeAll()
        guard let raw = boundAccount?.userDefaults.object(
            forKey: AccountUserDefaults.DefaultsKey.slotsRestoreSnapshot.rawValue
        ) as? [[String: Any]] else { return }
        for dict in raw {
            let rawMap = (dict["windowMap"] as? [String: String]) ?? [:]
            let windowMap: [Int: String] = rawMap.reduce(into: [:]) { partial, pair in
                if let id = Int(pair.key) { partial[id] = pair.value }
            }
            guard !windowMap.isEmpty else { continue }
            let entry = SlotRestoreEntry(
                activeSpaceId: dict["activeSpaceId"] as? String,
                windowMap: windowMap
            )
            let index = restoreEntries.count
            restoreEntries.append(entry)
            for windowId in windowMap.keys {
                restoreIndexByWindowId[windowId] = index
            }
        }
    }

    /// Returns the slot that currently hosts the given Chromium windowId,
    /// or nil if no slot owns it. Linear over slots × spaces — fine at the
    /// scale of "a handful of windows × a handful of spaces".
    func slot(forWindowId windowId: Int) -> SpaceWindowSlot? {
        for slot in slots {
            if slot.contains(windowId: windowId) {
                return slot
            }
        }
        return nil
    }

    /// Called by a slot when one of its windows becomes key so the manager
    /// can route Chromium-initiated windows (Cmd+N) and global queries to
    /// the right slot.
    func notifySlotBecameKey(_ slot: SpaceWindowSlot) {
        guard keySlot !== slot else { return }
        keySlot = slot
        // Tie-break preference for the new key slot's windows changed —
        // re-push so the spaceId→windowId map reflects it.
        pushSpaceStateToChromium()
    }

    // MARK: - Mutations (delegated to LocalStore)

    /// Creates a new Space bound to `profileId` (immutable for the Space's
    /// lifetime). Caller is responsible for choosing the profile — UI passes
    /// the currently-active Space's profile when the user takes the default
    /// one-click "+" path, or the user's explicit choice from the picker.
    ///
    /// The new Space inherits the currently-active Space's pinned theme, which
    /// is what decides the sidebar's overlay background color and opacity, so
    /// it opens looking like the Space it was created from rather than snapping
    /// to the global default theme. A nil pin means "follow the global theme" —
    /// the new Space already does, so we only copy an explicit override.
    @discardableResult
    func createSpace(name: String,
                     colorHex: String,
                     iconName: String,
                     profileId: String) -> String? {
        guard let account = boundAccount else { return nil }
        let newSpaceId = UUID().uuidString
        account.localStorage.createSpace(
            profileId: profileId,
            name: name,
            colorHex: colorHex,
            iconName: iconName,
            spaceId: newSpaceId
        )
        // Optimistic in-memory insert so the new Space's pill renders this
        // runloop turn instead of waiting for the background write to commit
        // and round-trip back through `spacesPublisher` (serial write queue →
        // SQLite fsync → NSManagedObjectContextDidSave → main-thread re-fetch),
        // which is what made "New Space" feel slow. The persisted row stays
        // authoritative: once its emission lands, `handleSpacesUpdate` replaces
        // this array wholesale with the context-attached models. We mirror
        // `LocalStore.createSpace`'s per-profile max+1 sortOrder and reuse
        // `getAllSpaces`'s (sortOrder, profileId, createdDate) ordering so the
        // pill's position is identical before and after that reconciliation —
        // no visible reposition.
        let nextOrder = (spaces.filter { $0.profileId == profileId }
            .map(\.sortOrder).max() ?? -1) + 1
        spaces.append(SpaceModel(spaceId: newSpaceId,
                                 profileId: profileId,
                                 name: name,
                                 colorHex: colorHex,
                                 iconName: iconName,
                                 sortOrder: nextOrder))
        spaces.sort { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.profileId != rhs.profileId { return lhs.profileId < rhs.profileId }
            return lhs.createdDate < rhs.createdDate
        }
        if let currentSpaceId = activeSpaceId,
           let inheritedThemeId = themeId(forSpaceId: currentSpaceId) {
            setTheme(forSpaceId: newSpaceId, themeId: inheritedThemeId)
        }
        // Record the new Space as the persisted default so the first window
        // that opens with no spawn/restore claim lands on it. This is cheap and
        // does NOT spawn the Space's Chromium window. Bringing the new Space to
        // the front of the *currently-focused* window — which does require that
        // spawn — is the caller's job via `activateInFocusedWindow`, so a create
        // made with no window open still seeds the pointer without paying the
        // spawn cost.
        persistActiveSpaceId(newSpaceId)
        return newSpaceId
    }

    /// Brings `spaceId` to the front of the currently-focused window, spawning
    /// that Space's Chromium window when it has none open yet. Paired with
    /// `createSpace` — which only records the new Space as the persisted
    /// default — so a freshly created Space opens in front instead of leaving
    /// the active window sitting on the Space it was created from. Routes
    /// through `keySlot.activate`, which persists the active Space and plays the
    /// correct per-layout switch animation (vertical push-in / horizontal
    /// slide). No-op when no window is open — the persisted default then seeds
    /// the next window to launch.
    func activateInFocusedWindow(spaceId: String) {
        keySlot?.activate(spaceId: spaceId)
    }

    func renameSpace(spaceId: String, to name: String) {
        boundAccount?.localStorage.updateSpace(spaceId: spaceId, name: name)
    }

    func recolorSpace(spaceId: String, colorHex: String) {
        boundAccount?.localStorage.updateSpace(spaceId: spaceId, colorHex: colorHex)
    }

    func changeIcon(spaceId: String, iconName: String) {
        boundAccount?.localStorage.updateSpace(spaceId: spaceId, iconName: iconName)
    }

    func deleteSpace(spaceId: String) {
        guard spaceId != LocalStore.defaultSpaceId else {
            AppLogWarn("[SpaceManager] refusing to delete the default space")
            return
        }
        // A queued profile-change reopen for this Space is moot once the
        // Space itself goes away.
        pendingProfileChangeReopens.removeValue(forKey: spaceId)
        // Any slot currently active on this Space retreats to the default
        // Space with the usual switch animation, then closes the deleted
        // Space's window — but only once the slide settles (`onSwapSettled`).
        // By then the retreat has fronted the default Space and ordered the
        // leaving window out, so the close lands on an already off-screen
        // window and the browser never blinks. Closing it synchronously here
        // would race the in-flight slide and tear down the still-front window
        // mid-animation, which is why the retreat used to be instant.
        let retreatingSlots = slots.filter { $0.activeSpaceId == spaceId }
        for slot in retreatingSlots {
            slot.activate(spaceId: LocalStore.defaultSpaceId) { [weak slot] in
                guard let slot,
                      let controller = slot.windowController(for: spaceId) else { return }
                // If the retreat never completed (e.g. its window spawn failed
                // on a profile-load error) the deleted Space's window is still
                // the slot's visible one. Closing it now would be classified as
                // a window-driven close and cascade the entire slot shut —
                // worst case terminating the app over a Space delete. Leave it
                // open instead; the Space row is still removed below.
                guard slot.visibleController !== controller else {
                    AppLogWarn("[SpaceManager] deleteSpace: not closing \(spaceId)'s window — it is still visible (retreat to default did not complete)")
                    return
                }
                controller.window?.close()
            }
        }
        // Background windows of this Space in slots that weren't showing it are
        // already off-screen — close them immediately. Excludes the retreating
        // slots: their `activeSpaceId` has already flipped to the default Space,
        // so a plain `activeSpaceId != spaceId` filter would wrongly match them
        // and double-close ahead of the deferred handler above. Each close
        // routes through `windowWillClose` → slot.unregisterWindow → cleanup.
        for slot in slots where !retreatingSlots.contains(where: { $0 === slot }) {
            guard let controller = slot.windowController(for: spaceId) else { continue }
            controller.window?.close()
        }
        // Cascade-delete the Space row, its tagged tabs/bookmarks, and its
        // URL rules in a SINGLE write (LocalStore.deleteSpace intentionally
        // leaves the cascade decision to the caller). Doing this as one
        // transaction avoids a crash mid-delete leaving a content-less ghost
        // Space or orphaned rows, and avoids publishing an inconsistent
        // strip/bookmark state between separate saves. Without the rule
        // cleanup they would linger as inert rows that keep being pushed to
        // Chromium and dangle in the rules editor.
        boundAccount?.localStorage.deleteSpaceCascade(spaceId: spaceId)
    }

    /// Re-binds a Space to a different profile. A controller bakes its
    /// profileId at init, so re-binding requires replacing the Space's
    /// windows. The open tabs are captured first; background windows (other
    /// slots) are retired immediately, while the slot the Space is visible
    /// in keeps its window on screen until the persisted write round-trips
    /// through the spaces publisher — `handleSpacesUpdate` then replaces
    /// that window in place via `respawnWindow(forSpaceId:)`, which spawns
    /// on the new profile (the spawn path re-reads the Space's profileId
    /// from `spaces`) and reopens the captured tabs. The user never leaves
    /// the Space. Tagged rows and URL rules stay with the Space.
    func changeProfile(spaceId: String, toProfileId newProfileId: String) {
        guard spaceId != LocalStore.defaultSpaceId else {
            AppLogWarn("[SpaceManager] refusing to change the default space's profile")
            return
        }
        guard let space = spaces.first(where: { $0.spaceId == spaceId }) else {
            AppLogWarn("[SpaceManager] changeProfile: unknown space \(spaceId)")
            return
        }
        guard space.profileId != newProfileId else {
            AppLogInfo("[SpaceManager] changeProfile: \(spaceId) already on \(newProfileId); nothing to do")
            return
        }
        guard ProfileManager.shared.profile(for: newProfileId) != nil else {
            AppLogWarn("[SpaceManager] changeProfile: unknown profile \(newProfileId)")
            return
        }
        AppLogInfo("[SpaceManager] changeProfile: \(spaceId) \(space.profileId) → \(newProfileId)")
        // Capture before closing anything. Pinned tabs are excluded — they
        // are per-profile by design, so the respawned window shows the new
        // profile's pinned set — and so are new-tab pages. keySlot first so
        // the focused window's tabs lead the reopened order.
        var reopenURLs: [String] = []
        var respawnSlot: SpaceWindowSlot?
        var orderedSlots: [SpaceWindowSlot] = []
        if let keySlot { orderedSlots.append(keySlot) }
        orderedSlots.append(contentsOf: slots.filter { $0 !== keySlot })
        for slot in orderedSlots {
            if respawnSlot == nil, slot.activeSpaceId == spaceId {
                respawnSlot = slot
            }
            guard let controller = slot.windowController(for: spaceId) else { continue }
            let urls = controller.browserState.normalTabs
                .compactMap(\.url)
                .filter { !$0.isEmpty && !$0.isNTP }
            reopenURLs.append(contentsOf: urls)
        }
        AppLogInfo("[SpaceManager] changeProfile: captured \(reopenURLs.count) tab(s); respawn slot \(respawnSlot == nil ? "NOT found" : "found")")
        if !reopenURLs.isEmpty || respawnSlot != nil {
            pendingProfileChangeReopens[spaceId] = PendingProfileChangeReopen(
                profileId: newProfileId,
                urls: reopenURLs,
                respawnSlot: respawnSlot
            )
        }
        boundAccount?.localStorage.changeSpaceProfile(
            spaceId: spaceId,
            toProfileId: newProfileId
        )
        // The respawn slot is deliberately untouched here: it keeps showing
        // the old window until the write lands, and `respawnWindow` then
        // swaps it for the new-profile window in place. Retreating it to
        // another Space first (the old approach) armed a deferred swap
        // animation whose completion and key-window churn raced the respawn
        // and could leave the slot on that other Space.
        for slot in slots where slot !== respawnSlot {
            guard let controller = slot.windowController(for: spaceId) else { continue }
            if slot.activeSpaceId == spaceId {
                slot.activate(spaceId: LocalStore.defaultSpaceId)
            }
            // Same guard as `deleteSpace`: if the retreat above failed to
            // spawn, closing the still-visible window would be classified
            // as window-driven and cascade the whole slot shut.
            guard slot.visibleController !== controller else {
                AppLogWarn("[SpaceManager] changeProfile: not closing \(spaceId)'s window — it is still visible (retreat to default did not complete)")
                continue
            }
            // Evict before closing so the asynchronous teardown's late
            // unregister can't run the visible-close side effects.
            slot.evictWindow(for: spaceId)
            controller.window?.close()
        }
    }

    /// Persists a new strip ordering. `spaceIds` is the full set of Spaces
    /// the user just shuffled (across every profile), in the order the strip
    /// should display them. Written as one global renumbering: per-profile
    /// renumbering would tie Spaces from different profiles on `sortOrder`,
    /// and the profileId tiebreak in `getAllSpaces` could then display an
    /// order other than the one the user produced.
    func reorder(spaceIds: [String]) {
        guard let account = boundAccount else { return }
        let known = Set(spaces.map(\.spaceId))
        account.localStorage.reorderSpaces(
            orderedSpaceIds: spaceIds.filter { known.contains($0) }
        )
    }

    // MARK: - Feature toggle

    /// Single entry point for flipping the master Spaces switch. Writes the
    /// preference and, on disable, retreats every slot to the default Space
    /// and closes the windows of all non-default Spaces. The File menu
    /// toggle and the layout-mode auto-disable path both call this so the
    /// side effect cannot drift between callers.
    func setFeatureEnabled(_ enabled: Bool) {
        let key = PhiPreferences.GeneralSettings.spacesFeatureEnabled.rawValue
        let current = UserDefaults.standard.bool(
            forKey: key,
            default: PhiPreferences.GeneralSettings.spacesFeatureEnabled.defaultValue
        )
        guard current != enabled else { return }
        UserDefaults.standard.set(enabled, forKey: key)
        if !enabled {
            collapseToDefaultSpaceOnly()
        }
        // Reflect the toggle in the web-content "Open Link In Space" menu
        // immediately (disable pushes an empty list; enable repopulates it).
        pushOpenLinkSpaceMenuToChromium()
    }

    /// Retreats every slot to the default Space and closes every window
    /// bound to a non-default Space. Called by `setFeatureEnabled(false)` —
    /// keeps the feature-off invariant ("the user only sees one Space, the
    /// default one") even when multiple windows are currently live.
    func collapseToDefaultSpaceOnly() {
        for slot in slots where slot.activeSpaceId != LocalStore.defaultSpaceId {
            slot.activate(spaceId: LocalStore.defaultSpaceId)
        }
        let nonDefaultSpaceIds = spaces
            .map(\.spaceId)
            .filter { $0 != LocalStore.defaultSpaceId }
        for slot in slots {
            for spaceId in nonDefaultSpaceIds {
                guard let controller = slot.windowController(for: spaceId) else { continue }
                // Same guard as `deleteSpace`: if the retreat to the default
                // Space failed to spawn, closing the still-visible window
                // would cascade the whole slot shut.
                guard slot.visibleController !== controller else {
                    AppLogWarn("[SpaceManager] collapse: not closing \(spaceId)'s window — it is still visible (retreat to default did not complete)")
                    continue
                }
                controller.window?.close()
            }
        }
    }

    // MARK: - Per-Space theme

    /// Returns the user-pinned theme id for `spaceId`, or nil when that
    /// Space follows the global theme.
    func themeId(forSpaceId spaceId: String) -> String? {
        boundAccount?.userDefaults.spaceThemeIds()[spaceId]
    }

    /// Sets (or clears) the theme override for `spaceId`. Passing nil makes
    /// the Space follow the global theme again; passing a registered theme
    /// id pins the Space to that theme even when the global theme later
    /// changes. The change is persisted and applied to every live
    /// controller bound to that Space — a Space can now have a live
    /// controller in multiple slots simultaneously, so we iterate.
    func setTheme(forSpaceId spaceId: String, themeId: String?) {
        guard let account = boundAccount else { return }
        var map = account.userDefaults.spaceThemeIds()
        if let themeId {
            map[spaceId] = themeId
        } else {
            map.removeValue(forKey: spaceId)
        }
        account.userDefaults.setSpaceThemeIds(map)
        for slot in slots {
            if let controller = slot.windowController(for: spaceId) {
                applyTheme(themeId: themeId, to: controller)
            }
        }
    }

    // MARK: - Per-Space URL routing

    /// Rules currently configured for `spaceId`, ordered by `sortOrder`.
    /// Reads from the in-memory snapshot kept by `urlRulesPublisher` — safe
    /// to call from any UI path.
    @MainActor
    func rules(forSpaceId spaceId: String) -> [SpaceURLRule] {
        cachedURLRules.filter { $0.spaceId == spaceId }
    }

    /// Snapshot of every Space's rules, in the order delivered by the
    /// publisher (sorted by `spaceId` then `sortOrder`). Used by the
    /// universal URL Rules editor where every rule lives in a single list
    /// rather than one Space at a time.
    @MainActor
    var allRules: [SpaceURLRule] {
        cachedURLRules
    }

    /// Replaces every Space's rule set at once. `byTargetSpaceId` keys are
    /// `spaceId`s; absent spaceIds end up cleared. Pushes the recompiled
    /// routing table optimistically so the change is live before SwiftData's
    /// save notification fires. The publisher re-emission then pushes the
    /// same table a second time — `replaceAllURLRules` regenerates row ids
    /// on every save, so `removeDuplicates` never suppresses it — which is
    /// harmless: Chromium replaces the table atomically.
    func setAllRules(_ byTargetSpaceId: [String: [LocalStore.URLRuleDraft]]) {
        guard let account = boundAccount else { return }
        account.localStorage.replaceAllURLRules(byTargetSpaceId)
        pushOptimisticAllRoutingTable(byTargetSpaceId)
    }

    /// Universal-editor counterpart of `pushOptimisticRoutingTable`. Builds
    /// the routing-table payload entirely from the supplied drafts (i.e. the
    /// caller has already chosen the new complete state) and ships it to
    /// Chromium without round-tripping through SwiftData.
    private func pushOptimisticAllRoutingTable(
        _ byTargetSpaceId: [String: [LocalStore.URLRuleDraft]]
    ) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let mapping = currentSpaceWindowMap()

        var rulesPayload: [[String: Any]] = []
        for (spaceId, drafts) in byTargetSpaceId {
            for (index, draft) in drafts.enumerated() {
                let host = draft.host.lowercased()
                guard !host.isEmpty else { continue }
                var entry: [String: Any] = [
                    "targetSpaceId": spaceId,
                    "host": host,
                    "ask": NSNumber(value: draft.askBeforeRouting),
                    "sortOrder": NSNumber(value: index),
                ]
                if let prefix = draft.pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prefix.isEmpty {
                    entry["pathPrefix"] = prefix
                }
                rulesPayload.append(entry)
            }
        }
        Self.canonicalizeRulesPayloadOrder(&rulesPayload)
        let windowMapPayload = mapping.mapValues { NSNumber(value: $0) }
        bridge.setSpaceRoutingTable(rulesPayload, spaceWindowMap: windowMapPayload)
    }

    /// Orders a routing-table payload by (targetSpaceId, sortOrder) — the
    /// same order the persisted-path push sees from the publisher. Payload
    /// order is load-bearing: `sortOrder` values are per-Space indices, so
    /// rules from different Spaces can tie on full specificity, and the C++
    /// matcher keeps the FIRST best rule it encounters. Without one
    /// canonical order, an optimistic push could resolve such a tie
    /// differently than the steady-state push that follows the SwiftData
    /// save.
    private static func canonicalizeRulesPayloadOrder(_ payload: inout [[String: Any]]) {
        payload.sort { lhs, rhs in
            let lhsSpace = (lhs["targetSpaceId"] as? String) ?? ""
            let rhsSpace = (rhs["targetSpaceId"] as? String) ?? ""
            if lhsSpace != rhsSpace { return lhsSpace < rhsSpace }
            let lhsOrder = ((lhs["sortOrder"] as? NSNumber)?.intValue) ?? 0
            let rhsOrder = ((rhs["sortOrder"] as? NSNumber)?.intValue) ?? 0
            return lhsOrder < rhsOrder
        }
    }

    /// Replaces the rule list for `spaceId` with `drafts` (full set, in the
    /// order the user authored). Existing rows for the Space are deleted
    /// and re-created with `sortOrder = index`. Pushes optimistically so the
    /// new table is live in Chromium before the SwiftData write + notification
    /// round-trip completes; the publisher re-emission then pushes the same
    /// table a second time (fresh row ids defeat `removeDuplicates`), which
    /// is harmless — Chromium replaces the table atomically.
    func setRules(_ drafts: [LocalStore.URLRuleDraft], forSpaceId spaceId: String) {
        guard let account = boundAccount else { return }
        account.localStorage.replaceURLRules(forSpaceId: spaceId, with: drafts)
        pushOptimisticRoutingTable(drafts: drafts, forSpaceId: spaceId)
    }

    /// Builds the routing-table payload using `drafts` for `spaceId` and the
    /// in-memory `cachedURLRules` for every other Space, then pushes it to
    /// Chromium without waiting for SwiftData's save notification to fire.
    private func pushOptimisticRoutingTable(
        drafts: [LocalStore.URLRuleDraft],
        forSpaceId spaceId: String
    ) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let mapping = currentSpaceWindowMap()

        var rulesPayload: [[String: Any]] = cachedURLRules.compactMap { rule in
            guard rule.spaceId != spaceId else { return nil }
            var entry: [String: Any] = [
                "targetSpaceId": rule.spaceId,
                "host": rule.host,
                "ask": NSNumber(value: rule.askBeforeRouting),
                "sortOrder": NSNumber(value: rule.sortOrder),
            ]
            if let prefix = rule.pathPrefix, !prefix.isEmpty {
                entry["pathPrefix"] = prefix
            }
            return entry
        }
        for (index, draft) in drafts.enumerated() {
            let host = draft.host.lowercased()
            guard !host.isEmpty else { continue }
            var entry: [String: Any] = [
                "targetSpaceId": spaceId,
                "host": host,
                "ask": NSNumber(value: draft.askBeforeRouting),
                "sortOrder": NSNumber(value: index),
            ]
            if let prefix = draft.pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prefix.isEmpty {
                entry["pathPrefix"] = prefix
            }
            rulesPayload.append(entry)
        }
        Self.canonicalizeRulesPayloadOrder(&rulesPayload)
        let windowMapPayload = mapping.mapValues { NSNumber(value: $0) }
        bridge.setSpaceRoutingTable(rulesPayload, spaceWindowMap: windowMapPayload)
    }

    /// Flattens the rules and the live spaceId→windowId
    /// map and hands both to the Chromium bridge via the new
    /// `setSpaceRoutingTable:spaceWindowMap:` method. Idempotent — Chromium
    /// replaces its table atomically — so it's safe to call on every change
    /// without diffing. Invoked from:
    ///   - `handleURLRulesUpdate` when the persisted rules change.
    ///   - `SpaceWindowSlot.registerWindow`/`unregisterWindow` when a Space's
    ///     window comes or goes (mapping changed).
    ///   - `notifySlotBecameKey` when the keySlot moves (tie-break preference
    ///     for the new key slot's windows).
    ///   - `unbind` to clear Chromium's table when the user signs out.
    func pushRoutingTableToChromium() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let mapping = currentSpaceWindowMap()

        var rulesPayload: [[String: Any]] = cachedURLRules.map { rule in
            var entry: [String: Any] = [
                "targetSpaceId": rule.spaceId,
                "host": rule.host,
                "ask": NSNumber(value: rule.askBeforeRouting),
                "sortOrder": NSNumber(value: rule.sortOrder),
            ]
            if let prefix = rule.pathPrefix, !prefix.isEmpty {
                entry["pathPrefix"] = prefix
            }
            return entry
        }
        // Already publisher-ordered; canonicalize anyway so all three push
        // paths share one explicit ordering invariant.
        Self.canonicalizeRulesPayloadOrder(&rulesPayload)
        let windowMapPayload = mapping.mapValues { NSNumber(value: $0) }
        bridge.setSpaceRoutingTable(rulesPayload, spaceWindowMap: windowMapPayload)
    }

    /// Pushes the Space list shown in the web-content right-click "Open Link In
    /// Space" submenu down to Chromium (replaces it atomically). Each entry
    /// carries the Space's id, name, and the id of its currently-open window
    /// (0 if none) so Chromium can exclude the Space the user right-clicked in.
    /// Shares `pushRoutingTableToChromium`'s trigger set via
    /// `pushSpaceStateToChromium`, plus `handleSpacesUpdate` for name/order
    /// changes that don't affect routing.
    func pushOpenLinkSpaceMenuToChromium() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        // When the master Spaces feature is off, push an empty list so the
        // web-content "Open Link In Space" menu is hidden entirely.
        guard PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else {
            bridge.setOpenLinkSpaceMenu([])
            return
        }
        let mapping = currentSpaceWindowMap()
        let payload: [[String: Any]] = spaces.map { space in
            [
                "spaceId": space.spaceId,
                "name": space.name,
                "windowId": NSNumber(value: mapping[space.spaceId] ?? 0),
            ]
        }
        bridge.setOpenLinkSpaceMenu(payload)
    }

    /// Pushes both the Space URL routing table and the "Open Link In Space"
    /// submenu list. Call whenever the Space set or the open-window mapping
    /// changes.
    func pushSpaceStateToChromium() {
        pushRoutingTableToChromium()
        pushOpenLinkSpaceMenuToChromium()
    }

    /// Opens `urlString` after an "ask first" rule match, once the user has
    /// chosen a destination in the prompt presented by `PhiChromiumCoordinator`.
    /// `spaceId == nil` means "keep it here": the URL opens as a new
    /// foreground tab in the source window. Otherwise the chosen Space is
    /// brought to the front in the source window's slot (spawning its window
    /// when the Space isn't currently open) and the URL opens there.
    ///
    /// The matching navigation was already cancelled on the Chromium side, so
    /// this always opens *something* — if the chosen Space's window can't be
    /// resolved (rare cold-spawn race), it falls back to the source window so
    /// the URL is never silently dropped.
    @MainActor
    func routeAskedURL(_ urlString: String, toSpaceId spaceId: String?, sourceWindowId: Int64) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        // Bypass space routing for the re-open: the URL matched an ask-rule,
        // so a plain new tab would be caught by the same rule and prompt
        // again in a loop. The bridge exempts this one (url, window) pair.
        let open: (Int64) -> Void = { windowId in
            bridge.openTabBypassingSpaceRouting(withUrl: urlString, windowId: windowId)
        }
        guard let spaceId else {
            open(sourceWindowId)
            return
        }
        let sourceSlot = slots.first { $0.contains(windowId: Int(sourceWindowId)) }
        let slot = sourceSlot ?? keySlot ?? slots.first
        slot?.activate(spaceId: spaceId)
        if let controller = slot?.windowController(for: spaceId) {
            open(Int64(controller.windowId))
            return
        }
        // Cold path: the Space's window spawns asynchronously. Retry on the
        // next runloop tick, then fall back to the source window.
        DispatchQueue.main.async { [weak slot] in
            if let controller = slot?.windowController(for: spaceId) {
                open(Int64(controller.windowId))
            } else {
                open(sourceWindowId)
            }
        }
    }

    /// Picks one windowId per Space that currently has an open window. A
    /// Space can be active in multiple slots simultaneously; the keySlot
    /// wins the tiebreak so cross-Space routing lands in the window the
    /// user just had focused. Spaces without an open window are omitted —
    /// rules targeting them are no-ops on the Chromium side.
    private func currentSpaceWindowMap() -> [String: Int] {
        var result: [String: Int] = [:]
        var ordered: [SpaceWindowSlot] = []
        if let key = keySlot { ordered.append(key) }
        ordered.append(contentsOf: slots.filter { $0 !== keySlot })
        for slot in ordered {
            for (spaceId, controller) in slot.windowsBySpaceId where result[spaceId] == nil {
                result[spaceId] = controller.windowId
            }
        }
        return result
    }

    /// Applied by `SpaceWindowSlot.registerWindow` so a freshly-spawned
    /// controller adopts any persisted per-Space override before first paint.
    func applyPersistedTheme(to controller: MainBrowserWindowController, spaceId: String) {
        let persisted = boundAccount?.userDefaults.spaceThemeIds()[spaceId]
        // Only touch the context when there's actually an override to apply —
        // leaving the default `mirrorsSharedTheme = true` alone for Spaces
        // that follow the global theme.
        guard persisted != nil else { return }
        applyTheme(themeId: persisted, to: controller)
    }

    /// Applies `themeId` to `controller`'s theme context. Nil means "follow
    /// the global theme". Touches `ThemeManager.shared`, which is
    /// `@MainActor`-isolated; every caller is on main already (UI menu
    /// actions, slot.registerWindow from `NSWindowController` init), so we
    /// assume main isolation rather than propagating the annotation through
    /// the whole call chain.
    fileprivate func applyTheme(themeId: String?, to controller: MainBrowserWindowController) {
        MainActor.assumeIsolated {
            let manager = ThemeManager.shared
            let context = controller.browserState.themeContext
            if let themeId, let theme = manager.registeredThemes[themeId] {
                context.mirrorsSharedTheme = false
                context.setTheme(theme)
            } else {
                // "Follow Global" — restore mirroring and snap to whatever
                // the global theme is right now so the change is visible
                // without waiting for the next global theme switch.
                context.mirrorsSharedTheme = true
                context.setTheme(manager.currentTheme)
            }
        }
    }

    // MARK: - Persistence helper used by slots

    /// Hands the captured tab URLs for `spaceId` to the spawn path — only
    /// when the spawned window's profile matches the pending intent, so a
    /// stale-profile spawn (persisted write still in flight) leaves the
    /// intent queued for the next spawn instead of replaying tabs into a
    /// window on the old profile.
    fileprivate func consumePendingProfileChangeReopenURLs(
        forSpaceId spaceId: String,
        profileId: String?
    ) -> [String]? {
        guard let pending = pendingProfileChangeReopens[spaceId],
              pending.profileId == profileId else { return nil }
        pendingProfileChangeReopens.removeValue(forKey: spaceId)
        return pending.urls
    }

    /// Slots call this after every `activate` so the persisted "last-active
    /// Space" tracks the most recent user choice across all slots. Used to
    /// initialize newly created slots (cold launch, additional windows
    /// without a pending spawn intent).
    fileprivate func persistActiveSpaceId(_ spaceId: String) {
        boundAccount?.userDefaults.set(spaceId, forKey: .activeSpaceId)
    }

    // MARK: - Account / login binding

    @objc private func handleLoginCompleted() {
        if let account = AccountController.shared.account {
            bind(to: account)
        }
    }

    @objc private func handleAccountChanged(_ notification: Notification) {
        if let account = notification.object as? Account {
            bind(to: account)
        } else {
            unbind()
        }
    }

    private func bind(to account: Account) {
        guard boundAccount !== account else { return }
        boundAccount = account
        // Load before the first Chromium window arrives so
        // `claimRestoredWindow` can answer for session-restore callbacks
        // that race the SwiftData publishers below.
        loadRestoreSnapshot()

        Task { @MainActor [weak self] in
            guard let self else { return }
            account.localStorage.ensureDefaultSpace(profileId: LocalStore.defaultProfileId)
            // No profileId filter — the sidebar shows every Space regardless
            // of which profile it's bound to. The publisher re-emits on any
            // SpaceModel write, so creating a Space on a non-default profile
            // appears immediately in the strip.
            self.spacesCancellable = account.localStorage
                .spacesPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] spaces in
                    self?.handleSpacesUpdate(spaces)
                }
            self.rulesCancellable = account.localStorage
                .urlRulesPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] rules in
                    self?.handleURLRulesUpdate(rules)
                }
        }
    }

    private func unbind() {
        boundAccount = nil
        spacesCancellable?.cancel()
        spacesCancellable = nil
        rulesCancellable?.cancel()
        rulesCancellable = nil
        cachedURLRules = []
        spaces = []
        // Tear down each slot's NotificationCenter registrations before
        // dropping the registry — controllers may keep the slots alive past
        // this point, and their observers would otherwise keep firing
        // against slots the manager no longer tracks.
        for slot in slots {
            slot.invalidate()
        }
        slots.removeAll()
        keySlot = nil
        restoreEntries.removeAll()
        restoreIndexByWindowId.removeAll()
        restoredSlotsByIndex.removeAll()
        pendingProfileChangeReopens.removeAll()
        // spaces is now empty, so this also clears the "Open link as" submenu.
        pushSpaceStateToChromium()
    }

    private func handleURLRulesUpdate(_ rules: [SpaceURLRule]) {
        cachedURLRules = rules
        pushRoutingTableToChromium()
    }

    private func handleSpacesUpdate(_ updated: [SpaceModel]) {
        spaces = updated
        let validIds = Set(updated.map(\.spaceId))

        // Reconcile each slot: if its active Space has been deleted out
        // from under it, fall back to the persisted default (still valid)
        // or the first known Space. Slots that are still on a valid Space
        // are left alone.
        let fallback: String? = {
            if let restored = persistedActiveSpaceId, validIds.contains(restored) {
                return restored
            }
            return updated.first?.spaceId
        }()

        for slot in slots {
            if let current = slot.activeSpaceId, validIds.contains(current) {
                continue
            }
            if let fallback {
                slot.activate(spaceId: fallback)
            } else {
                slot.clearActiveSpace()
            }
        }

        // Maintain the persisted default so newly created slots and
        // cold-launch reads land somewhere valid.
        if let fallback,
           let persisted = persistedActiveSpaceId,
           !validIds.contains(persisted) {
            boundAccount?.userDefaults.set(fallback, forKey: .activeSpaceId)
        } else if persistedActiveSpaceId == nil, let first = updated.first {
            boundAccount?.userDefaults.set(first.spaceId, forKey: .activeSpaceId)
        }

        // Profile-change respawns: once a changed Space reports its new
        // profileId, replace its window in place in the slot it stayed
        // visible in — the spawn path reads the new binding and replays the
        // captured tabs. The slot reference is cleared before respawning so
        // a later publisher emission can't fire it twice; the URLs are
        // consumed by the spawn path, so they survive a dead slot and
        // replay on the next manual activation instead.
        for (spaceId, pending) in pendingProfileChangeReopens {
            let updatedProfileId = updated.first(where: { $0.spaceId == spaceId })?.profileId
            guard updatedProfileId == pending.profileId else {
                AppLogInfo("[SpaceManager] changeProfile: respawn for \(spaceId) waiting — store reports \(updatedProfileId ?? "nil"), expecting \(pending.profileId)")
                continue
            }
            guard let slot = pending.respawnSlot else {
                if pending.urls.isEmpty {
                    pendingProfileChangeReopens.removeValue(forKey: spaceId)
                }
                continue
            }
            AppLogInfo("[SpaceManager] changeProfile: respawning \(spaceId) on \(pending.profileId)")
            pendingProfileChangeReopens[spaceId]?.respawnSlot = nil
            slot.respawnWindow(forSpaceId: spaceId)
        }

        // Space set / names / icons / order may have changed (routing rules
        // didn't, so only the submenu list needs refreshing).
        pushOpenLinkSpaceMenuToChromium()
    }
}

// MARK: - SpaceWindowSlot

/// Per-window-group container: one slot per user-perceived browser window.
///
/// Each slot owns a private set of `MainBrowserWindowController`s — one per
/// Space ever surfaced from this slot (lazy: the controller is only spawned
/// the first time the slot activates that Space). Exactly one of the slot's
/// controllers is on-screen at a time, the rest are kept around but hidden;
/// switching Spaces inside this slot swaps which controller is visible —
/// from the user's POV, "this window's contents change".
///
/// The slot does NOT coordinate with other slots: another slot can show the
/// same Space with its own dedicated controller, and both are visible at
/// once.
final class SpaceWindowSlot: ObservableObject {

    @Published private(set) var activeSpaceId: String?

    /// spaceId → controller dedicated to this slot for that Space.
    /// Populated lazily by `activate`'s spawn path and `registerWindow`.
    private(set) var windowsBySpaceId: [String: MainBrowserWindowController] = [:]

    /// The controller whose NSWindow is currently visible to the user in
    /// this slot. Kept in sync via `didBecomeKey` so any path that surfaces
    /// a window — our own `activate`, ⌘`, Dock click — is reflected here.
    ///
    /// The didSet swaps frame-change observers onto the new visible window
    /// so drags/resizes propagate to siblings (see `observeFrameChanges`).
    /// Weak-var auto-nil-out does NOT trigger didSet, so cleanup also runs
    /// from `deinit`.
    private(set) weak var visibleController: MainBrowserWindowController? {
        didSet {
            guard oldValue !== visibleController else { return }
            observeFrameChanges(on: visibleController)
        }
    }

    /// windowId → spaceId we asked Chromium to spawn that window for, for
    /// THIS slot. `activate(spaceId:)` populates this synchronously right
    /// after calling `bridge.createBrowserWithWindowType` so the asynchronous
    /// `mainBrowserWindowCreated` callback can tag the resulting window
    /// correctly — even if the user has clicked a different Space pip in the
    /// gap between request and callback.
    private var pendingSpawnSpaceIdByWindowId: [Int: String] = [:]

    /// windowId → NSRect to apply to that window before it surfaces.
    /// Set when `activate` spawns a new window so the new Space's NSWindow
    /// appears in the same place the previously visible one was — giving the
    /// illusion that the user is "swapping the contents" of one window.
    private var pendingFrameByWindowId: [Int: NSRect] = [:]

    /// spaceId → controller whose window a profile-change respawn left on
    /// screen until its replacement registers. Holds the only strong
    /// reference once the controller is evicted from `windowsBySpaceId`.
    /// Drained by `registerWindow`; the stale window is closed one turn
    /// later because registration runs inside Chromium's synchronous
    /// window-created callback, where closing a Browser re-entrantly is
    /// unsafe. See `respawnWindow(forSpaceId:)`.
    private var pendingCloseOnReplacementBySpaceId: [String: MainBrowserWindowController] = [:]

    /// Sidebar width/collapsed state pending application to a Space's window
    /// that hasn't been spawned yet. Consumed in `registerWindow` so the
    /// freshly-created window matches the previously visible Space's sidebar
    /// shape before it surfaces — keeps the "one window changing contents"
    /// illusion intact even on first activation of a Space.
    private var pendingSidebarWidthByWindowId: [Int: CGFloat] = [:]
    private var pendingSidebarCollapsedByWindowId: [Int: Bool] = [:]

    /// windowId → didBecomeKey observation, so we can keep `visibleController`
    /// in sync with reality and tear down on unregister to avoid stale
    /// callbacks against deallocated controllers.
    private var keyObservationsByWindowId: [Int: NSObjectProtocol] = [:]

    /// Space IDs whose imminent window close is driven by the user
    /// closing the last tab in the active Space (⌘W on tab / tab X
    /// button), not by closing the window itself. Populated by
    /// `markTabDrivenClose` from `CommandDispatcher` / `Tab.close()`
    /// just before dispatching `IDC_CLOSE_TAB` when only one tab
    /// remains; drained by `unregisterWindow` to decide whether to
    /// switch to a sibling Space (tab-driven) or cascade-close every
    /// Space and terminate (window-driven, the default).
    ///
    /// Stored as spaceId → expiration deadline rather than a plain
    /// set: when the dispatched `IDC_CLOSE_TAB` is vetoed (typically
    /// an `onbeforeunload` prompt the user cancels), no
    /// `unregisterWindow` ever fires to drain the marker, and a later
    /// window-driven close would otherwise misclassify itself as
    /// tab-driven. The TTL caps that stale window at
    /// `Self.tabDrivenCloseTTL` seconds.
    private var pendingTabDrivenCloseDeadlines: [String: Date] = [:]

    /// Maximum lifetime of a `pendingTabDrivenCloseDeadlines` entry.
    /// Realistic close-window roundtrip (dispatch IDC_CLOSE_TAB →
    /// Chromium closes tab → browser teardown → `[NSWindow close]` →
    /// `windowWillClose` → `unregisterWindow`) is well under 100ms,
    /// so 2s is comfortably above that ceiling while still expiring
    /// vetoed/swallowed markers before the user's next action can
    /// be misclassified.
    private static let tabDrivenCloseTTL: TimeInterval = 2.0

    /// spaceId → snapshot of the closing window's composited pixels,
    /// captured at `markTabDrivenClose` time and consumed by
    /// `unregisterWindow`. Snapshotting at IDC_CLOSE_TAB dispatch time
    /// (rather than at `windowWillClose`) is load-bearing for the swap
    /// animation: by the time the browser teardown reaches
    /// `unregisterWindow`, Chromium has already drained the WebContents
    /// and the contentView's GPU surface, so a snapshot taken there
    /// captures blank/partial pixels. Same lifetime semantics as
    /// `pendingTabDrivenCloseDeadlines` — drained alongside it.
    private var pendingTabDrivenCloseSnapshots: [String: NSImage] = [:]

    /// Set for the duration of an `activate(spaceId:)` call so the
    /// `didBecomeKey` notification that `makeKeyAndOrderFront` emits
    /// (synchronously or asynchronously) does not re-trigger animation
    /// through `handleWindowDidBecomeKey`. The handler animates only
    /// EXTERNAL switches — Chromium routing a tab into a sibling
    /// Space's window via the URL rule throttle, primarily — which we
    /// distinguish from self-initiated activations by this flag.
    private var isPerformingActivate = false

    /// `NSWindow.didMove` / `didResize` tokens for the currently-visible
    /// window. Swapped wholesale by `observeFrameChanges` whenever
    /// `visibleController` changes — only the visible window can be dragged
    /// or resized (siblings are `orderOut`'d), so observing exactly one
    /// window keeps propagation cheap and structurally prevents the
    /// setFrame-fires-didMove feedback loop a per-sibling observer would
    /// create.
    private var visibleFrameObservers: [NSObjectProtocol] = []

    /// The on-screen frame every Space window in this slot is kept aligned to
    /// — the slot's single source of truth for window position/size. Refreshed
    /// whenever the visible window moves or resizes (`observeFrameChanges`) and
    /// whenever a switch reads a live source frame (`resolveInheritedFrame`).
    /// Both the switch path and the spawn path inherit from it, so continuity
    /// no longer depends on the previous window still being alive and on-screen
    /// at the instant of the switch (e.g. an async cross-profile spawn whose
    /// source window closed during the profile load). Nil only before the slot
    /// has ever had a positioned window.
    private var lastKnownFrame: NSRect?

    /// True for the duration of a `performHorizontalWindowSlide`. Read by
    /// the `observeFrameChanges` propagation closure to early-return — the
    /// previous window's animated `didMove` would otherwise overwrite the
    /// target window's in-flight frame and break the slide.
    private var isAnimatingWindowSlide = false

    /// Cancellation handle for an in-flight window slide. Invoking it
    /// snaps both windows to their resting positions, clears
    /// `isAnimatingWindowSlide`, and orderOut's the previous window.
    /// Counterpart to `activeSidebarOverlay?.cancel()` etc.
    private var windowSlideCancel: (() -> Void)?

    /// Finalizes an in-flight vertical-layout push-in immediately: fronts the
    /// entering window, orders the leaving one out, and removes the band
    /// overlay. Unlike the horizontal slide, the vertical push-in keeps the
    /// LEAVING window front for the duration and only swaps on completion, so
    /// a superseding switch must settle the deferred swap before starting its
    /// own (otherwise the screen would stay on the wrong window).
    private var verticalSwapCancel: (() -> Void)?

    /// Bumped on each vertical push-in. The entering-band snapshot is captured
    /// one runloop late (so the target sidebar's SwiftUI has committed the new
    /// Space name); the deferred block bails if a newer switch has bumped this.
    private var verticalSwapToken = 0

    /// Per-frame timer that transitions the LEAVING window's theme to the
    /// entering Space's theme during a vertical push-in, so the whole-window
    /// background color ramps source -> target while the band slides. The
    /// leaving window's theme is restored once the swap completes (it stays
    /// the source Space's window and must look correct when next activated).
    private var themeRampTimer: Timer?

    /// The transient overlay that hosts the two sidebar snapshots while a
    /// swap animates. We keep a weak reference so rapid back-to-back
    /// switches can tear down the previous overlay (otherwise it would
    /// linger over the newly active window's sidebar until its own
    /// completion fires).
    private weak var activeSidebarOverlay: SidebarSwapOverlay?

    /// Animation timing for the cross-Space slide. Routed through
    /// `PhiPreferences` so the sidebar tint cross-fade in vertical layout
    /// stays in sync with this slide — both pick up the debug override
    /// when present.
    private static var swapAnimationDuration: TimeInterval {
        PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration()
    }

    private weak var manager: SpaceManager?

    init(manager: SpaceManager, initialSpaceId: String?) {
        self.manager = manager
        self.activeSpaceId = initialSpaceId
    }

    // MARK: - Public

    /// Switches this slot's visible NSWindow to the one hosting `spaceId`.
    /// The target inherits the previous visible window's frame so the swap
    /// looks like the contents of one window changing. If no window is
    /// registered in this slot for the Space yet, ask Chromium to spawn one
    /// — the pending-frame map carries the inherited frame to
    /// `registerWindow` so it lands before the new window surfaces.
    ///
    /// `leavingSnapshotOverride` is used by `unregisterWindow` when the
    /// previous (closing) window's contentView can no longer produce a
    /// usable snapshot — the override holds the composite captured at
    /// `markTabDrivenClose` time. Per-style animation functions consult
    /// it as a fallback after their own snapshot attempt fails.
    func activate(spaceId: String, leavingSnapshotOverride: NSImage? = nil, animated: Bool = true, onSwapSettled: (() -> Void)? = nil) {
        isPerformingActivate = true
        defer { isPerformingActivate = false }
        guard let manager,
              manager.spaces.contains(where: { $0.spaceId == spaceId }) else {
            AppLogWarn("[SpaceWindowSlot] activate ignored: unknown spaceId \(spaceId)")
            return
        }
        let previousSpaceId = activeSpaceId

        // Vertical push-in reads the leaving Space's sidebar band and color
        // BEFORE `activeSpaceId` flips below: the SpacesStrip name and the tint
        // gradient are bound to the shared slot, so capturing afterward would
        // bake in the TARGET Space (the name would change before the animation
        // and the background wouldn't transition).
        let isVerticalSwitch = spaceId != activeSpaceId
            && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let verticalLeavingBand: NSImage? = isVerticalSwitch
            ? visibleController?.mainSplitViewController.sidebarViewController.snapshotSpaceSwitchBand()
            : nil
        let sourceColorHex = manager.spaces.first(where: { $0.spaceId == previousSpaceId })?.colorHex
        let targetColorHex = manager.spaces.first(where: { $0.spaceId == spaceId })?.colorHex

        if spaceId != activeSpaceId {
            activeSpaceId = spaceId
            manager.persistActiveSpaceId(spaceId)
            // Mirror the per-slot active Space into the restore snapshot
            // so the next cold launch surfaces this Space — not whatever
            // was registered last.
            manager.persistSlotsSnapshot()
        }

        let previous = visibleController
        // The frame the entering Space's window inherits — resolved once, from
        // the slot's single source of truth, and shared by both the swap path
        // (target window already exists) and the spawn path (captured by the
        // closure below). Computing it here, while `previous` is guaranteed
        // alive, is what lets the async spawn path stay correct after the
        // source window goes away.
        let inheritedFrame = resolveInheritedFrame(from: previous)
        let direction = swapDirection(previousSpaceId: previousSpaceId, targetSpaceId: spaceId)

        if let target = windowsBySpaceId[spaceId] {
            if target !== previous {
                // Surface the target where the slot currently sits. Using the
                // shared `inheritedFrame` (the slot's source of truth) instead
                // of `previous.window.frame` keeps this correct even when the
                // source window isn't on-screen — mid-swap during rapid
                // switching, or a tab-driven close hand-off from a window
                // already torn down.
                if let inheritedFrame, let targetWindow = target.window {
                    targetWindow.setFrame(inheritedFrame, display: false)
                }
                // Align the target's sidebar shape to the previously visible
                // Space *before* it surfaces so the user reads a single
                // window whose contents change.
                if let previous {
                    let previousWidth = previous.browserState.sidebarWidth
                    target.mainSplitViewController.syncSidebar(
                        width: previousWidth > 0 ? previousWidth : nil,
                        collapsed: previous.browserState.sidebarCollapsed
                    )
                }
                // Switching into a tab-less Space (its window outlived a
                // last-tab close in placeholder mode) should greet the user
                // with a usable tab, not the placeholder. Create it before
                // the swap so the entering window surfaces on the new tab
                // page. Re-activating the already-visible Space is excluded
                // (`target !== previous`): the placeholder after closing the
                // last tab is deliberate, only a real switch replaces it.
                if target.browserState.tabs.isEmpty {
                    target.browserState.createQuickLookupTab()
                }
                if animated {
                    performSwap(
                        from: previous,
                        to: target,
                        direction: direction,
                        leavingSnapshotOverride: leavingSnapshotOverride,
                        verticalLeavingBand: verticalLeavingBand,
                        sourceColorHex: sourceColorHex,
                        targetColorHex: targetColorHex,
                        onSwapSettled: onSwapSettled
                    )
                    visibleController = target
                } else {
                    // Instant present (no slide) for `animated: false` callers:
                    // front the target and order the leaving window out in the
                    // same turn, then fire `onSwapSettled` with the target
                    // already on screen and `visibleController` repointed — so a
                    // post-swap close (e.g. `deleteSpace`) lands off-screen.
                    target.window?.makeKeyAndOrderFront(nil)
                    previous?.window?.orderOut(nil)
                    visibleController = target
                    onSwapSettled?()
                }
            }
            return
        }

        // Spawn path — no live window in this slot for this Space yet.
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("[SpaceWindowSlot] activate cannot spawn: bridge unavailable")
            return
        }
        // Settle any in-flight swap before spawning, exactly as the swap
        // path does inside its per-style animation functions. The vertical
        // push-in defers `makeKeyAndOrderFront(target)` to its completion;
        // left armed, that stale finalize would fire AFTER the spawned
        // window surfaces and re-front the superseded swap's target on top
        // of it — two visible windows. Hit reliably by `changeProfile`'s
        // retreat-then-respawn when the new profile is already loaded (the
        // respawn lands within the retreat animation's duration).
        verticalSwapCancel?()
        activeSidebarOverlay?.cancel()
        windowSlideCancel?()
        // Bind the new Chromium Browser to the Space's profile, re-read from
        // `spaces` on every spawn. When a Space is re-bound to another
        // profile (`changeProfile`), its windows are closed and the next
        // activation lands here to respawn on the new profile.
        let targetProfileId = manager.spaces.first(where: { $0.spaceId == spaceId })?.profileId
        let spawn: () -> Void = { [weak self, weak previous, weak manager] in
            guard let self = self else { return }
            // Record the spawn intent *before* createBrowser. Chromium's
            // BrowserList observer fires `mainBrowserWindowCreated`
            // SYNCHRONOUSLY inside createBrowser, so the windowId-keyed
            // map below is set too late to claim the new window — the
            // coordinator falls back to `manager.currentSpawn` instead.
            // `inheritedFrame` is the slot's shared source of truth, resolved
            // synchronously in `activate` while `previous` was still alive, so
            // it stays valid even if the source window closes during an async
            // profile load before this closure runs.
            let inheritedSidebarWidth = previous?.browserState.sidebarWidth ?? 0
            let inheritedSidebarCollapsed = previous?.browserState.sidebarCollapsed
            manager?.currentSpawn = SpaceManager.SpawnContext(
                slot: self,
                spaceId: spaceId,
                inheritedFrame: inheritedFrame,
                inheritedSidebarWidth: inheritedSidebarWidth,
                inheritedSidebarCollapsed: inheritedSidebarCollapsed
            )
            let dict = bridge.createBrowser(withWindowType: .normal,
                                            profileId: targetProfileId)
            // Clear in case the callback was async (rare) or createBrowser
            // failed before the observer fired — either way the hint is
            // no longer valid for any later arriving window.
            manager?.currentSpawn = nil
            // createBrowser returns nil when the window could not be created
            // (e.g. the Space's profile failed to load during a collapse).
            // The bridge return is nonnull-imported, so an unguarded nil
            // traps right here — bail gracefully instead.
            guard let dict else {
                AppLogWarn("[SpaceWindowSlot] createBrowserWithWindowType returned nil")
                return
            }
            guard let windowIdNumber = dict["windowId"] as? NSNumber else {
                AppLogWarn("[SpaceWindowSlot] createBrowserWithWindowType returned no windowId")
                return
            }
            let id = windowIdNumber.intValue
            // Backfill the windowId-keyed intent so an async-callback
            // implementation continues to work without relying on
            // `currentSpawn`. Skipped when the callback already ran
            // synchronously inside createBrowser (the common case): the
            // controller is registered by now and `registerWindow` has
            // drained these maps, so re-adding would strand one stale
            // entry per spawn.
            if !self.contains(windowId: id) {
                if self.pendingSpawnSpaceIdByWindowId[id] == nil {
                    self.pendingSpawnSpaceIdByWindowId[id] = spaceId
                }
                if let inheritedFrame, self.pendingFrameByWindowId[id] == nil {
                    self.pendingFrameByWindowId[id] = inheritedFrame
                }
                if let inheritedSidebarCollapsed,
                   self.pendingSidebarCollapsedByWindowId[id] == nil {
                    self.pendingSidebarWidthByWindowId[id] = inheritedSidebarWidth
                    self.pendingSidebarCollapsedByWindowId[id] = inheritedSidebarCollapsed
                }
            }
            // Re-assert the inherited frame now that `createBrowser` has
            // returned. `registerWindow` already applied it in the
            // window-controller ctor, but Chromium surfaces the new window via
            // `BrowserWindow::Show()` (PhiBrowserProxyFactory) AFTER the ctor
            // returns — and Show()/the WindowSizer snap the freshly-spawned
            // window to a default "origin" position, clobbering our frame. That
            // is why the first switch to a Space (the one that spawns its
            // window) lands at the origin instead of where the user left the
            // previous Space's window. This runs in the same runloop turn as
            // Show(), so there is no visible jump; the next-turn re-assert also
            // overrides the async remote_cocoa bounds update that can still land
            // afterward. Both are idempotent no-ops once the frame has stuck.
            if let inheritedFrame {
                self.windowsBySpaceId[spaceId]?.window?.setFrame(inheritedFrame, display: false)
                DispatchQueue.main.async { [weak self] in
                    self?.windowsBySpaceId[spaceId]?.window?.setFrame(inheritedFrame, display: false)
                }
            }
            // A spawned Browser starts with zero tabs and nothing else
            // populates it (the placeholder shell only engages on
            // last-tab-close), so the Space would surface as an empty
            // window. Replay tabs captured by a profile change when one is
            // queued for this (Space, profile) pair; otherwise give it a
            // new tab page. Routed through the bridge by windowId rather
            // than the controller's BrowserState so the rare
            // async-registration path (controller not yet in
            // `windowsBySpaceId`) is covered too; the tabs.isEmpty check
            // keeps this idempotent should the spawn contract ever change.
            if self.windowsBySpaceId[spaceId]?.browserState.tabs.isEmpty != false {
                if let reopenURLs = manager?.consumePendingProfileChangeReopenURLs(
                    forSpaceId: spaceId,
                    profileId: targetProfileId
                ), !reopenURLs.isEmpty {
                    AppLogInfo("[SpaceWindowSlot] spawn(\(spaceId)) on \(targetProfileId ?? "nil"): replaying \(reopenURLs.count) captured tab(s)")
                    for (index, url) in reopenURLs.enumerated() {
                        bridge.createNewTab(withUrl: url,
                                            windowId: windowIdNumber.int64Value,
                                            customGuid: nil,
                                            focusAfterCreate: index == 0)
                    }
                } else {
                    bridge.createQuickLookupTab(withWindowId: windowIdNumber.int64Value,
                                                customGuid: nil)
                }
            }
            // The new window's `makeKeyAndOrderFront` happens after this turn
            // (inside the coordinator's `mainBrowserWindowCreated` after our
            // controller-init returns). On the next runloop the new window is
            // up — animate the switch, then hide the previous so the screen
            // never goes blank.
            if let previous {
                DispatchQueue.main.async { [weak self, weak previous] in
                    guard let self,
                          let registered = self.windowsBySpaceId[spaceId],
                          registered.window?.isVisible == true else { return }
                    // First switch to a Space spawns its window, so there is no
                    // existing window for `activate` to slide — without this the
                    // first switch surfaces with no animation. Chromium has
                    // already fronted the new window, so this is the external-
                    // switch shape: slide the new window's sidebar band (the
                    // clicked push-in animates on the LEAVING window, which is
                    // about to be hidden here, so it would play off-screen).
                    // Bandless / horizontal layouts fall through to a plain
                    // present, matching today's behavior.
                    if !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional,
                       let leavingBand = verticalLeavingBand {
                        self.performExternalVerticalSlide(
                            target: registered,
                            leavingBand: leavingBand,
                            direction: direction,
                            sourceColorHex: sourceColorHex,
                            targetColorHex: targetColorHex
                        )
                    }
                    previous?.window?.orderOut(nil)
                    // The spawned target is up and the leaving window is
                    // hidden — let a post-swap close (e.g. `deleteSpace`) run
                    // now that it lands off-screen. No-op for ordinary
                    // switches, which pass no handler.
                    onSwapSettled?()
                }
            }
        }
        // Lazy-load the Space's profile before spawning. Completion fires
        // synchronously when the profile is already in memory (the common
        // case), so this is free for warm switches. First cross-profile
        // activation of the session pays the load cost (~100–300ms) — the
        // deferred orderOut inside `spawn` keeps the previous window on
        // screen until the new window paints, hiding that latency.
        if let pid = targetProfileId, !pid.isEmpty {
            bridge.ensureProfileLoaded(pid) { success in
                guard success else {
                    // Spawning anyway would hand the Space a window on
                    // whatever profile Chromium substitutes — another
                    // profile's pinned tabs inside this Space. The bridge
                    // refuses unresolved profiles too (returns nil); bail
                    // here so the previous window simply stays on screen.
                    AppLogWarn("[SpaceWindowSlot] ensureProfileLoaded failed for \(pid); not spawning")
                    return
                }
                spawn()
            }
        } else {
            spawn()
        }
    }

    /// Returns the direction the new Space should appear to enter from.
    /// `.forward` means the target sits to the right of the previous Space in
    /// the strip → the new window slides in from the right, the previous
    /// slides off to the left. `.backward` mirrors that. Unknown previous
    /// (e.g. first activation) defaults to `.forward` so the motion is
    /// consistent.
    private func swapDirection(previousSpaceId: String?, targetSpaceId: String) -> SwapDirection {
        guard let manager,
              let previousSpaceId,
              let previousIdx = manager.spaces.firstIndex(where: { $0.spaceId == previousSpaceId }),
              let targetIdx = manager.spaces.firstIndex(where: { $0.spaceId == targetSpaceId }) else {
            return .forward
        }
        return targetIdx >= previousIdx ? .forward : .backward
    }

    fileprivate enum SwapDirection { case forward, backward }

    /// Swaps the visible window using the animation style the user picked
    /// in General settings. `slide` is the original sidebar-only translation
    /// (kept as the default for layout continuity); `fade` cross-fades a
    /// snapshot of the leaving window over the entering one. Both styles
    /// fall back to an instant present when the precondition for an animated
    /// swap is missing (no previous visible window, missing snapshot, etc.).
    private func performSwap(
        from previous: MainBrowserWindowController?,
        to target: MainBrowserWindowController,
        direction: SwapDirection,
        leavingSnapshotOverride: NSImage? = nil,
        verticalLeavingBand: NSImage? = nil,
        sourceColorHex: String? = nil,
        targetColorHex: String? = nil,
        onSwapSettled: (() -> Void)? = nil
    ) {
        guard let targetWindow = target.window else {
            previous?.window?.orderOut(nil)
            // Target has no window — the switch failed, so do NOT fire
            // `onSwapSettled`: a caller closing the leaving window on the back
            // of it would leave the slot with nothing on screen.
            return
        }
        let previousWindow = previous?.window
        let previousVisible = previousWindow?.isVisible == true
        // An animation needs either a live, visible previous window the
        // per-style function can snapshot OR a pre-captured override.
        // Without either, surface the target instantly.
        guard previousVisible || leavingSnapshotOverride != nil else {
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow?.orderOut(nil)
            onSwapSettled?()
            return
        }

        // Vertical layout: the per-Space content band (pinned tabs, Spaces
        // strip, tab list) pushes in horizontally while the sidebar tint
        // gradient ramps to the new Space's color; the workspace (web content)
        // swaps only once the push completes. The address bar and bottom
        // toolbar stay put — they're the leaving window's live chrome, which
        // remains front for the whole animation. Horizontal layout routes
        // through the window slide below instead.
        if !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            performVerticalSidebarPushIn(
                from: previous,
                previousWindow: previousWindow,
                to: target,
                targetWindow: targetWindow,
                direction: direction,
                leavingBand: verticalLeavingBand,
                sourceColorHex: sourceColorHex,
                targetColorHex: targetColorHex,
                onSwapSettled: onSwapSettled
            )
            return
        }

        performSlideSwap(
            from: previous,
            previousWindow: previousWindow,
            to: target,
            targetWindow: targetWindow,
            direction: direction,
            leavingSnapshotOverride: leavingSnapshotOverride,
            onSwapSettled: onSwapSettled
        )
    }

    /// Vertical-layout Space switch. Keeps the LEAVING window front and slides
    /// the entering Space's sidebar content band in over the leaving band (old
    /// pushes out one side as new enters from the other), while the leaving
    /// window's tint gradient ramps from the source color to the target color
    /// underneath. The window swap — and therefore the visible workspace
    /// change — is deferred to the animation's completion, so the address bar,
    /// bottom toolbar, and web content stay on the old Space until the push
    /// finishes.
    ///
    /// Timing matters because the SpacesStrip name and tint are bound to the
    /// shared slot, which `activate` already flipped to the target:
    ///  - `leavingBand` is captured by `activate` BEFORE the flip, so it
    ///    carries the source Space's name/content.
    ///  - the entering band is snapshotted one runloop later, after the target
    ///    sidebar's SwiftUI has committed the new name.
    /// In between, the live band is hidden and a static placeholder of the
    /// leaving band stands in, so the strip name never visibly changes ahead
    /// of the slide.
    ///
    /// Both bands are content-only (transparent background) so the ramping
    /// gradient shows through. Falls back to an instant present whenever a
    /// precondition is missing.
    private func performVerticalSidebarPushIn(
        from previous: MainBrowserWindowController?,
        previousWindow: NSWindow?,
        to target: MainBrowserWindowController,
        targetWindow: NSWindow,
        direction: SwapDirection,
        leavingBand: NSImage?,
        sourceColorHex: String?,
        targetColorHex: String?,
        onSwapSettled: (() -> Void)? = nil
    ) {
        // Settle any in-flight push-in or slide before starting a new one. The
        // vertical push-in keeps the leaving window front until completion, so
        // its deferred swap must be finalized first or the screen would stay
        // on the wrong window.
        verticalSwapCancel?()
        activeSidebarOverlay?.cancel()
        windowSlideCancel?()

        let presentInstantly: () -> Void = {
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow?.orderOut(nil)
            onSwapSettled?()
        }

        let targetSidebar = target.mainSplitViewController.sidebarViewController
        let duration = Self.swapAnimationDuration
        guard duration > 0,
              let previousWindow,
              previousWindow.isVisible,
              let previous,
              let leavingImage = leavingBand else {
            presentInstantly()
            return
        }
        let prevSidebar = previous.mainSplitViewController.sidebarViewController

        // The whole-window background color is theme-driven and per-Space, so
        // it would otherwise jump when the window swaps at the end. Transition
        // the LEAVING (visible) window's theme to the entering Space's theme
        // during the slide so the swap lands on a matching color; restore it
        // afterward since the leaving window keeps the source Space.
        let prevThemeContext = previous.browserState.themeContext
        let sourceTheme = prevThemeContext.currentTheme
        let sourceMirrors = prevThemeContext.mirrorsSharedTheme
        let targetTheme = target.browserState.themeContext.currentTheme

        // Keep frames aligned even though the target is fronted only on
        // completion (the sidebar width was already synced by `activate`).
        targetWindow.setFrame(previousWindow.frame, display: false)

        let bandFrame = prevSidebar.spaceSwitchBandFrame
        guard bandFrame.width > 0, bandFrame.height > 0 else {
            presentInstantly()
            return
        }

        verticalSwapToken += 1
        let token = verticalSwapToken

        // Hide the live band (its strip is flipping to the new name on the
        // shared slot) and stand a static copy of the leaving band in its place
        // so nothing visibly changes while we wait one runloop for the target's
        // SwiftUI to commit. The tint gradient lives behind the stack, so it
        // stays visible and ramps underneath.
        prevSidebar.setSwitchBandContentHidden(true)
        let placeholder = NSImageView(frame: bandFrame)
        placeholder.image = leavingImage
        placeholder.imageScaling = .scaleAxesIndependently
        placeholder.imageAlignment = .alignTopLeft
        placeholder.autoresizingMask = []
        prevSidebar.view.addSubview(placeholder, positioned: .above, relativeTo: nil)

        var didFinish = false
        let finalize: () -> Void = { [weak self, weak prevSidebar, weak placeholder] in
            guard !didFinish else { return }
            didFinish = true
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow.orderOut(nil)
            placeholder?.removeFromSuperview()
            self?.activeSidebarOverlay?.cancel()
            prevSidebar?.setSwitchBandContentHidden(false)
            // Restore the leaving window's own theme now that it's hidden, so
            // it shows the source Space's colors when next activated.
            self?.themeRampTimer?.invalidate()
            self?.themeRampTimer = nil
            prevThemeContext.setTheme(sourceTheme)
            prevThemeContext.mirrorsSharedTheme = sourceMirrors
            self?.verticalSwapCancel = nil
            // The swap has landed and the leaving window is ordered out — run
            // any post-swap close now that it's off-screen. `didFinish` guards
            // this to exactly one call across the overlay/cancel paths.
            onSwapSettled?()
        }
        verticalSwapCancel = finalize

        // Defer the entering snapshot + slide one runloop so the target
        // sidebar's strip shows the new Space name (bail if superseded).
        DispatchQueue.main.async { [weak self, weak prevSidebar] in
            guard let self, self.verticalSwapToken == token, !didFinish,
                  let prevSidebar else { return }
            targetSidebar.view.layoutSubtreeIfNeeded()
            guard let enteringImage = targetSidebar.snapshotSpaceSwitchBand() else {
                finalize()
                return
            }
            let overlay = SidebarSwapOverlay(
                frame: bandFrame,
                leavingImage: leavingImage,
                enteringImage: enteringImage,
                direction: direction
            )
            // Above the content band only — the header (address bar) and bottom
            // toolbar sit outside `bandFrame` and stay exposed/static.
            prevSidebar.view.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.activeSidebarOverlay = overlay
            // The overlay's leaving half sits at rest (x=0) exactly where the
            // placeholder was, so removing the placeholder is seamless.
            placeholder.removeFromSuperview()
            // Ramp the whole-window theme AND the sidebar tint in lockstep with
            // the slide so the background transitions source -> target across
            // the same window, landing on the target's colors at the swap.
            self.rampWindowTheme(prevThemeContext, from: sourceTheme, to: targetTheme, duration: duration)
            prevSidebar.rampSpaceTint(fromHex: sourceColorHex, toHex: targetColorHex, duration: duration)
            overlay.runAnimation(duration: duration) { finalize() }
        }
    }

    /// Vertical-layout band slide for an EXTERNAL switch (Chromium routed a
    /// navigation into a sibling Space's window via the URL rule throttle and
    /// already made that window key + front). The clicked-switch push-in draws
    /// on the LEAVING window and reveals the target only on completion — but
    /// here Chromium has surfaced the target already, so the leaving window is
    /// behind it and that animation would play hidden. Instead we slide the
    /// band swap directly on the (already front) TARGET sidebar: the leaving
    /// Space's band — captured by `handleWindowDidBecomeKey` before the slot
    /// flipped — pushes out as the target's own band pushes in, with the tint
    /// ramping underneath. No window swap occurs (the target is already shown).
    ///
    /// The target's web content is already the new Space's (Chromium swapped
    /// it), so only the sidebar band animates; that's the most a post-hoc
    /// notification can choreograph without controlling Chromium's swap timing.
    private func performExternalVerticalSlide(
        target: MainBrowserWindowController,
        leavingBand: NSImage,
        direction: SwapDirection,
        sourceColorHex: String?,
        targetColorHex: String?
    ) {
        let duration = Self.swapAnimationDuration
        let targetSidebar = target.mainSplitViewController.sidebarViewController
        let bandFrame = targetSidebar.spaceSwitchBandFrame
        guard duration > 0, bandFrame.width > 0, bandFrame.height > 0 else {
            return
        }

        // Settle any in-flight swap before starting a new band slide so tokens
        // and the shared overlay handle stay consistent with the clicked path.
        verticalSwapCancel?()
        activeSidebarOverlay?.cancel()

        // Hide the target's live band (mid-flip to the new name on the shared
        // slot) and stand a static copy of the LEAVING band in its place so the
        // strip doesn't pop to the new name before the slide. The tint gradient
        // lives behind the stack and stays visible to ramp underneath.
        targetSidebar.setSwitchBandContentHidden(true)
        let placeholder = NSImageView(frame: bandFrame)
        placeholder.image = leavingBand
        placeholder.imageScaling = .scaleAxesIndependently
        placeholder.imageAlignment = .alignTopLeft
        placeholder.autoresizingMask = []
        targetSidebar.view.addSubview(placeholder, positioned: .above, relativeTo: nil)

        verticalSwapToken += 1
        let token = verticalSwapToken
        var didFinish = false
        let finalize: () -> Void = { [weak self, weak targetSidebar, weak placeholder] in
            guard !didFinish else { return }
            didFinish = true
            placeholder?.removeFromSuperview()
            self?.activeSidebarOverlay?.cancel()
            targetSidebar?.setSwitchBandContentHidden(false)
            self?.verticalSwapCancel = nil
        }
        verticalSwapCancel = finalize

        // Defer one runloop so the target sidebar's strip has committed the new
        // Space name before we snapshot the entering band (bail if superseded).
        DispatchQueue.main.async { [weak self, weak targetSidebar] in
            guard let self, self.verticalSwapToken == token, !didFinish,
                  let targetSidebar else { return }
            targetSidebar.view.layoutSubtreeIfNeeded()
            guard let enteringImage = targetSidebar.snapshotSpaceSwitchBand() else {
                finalize()
                return
            }
            let overlay = SidebarSwapOverlay(
                frame: bandFrame,
                leavingImage: leavingBand,
                enteringImage: enteringImage,
                direction: direction
            )
            targetSidebar.view.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.activeSidebarOverlay = overlay
            placeholder.removeFromSuperview()
            targetSidebar.rampSpaceTint(fromHex: sourceColorHex, toHex: targetColorHex, duration: duration)
            overlay.runAnimation(duration: duration) { finalize() }
        }
    }

    /// Per-frame interpolation of `context`'s theme from `from` to `to` over
    /// `duration`. `BrowserThemeContext.setTheme` notifies themed views which
    /// re-resolve their colors synchronously, but the resulting layer writes
    /// don't animate on their own — so driving the model each frame is what
    /// makes the whole-window color transition visible. Mirroring is disabled
    /// for the duration so a global theme tick can't fight the ramp.
    private func rampWindowTheme(
        _ context: BrowserThemeContext,
        from: Theme,
        to: Theme,
        duration: TimeInterval
    ) {
        themeRampTimer?.invalidate()
        themeRampTimer = nil
        guard duration > 0 else {
            context.setTheme(to)
            return
        }
        context.mirrorsSharedTheme = false
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak context] t in
            guard let context else { t.invalidate(); return }
            let progress = min(1.0, (CACurrentMediaTime() - start) / duration)
            let eased: CGFloat = progress < 0.5
                ? 2 * progress * progress
                : 1 - pow(-2 * progress + 2, 2) / 2
            context.setTheme(Self.interpolatedTheme(from: from, to: to, progress: eased))
            if progress >= 1.0 { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        themeRampTimer = timer
    }

    /// Builds a theme whose palette is `from` blended toward `to` by
    /// `progress`, across every `ColorRole`, for both light and dark.
    private static func interpolatedTheme(from: Theme, to: Theme, progress: CGFloat) -> Theme {
        let theme = Theme(id: to.id, name: to.name)
        for role in ColorRole.allCases {
            let f = from.colorPair(for: role)
            let t = to.colorPair(for: role)
            theme.setColor(
                light: lerpColor(f.light, t.light, progress),
                dark: lerpColor(f.dark, t.dark, progress),
                for: role
            )
        }
        return theme
    }

    private static func lerpColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        // Some role defaults resolve to catalog/system colors that don't expose
        // RGBA components; if either side can't convert, snap to the target.
        guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else {
            return b
        }
        return NSColor(
            srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
            alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t
        )
    }

    /// Horizontal-layout slide. The dispatcher gates vertical out before
    /// this is ever called, so this function is horizontal-only.
    ///
    /// Live previous window: route to `performHorizontalWindowSlide`, which
    /// animates the two NSWindows themselves so the entering side carries
    /// real Chromium GPU pixels rather than a blank web area sliding in.
    ///
    /// Tab-driven close (`leavingSnapshotOverride` set, no live previous):
    /// fall through to the snapshot overlay below, which is the only path
    /// that can consume the pre-captured composite.
    private func performSlideSwap(
        from previous: MainBrowserWindowController?,
        previousWindow: NSWindow?,
        to target: MainBrowserWindowController,
        targetWindow: NSWindow,
        direction: SwapDirection,
        leavingSnapshotOverride: NSImage? = nil,
        onSwapSettled: (() -> Void)? = nil
    ) {
        if leavingSnapshotOverride == nil,
           let previousWindow,
           previousWindow.isVisible {
            performHorizontalWindowSlide(
                previousWindow: previousWindow,
                target: target,
                targetWindow: targetWindow,
                direction: direction,
                onSwapSettled: onSwapSettled
            )
            return
        }

        guard let targetContent = targetWindow.contentView else {
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow?.orderOut(nil)
            onSwapSettled?()
            return
        }

        // Live composite of the closing window (still in the window list)
        // captures the Chromium GPU surface; if that fails, fall back to
        // the pre-captured override from `markTabDrivenClose`.
        let previousImage: NSImage?
        if let previousWindow {
            previousImage = snapshotWindowComposite(of: previousWindow)
                ?? leavingSnapshotOverride
        } else {
            previousImage = leavingSnapshotOverride
        }
        guard let previousImage else {
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow?.orderOut(nil)
            onSwapSettled?()
            return
        }

        // Force layout on the target so its content reflects the just-synced
        // shape before we snapshot it. The window is still off-screen here,
        // but AppKit layout is independent of visibility.
        targetContent.layoutSubtreeIfNeeded()

        guard let targetImage = snapshotContent(of: targetContent) else {
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow?.orderOut(nil)
            onSwapSettled?()
            return
        }

        // Kill any older overlay still on screen — without this, a rapid
        // A → B → C tap leaves B's overlay covering C until its own
        // animation finishes.
        activeSidebarOverlay?.cancel()
        windowSlideCancel?()

        let overlay = SidebarSwapOverlay(
            frame: targetContent.bounds,
            leavingImage: previousImage,
            enteringImage: targetImage,
            direction: direction
        )
        // Add overlay BEFORE the window becomes visible so the user never
        // sees a frame of the target content in its final state under the
        // sliding snapshots.
        targetContent.addSubview(overlay, positioned: .above, relativeTo: nil)
        activeSidebarOverlay = overlay

        targetWindow.makeKeyAndOrderFront(nil)
        previousWindow?.orderOut(nil)

        overlay.runAnimation(duration: Self.swapAnimationDuration) { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if self?.activeSidebarOverlay === overlay {
                self?.activeSidebarOverlay = nil
            }
            // Leaving window was ordered out before the slide began, so a
            // post-swap close is safe now that the animation has settled.
            onSwapSettled?()
        }
    }

    /// Horizontal-layout slide that stays entirely inside the previous
    /// window's frame — nothing visibly extends past it.
    ///
    /// Mechanics: snap the target window to the previous window's frame,
    /// translate each existing subview of the target's contentView via
    /// `CALayer.transform` so they're pre-positioned off-frame (sliding
    /// IN as REAL views — Chromium GPU pixels included, no blank web
    /// area), then add a single composite snapshot of the leaving
    /// window as a new sibling subview above them (sliding OUT). Both
    /// elements live inside the target window's contentView and clip
    /// naturally to its bounds (= window content rect), so anything
    /// that would extend past the original frame is hidden.
    ///
    /// `target.mainSplitViewController.view` IS the window's contentView
    /// here (set via `contentViewController`), so the leaving overlay
    /// can't be a sibling of it — it has to be a child of contentView,
    /// alongside the existing subviews that we translate. Capturing the
    /// existing subviews into `enteringSubviews` BEFORE adding the
    /// overlay keeps the overlay out of the translation loop.
    private func performHorizontalWindowSlide(
        previousWindow: NSWindow,
        target: MainBrowserWindowController,
        targetWindow: NSWindow,
        direction: SwapDirection,
        onSwapSettled: (() -> Void)? = nil
    ) {
        activeSidebarOverlay?.cancel()
        windowSlideCancel?()

        // Which traffic lights this slide suppresses is debug-tunable
        // (General ▸ Debug). The ship default, `source`, captures the leaving
        // window WITHOUT its traffic-light buttons so the sliding snapshot
        // carries none — the only buttons visible during the slide are then
        // the target window's real ones (the destination), which stay put at
        // top-left. We fade the SOURCE's buttons to alpha 0, capture, then
        // restore them. This is the one approach here that does NOT break the
        // target's standardWindowButton rendering — editing the
        // already-captured snapshot does (see the dead-end note further down).
        // `target` keeps the source's buttons in the snapshot (they slide out
        // with it) and instead hides the destination's live buttons until the
        // slide finalizes; `both` combines the two.
        //
        // CGWindowListCreateImage reads the WindowServer's composited frame,
        // which only reflects the alpha change once the layer transaction has
        // committed to the render server — hence the explicit
        // commit + CATransaction.flush() before capturing. A plain
        // window.display() (tried previously) does NOT suffice: it redraws the
        // AppKit backing, not the layer composite the capture reads.
        let trafficLightHiding = PhiPreferences.GeneralSettings.loadSwitchSpaceTrafficLightHiding()
        let trafficLightTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let leavingButtons = trafficLightHiding.hidesSource
            ? trafficLightTypes.compactMap { previousWindow.standardWindowButton($0) }
            : []
        let leavingButtonAlphas = leavingButtons.map { $0.alphaValue }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for btn in leavingButtons { btn.alphaValue = 0 }
        CATransaction.commit()
        CATransaction.flush()
        let leavingSnapshot = snapshotWindowComposite(of: previousWindow)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (btn, alpha) in zip(leavingButtons, leavingButtonAlphas) { btn.alphaValue = alpha }
        CATransaction.commit()

        guard let targetContent = targetWindow.contentView,
              !targetContent.subviews.isEmpty,
              let leavingImage = leavingSnapshot else {
            targetWindow.setFrame(previousWindow.frame, display: false)
            targetWindow.makeKeyAndOrderFront(nil)
            previousWindow.orderOut(nil)
            onSwapSettled?()
            return
        }

        let restingFrame = previousWindow.frame
        targetWindow.setFrame(restingFrame, display: false)
        targetContent.layoutSubtreeIfNeeded()

        let contentBounds = targetContent.bounds
        let width = contentBounds.width
        let forward = (direction == .forward)
        let mainStartDx: CGFloat = forward ?  width : -width
        let leavingEndDx: CGFloat = forward ? -width :  width

        // Snapshot the subview list BEFORE adding the leaving overlay
        // so the overlay never gets translated with the entering content.
        let enteringSubviews = targetContent.subviews
        let setEnteringTransform: (CGFloat) -> Void = { dx in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for v in enteringSubviews {
                v.wantsLayer = true
                v.layer?.transform = CATransform3DMakeTranslation(dx, 0, 0)
            }
            CATransaction.commit()
        }
        setEnteringTransform(mainStartDx)

        let leavingView = NSImageView(frame: contentBounds)
        leavingView.image = leavingImage
        leavingView.imageScaling = .scaleAxesIndependently
        leavingView.imageAlignment = .alignTopLeft
        leavingView.autoresizingMask = []
        targetContent.addSubview(leavingView, positioned: .above, relativeTo: nil)

        // Target-side suppression (`target` / `both` modes): fade the
        // destination window's live buttons to alpha 0 before it comes
        // onscreen so they never flash, and restore them in `finalize`.
        // In the default `source` mode this is a no-op — the snapshot was
        // captured with the source's traffic lights already faded out
        // (above), so the target's real buttons are the only set on screen.
        // Editing the captured snapshot to erase the buttons (lockFocus
        // paint-over / CAShapeLayer mask on leavingView) was tried in a
        // prior pass and broke the target's standardWindowButton rendering;
        // hiding live buttons instead avoids that path entirely.
        let targetButtons = trafficLightHiding.hidesTarget
            ? trafficLightTypes.compactMap { targetWindow.standardWindowButton($0) }
            : []
        let targetButtonAlphas = targetButtons.map { $0.alphaValue }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for btn in targetButtons { btn.alphaValue = 0 }
        CATransaction.commit()

        targetWindow.makeKeyAndOrderFront(nil)
        previousWindow.orderOut(nil)

        isAnimatingWindowSlide = true

        let duration = Self.swapAnimationDuration
        var didFinish = false
        var timer: Timer?
        let finalize: (Bool) -> Void = { [weak self, weak leavingView] cancelled in
            _ = cancelled
            guard !didFinish else { return }
            didFinish = true
            timer?.invalidate()
            timer = nil
            setEnteringTransform(0)
            leavingView?.removeFromSuperview()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (btn, alpha) in zip(targetButtons, targetButtonAlphas) { btn.alphaValue = alpha }
            CATransaction.commit()
            self?.isAnimatingWindowSlide = false
            self?.windowSlideCancel = nil
            // Leaving window was ordered out before the slide began, so a
            // post-swap close is safe now. `didFinish` guards this to exactly
            // one call across the tick / cancel / duration<=0 paths.
            onSwapSettled?()
        }
        windowSlideCancel = { finalize(true) }

        // Drive the slide manually. CALayer's implicit animation is
        // disabled per tick (CATransaction setDisableActions) so the
        // duration is exactly the user-tunable preference rather than
        // the layer's default 0.25s.
        if duration <= 0 {
            finalize(false)
            return
        }

        let startTime = CACurrentMediaTime()
        let easeInOut: (CGFloat) -> CGFloat = { t in
            t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }

        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak leavingView] t in
            guard let leavingView else {
                t.invalidate()
                finalize(true)
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            let progress = CGFloat(min(1.0, elapsed / duration))
            let eased = easeInOut(progress)
            setEnteringTransform(mainStartDx * (1 - eased))
            leavingView.frame = contentBounds.offsetBy(dx: leavingEndDx * eased, dy: 0)
            if progress >= 1.0 {
                finalize(false)
            }
        }
        timer = tick
        // `.common` so the slide keeps ticking during modal tracking
        // (window drag, menu open) — would freeze on `.default` mode.
        RunLoop.main.add(tick, forMode: .common)
    }

    /// Captures `view`'s current pixels as an NSImage for the slide overlay.
    /// Returns nil when the view has no rendered area, which is the only
    /// honest signal that the overlay path can't run. Note: views hosting
    /// GPU-backed surfaces (e.g. the Chromium web contents) may rasterize
    /// as their underlying background — fine for the entering-side
    /// snapshot since the dominant visible chrome carries the transition.
    private func snapshotContent(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Captures the entire composited window — including the Chromium web
    /// area — by routing through the WindowServer instead of AppKit's
    /// `cacheDisplay`. The web view renders to a GPU surface that
    /// `bitmapImageRepForCachingDisplay` cannot see; without this path the
    /// zoom animation only scales the AppKit chrome and the web area stays
    /// stationary, which reads as broken. `CGWindowListCreateImage` is
    /// marked deprecated on macOS 14.4+ in favor of ScreenCaptureKit but
    /// remains functional for capturing the app's own windows without
    /// permission prompts; revisit if Apple removes it.
    private func snapshotWindowComposite(of window: NSWindow) -> NSImage? {
        guard window.isVisible, window.windowNumber > 0 else { return nil }
        let windowID = CGWindowID(window.windowNumber)
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            options
        ) else { return nil }
        let size = window.contentView?.bounds.size ?? window.frame.size
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Registration (called by SpaceManager / MainBrowserWindowController)

    /// Registers (or replaces) the controller hosting `spaceId` in this slot.
    /// Idempotent. Window controllers call this from `init` once their slot
    /// has been resolved by the coordinator.
    ///
    /// Side effects beyond the map insert:
    ///  - Applies any pending frame queued by `activate`'s spawn path so the
    ///    new NSWindow surfaces in the previously visible window's frame.
    ///  - Observes the window's `didBecomeKey` so `visibleController` and
    ///    `activeSpaceId` track reality (manual ⌘`, Dock click, etc.) and
    ///    so the manager's `keySlot` updates to this slot.
    ///  - Initializes `visibleController` on the very first registration so
    ///    the first launched window owns the "visible" slot without waiting
    ///    for a key event.
    ///  - Applies any persisted per-Space theme override so the new window
    ///    adopts it on first paint.
    func registerWindow(_ controller: MainBrowserWindowController, for spaceId: String) {
        windowsBySpaceId[spaceId] = controller
        // Drain any spawn-intent entry for this windowId. On the async
        // callback path `claimPendingSpawn` consumed it already; on the
        // synchronous path `absorbCurrentSpawn` wrote it moments ago and
        // nothing reads it after this point — leaving it would strand one
        // entry per spawn for the slot's lifetime.
        pendingSpawnSpaceIdByWindowId.removeValue(forKey: controller.windowId)
        defer {
            manager?.pushSpaceStateToChromium()
            // Snapshot the live layout so the next launch can route
            // session-restored windows back to their original Space.
            manager?.persistSlotsSnapshot()
        }
        if let window = controller.window {
            // Follow the user across macOS desktops. Each sibling NSWindow
            // is tied to whatever desktop it was last shown on; without
            // this, dragging the visible window to a new desktop and then
            // switching Phi Spaces yanks the user back to the sibling's
            // original desktop. `.moveToActiveSpace` makes the sibling
            // surface on the user's current desktop on each show instead.
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        if let frame = pendingFrameByWindowId.removeValue(forKey: controller.windowId),
           let window = controller.window {
            window.setFrame(frame, display: false)
        }
        // Apply sidebar shape queued by the spawn path so the new window
        // surfaces matching the previously visible Space's sidebar.
        let pendingWidth = pendingSidebarWidthByWindowId.removeValue(forKey: controller.windowId)
        let pendingCollapsed = pendingSidebarCollapsedByWindowId.removeValue(forKey: controller.windowId)
        if let pendingCollapsed {
            controller.mainSplitViewController.syncSidebar(
                width: (pendingWidth ?? 0) > 0 ? pendingWidth : nil,
                collapsed: pendingCollapsed
            )
        }
        // Update `visibleController` synchronously when this registration is
        // the result of `activate(spaceId)` swapping the slot to a Space whose
        // window didn't exist yet — `activate` set `activeSpaceId` before
        // spawning, so a spaceId match here means this new controller IS the
        // one the user is about to see. Without this, `visibleController`
        // stays pointing at the OLD controller until the new window's
        // `didBecomeKey` notification arrives on a later runloop turn, and
        // any space switch in that window leaks a stale frame: the next
        // `activate` reads `previous?.window?.isVisible == false` (because
        // the deferred `orderOut(previous)` already fired), skips inheriting
        // the frame, and the target window surfaces at its own old position.
        // The original `visibleController == nil` branch is preserved for
        // the very first registration in a slot.
        if visibleController == nil || spaceId == activeSpaceId {
            visibleController = controller
        }
        // A profile-change respawn left the replaced window on screen until
        // this replacement arrived — retire it now. Deferred one turn:
        // registration runs inside Chromium's synchronous window-created
        // callback, and closing a Browser re-entrantly from inside
        // BrowserList's OnBrowserAdded notification is not safe.
        if let replaced = pendingCloseOnReplacementBySpaceId.removeValue(forKey: spaceId),
           replaced !== controller {
            AppLogInfo("[SpaceWindowSlot] registerWindow(\(spaceId)): closing replaced window \(replaced.windowId)")
            DispatchQueue.main.async {
                replaced.window?.close()
            }
        }
        manager?.applyPersistedTheme(to: controller, spaceId: spaceId)
        guard let window = controller.window else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowDidBecomeKey(spaceId: spaceId)
        }
        keyObservationsByWindowId[controller.windowId] = token
    }

    /// Records that `spaceId`'s next window close is going to be the
    /// result of the user closing the last tab in this Space, not
    /// the result of closing the window itself. Called from any tab-
    /// close entry point (`CommandDispatcher` IDC_CLOSE_TAB, the tab-
    /// row X button via `Tab.close()`) right before dispatching the
    /// IDC_CLOSE_TAB command, when the active Space's tab count is
    /// about to drop to zero.
    func markTabDrivenClose(for spaceId: String) {
        pendingTabDrivenCloseDeadlines[spaceId] = Date().addingTimeInterval(Self.tabDrivenCloseTTL)
        // Capture the closing window's pixels now, while the WebContents
        // and the chrome are still on screen. The snapshot is consumed
        // by `unregisterWindow` so the post-close swap to a sibling
        // Space runs the same animation a user-clicked pip would.
        if let window = windowsBySpaceId[spaceId]?.window {
            pendingTabDrivenCloseSnapshots[spaceId] = snapshotWindowComposite(of: window)
        }
    }

    /// Drops the controller for `spaceId`. When the closed controller
    /// was the slot's `visibleController`, behavior splits on whether
    /// the close was tab-driven or window-driven:
    ///
    /// - Tab-driven (the user just closed the last tab in this Space)
    ///   AND another Space in the slot still has tabs: activate that
    ///   sibling. The user-perceived window stays alive showing the
    ///   sibling Space's content.
    /// - Otherwise (user closed the window itself, OR every other
    ///   Space is also empty): iterate every sibling Space and call
    ///   `NSWindow.close()` directly so the entire user-perceived
    ///   window goes away as a unit. If this leaves SpaceManager with
    ///   no slots at all, also `NSApp.terminate(nil)` — the user
    ///   asked for "close all spaces and exit".
    ///
    /// `NSWindow.close()` (not `performClose:`) is used for the cascade
    /// because the user has already decided to close the window; a
    /// sibling Space's delegate (e.g. an unload prompt) shouldn't be
    /// allowed to veto.
    func unregisterWindow(_ controller: MainBrowserWindowController, for spaceId: String) {
        // Identity check, not just a key lookup: `changeProfile` evicts a
        // window from the registry before closing it, and by the time the
        // asynchronous teardown reaches `windowWillClose` the Space's
        // replacement window may already be registered under the same
        // spaceId. A stale unregister must neither remove the replacement
        // nor run the visible-close side effects (sibling handoff/cascade).
        guard windowsBySpaceId[spaceId] === controller else { return }
        windowsBySpaceId.removeValue(forKey: spaceId)
        defer { manager?.pushSpaceStateToChromium() }
        // Drain the marker unconditionally so a stale entry can't poison
        // a later re-spawn of the same Space in this slot. Honor it only
        // if it hasn't expired (see `tabDrivenCloseTTL`).
        let deadline = pendingTabDrivenCloseDeadlines.removeValue(forKey: spaceId)
        let isTabDriven = deadline.map { Date() < $0 } ?? false
        // Drained in lockstep with the deadline. Used only when we hand
        // off to a sibling Space below; otherwise discarded.
        let leavingSnapshot = pendingTabDrivenCloseSnapshots.removeValue(forKey: spaceId)
        if let token = keyObservationsByWindowId.removeValue(forKey: controller.windowId) {
            NotificationCenter.default.removeObserver(token)
        }
        let wasVisible = (visibleController === controller)
        if wasVisible {
            let siblingWithTabs = isTabDriven ? firstSiblingWithTabs() : nil
            if let siblingWithTabs {
                // Tab-driven close with a viable sibling: hand off to
                // the sibling instead of tearing the slot down.
                // `visibleController` is left pointing at the closing
                // controller so `activate` captures its frame as the
                // inherited frame for the target before performing the
                // swap. The pre-close composite snapshot is threaded in
                // so the per-style animation can run even after the
                // closing window's GPU surface has been drained.
                AppLogInfo("[SpaceWindowSlot] tab-driven close of \(spaceId); switching to sibling \(siblingWithTabs)")
                activate(spaceId: siblingWithTabs, leavingSnapshotOverride: leavingSnapshot)
            } else {
                // Window-driven OR tab-driven-but-no-sibling: cascade
                // every remaining Space in the slot.
                visibleController = nil
                let siblings = Array(windowsBySpaceId.values)
                AppLogInfo("[SpaceWindowSlot] window-driven close of \(spaceId); cascading \(siblings.count) sibling(s)")
                for sibling in siblings {
                    sibling.window?.close()
                }
            }
        }
        if windowsBySpaceId.isEmpty {
            manager?.removeSlot(self)
            if let manager, manager.slots.isEmpty {
                manager.requestTerminateForLastSlotClose()
            }
        }
    }

    /// Removes the controller registered for `spaceId` from this slot
    /// WITHOUT any of `unregisterWindow`'s visible-close side effects
    /// (sibling handoff / cascade). Used by `SpaceManager.changeProfile`
    /// before closing the old-profile window: window teardown is
    /// asynchronous, and an un-evicted registry entry would make the
    /// respawn's `activate` swap back to the dying window instead of
    /// spawning on the new profile — whose late unregister would then hand
    /// the slot off to a sibling Space. Eviction makes the respawn a
    /// guaranteed spawn and the late unregister a no-op (identity check).
    @discardableResult
    func evictWindow(for spaceId: String, removeSlotIfEmpty: Bool = true) -> MainBrowserWindowController? {
        guard let controller = windowsBySpaceId.removeValue(forKey: spaceId) else { return nil }
        if let token = keyObservationsByWindowId.removeValue(forKey: controller.windowId) {
            NotificationCenter.default.removeObserver(token)
        }
        manager?.pushSpaceStateToChromium()
        manager?.persistSlotsSnapshot()
        if removeSlotIfEmpty, windowsBySpaceId.isEmpty {
            // A background slot whose only window was the evicted one is
            // done — mirror unregisterWindow's slot teardown, minus the
            // app-termination check (an eviction is never a user-driven
            // "close the last window" gesture). `respawnWindow` opts out:
            // its replacement registers into this slot momentarily.
            manager?.removeSlot(self)
        }
        return controller
    }

    /// Profile-change respawn: replaces this slot's window for `spaceId` in
    /// place, with no detour through another Space. The current controller
    /// is evicted (so `activate` takes the spawn path and the old window's
    /// deferred unregister no-ops on the identity check) but its window
    /// stays on screen — the user keeps seeing the Space while the
    /// replacement spawns. The old window is closed only once the
    /// replacement registers (`registerWindow` drains
    /// `pendingCloseOnReplacementBySpaceId`): a profile load can make the
    /// spawn complete asynchronously, and closing up front would leave the
    /// slot window-less if the spawn fails.
    func respawnWindow(forSpaceId spaceId: String) {
        guard activeSpaceId == spaceId, let old = windowsBySpaceId[spaceId] else {
            // The slot moved on (user switched Spaces in the gap) or the
            // window is already gone — just retire any leftover window;
            // the queued tab replay runs on the next manual activation.
            AppLogInfo("[SpaceWindowSlot] respawnWindow(\(spaceId)): fallback — active=\(activeSpaceId ?? "nil"), window \(windowsBySpaceId[spaceId] == nil ? "absent" : "present")")
            if let leftover = evictWindow(for: spaceId) {
                leftover.window?.close()
            }
            return
        }
        AppLogInfo("[SpaceWindowSlot] respawnWindow(\(spaceId)): replacing window \(old.windowId) in place")
        evictWindow(for: spaceId, removeSlotIfEmpty: false)
        pendingCloseOnReplacementBySpaceId[spaceId] = old
        activate(spaceId: spaceId)
    }

    /// First Space in STRIP order (`manager.spaces`) that has a live
    /// controller with tabs in this slot. Deterministic, unlike iterating
    /// `windowsBySpaceId` directly — dictionary order made the tab-driven
    /// hand-off target vary between identical closes. Falls back to any
    /// tabbed sibling for a controller bound to a Space mid-deletion (no
    /// strip row anymore); an arbitrary hand-off still beats cascading the
    /// slot shut.
    private func firstSiblingWithTabs() -> String? {
        if let manager {
            for space in manager.spaces {
                if let candidate = windowsBySpaceId[space.spaceId],
                   !candidate.browserState.tabs.isEmpty {
                    return space.spaceId
                }
            }
        }
        return windowsBySpaceId.first(where: { !$0.value.browserState.tabs.isEmpty })?.key
    }

    /// Consumes a pending spawn intent for `windowId`. Returns nil when this
    /// windowId wasn't spawned by this slot.
    func consumePendingSpawnSpaceId(forWindowId windowId: Int) -> String? {
        pendingSpawnSpaceIdByWindowId.removeValue(forKey: windowId)
    }

    /// Called by `SpaceManager.claimPendingSpawn` when the windowId-keyed
    /// lookup missed but `currentSpawn` matches this slot. Backfills the
    /// per-windowId maps so the subsequent `registerWindow` (which fires
    /// inside the synchronous Chromium callback) picks up the inherited
    /// frame and sidebar shape just as it would on the async path.
    fileprivate func absorbCurrentSpawn(ctx: SpaceManager.SpawnContext, windowId: Int) {
        pendingSpawnSpaceIdByWindowId[windowId] = ctx.spaceId
        if let frame = ctx.inheritedFrame {
            pendingFrameByWindowId[windowId] = frame
        }
        if let collapsed = ctx.inheritedSidebarCollapsed {
            pendingSidebarWidthByWindowId[windowId] = ctx.inheritedSidebarWidth
            pendingSidebarCollapsedByWindowId[windowId] = collapsed
        }
    }

    /// Returns the controller this slot has registered for `spaceId`, or
    /// nil. Used by theme application across slots.
    func windowController(for spaceId: String) -> MainBrowserWindowController? {
        windowsBySpaceId[spaceId]
    }

    /// Does this slot host the given Chromium windowId?
    func contains(windowId: Int) -> Bool {
        windowsBySpaceId.values.contains { $0.windowId == windowId }
    }

    /// Read-only snapshot of `windowId → spaceId` for every controller
    /// this slot currently owns. Used by `SpaceManager.persistSlotsSnapshot`
    /// to write the cross-launch restore record.
    fileprivate func snapshotWindowMap() -> [Int: String] {
        var map: [Int: String] = [:]
        for (spaceId, controller) in windowsBySpaceId {
            map[controller.windowId] = spaceId
        }
        return map
    }

    /// Used by `SpaceManager.handleSpacesUpdate` when a slot's active Space
    /// has been deleted and no fallback Space exists.
    fileprivate func clearActiveSpace() {
        activeSpaceId = nil
    }

    private func handleWindowDidBecomeKey(spaceId: String) {
        guard let controller = windowsBySpaceId[spaceId] else { return }
        let previousSpaceId = activeSpaceId
        let previous = visibleController

        // External (non-`activate`) trigger — Chromium routing a navigation
        // into a sibling Space's window via the URL rule throttle made that
        // window key. `activate` already runs its own `performSwap` and guards
        // re-entry with `isPerformingActivate`, so this only fires when the key
        // change wasn't initiated from our side.
        let isExternalSwitch = !isPerformingActivate
            && activeSpaceId != spaceId
            && previous != nil
            && previous !== controller

        // Capture the leaving Space's sidebar band + Space colors BEFORE
        // `activeSpaceId` flips below, exactly as `activate` does for a clicked
        // switch: the SpacesStrip name and tint gradient bind to the shared
        // slot, so capturing after the flip would bake in the TARGET Space (no
        // color ramp, and the band would already carry the new name). Without
        // the band the vertical push-in bails to an instant present, so a
        // URL-rule switch would skip the animation a clicked switch shows.
        let isVerticalSwitch = isExternalSwitch
            && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let verticalLeavingBand: NSImage? = isVerticalSwitch
            ? previous?.mainSplitViewController.sidebarViewController.snapshotSpaceSwitchBand()
            : nil
        let sourceColorHex = isExternalSwitch ? manager?.spaces.first(where: { $0.spaceId == previousSpaceId })?.colorHex : nil
        let targetColorHex = isExternalSwitch ? manager?.spaces.first(where: { $0.spaceId == spaceId })?.colorHex : nil

        visibleController = controller
        // Persist on every key event, not only when this slot's active
        // Space flips: the persisted value seeds the Space for windows
        // that arrive with no spawn or restore claim (cold-launch first
        // window, Cmd+N), while Chromium independently seeds those same
        // windows' profile from its own last-active tracking. Persisting
        // only explicit switches lets the two diverge across a quit —
        // focusing another profile's window never re-persisted — and the
        // next launch pairs the first window with another profile's Space.
        manager?.persistActiveSpaceId(spaceId)
        if activeSpaceId != spaceId {
            activeSpaceId = spaceId
            manager?.persistSlotsSnapshot()
            // The previous window is still alive in the slot for URL-rule
            // routing (Chromium doesn't close it), so the per-style snapshot
            // paths produce real pixels.
            if isExternalSwitch, let previous, let previousSpaceId {
                let direction = swapDirection(
                    previousSpaceId: previousSpaceId,
                    targetSpaceId: spaceId
                )
                // Chromium already surfaced the target window, so unlike a
                // clicked switch the LEAVING window is not front — the vertical
                // push-in animates on the leaving window and reveals the target
                // only on completion, so it would play hidden behind the
                // target (confirmed: prevWindowFront=false). Instead animate the
                // band swap directly on the already-front TARGET sidebar.
                // Horizontal layout animates inside the target window already,
                // so it keeps the normal path.
                if isVerticalSwitch, let band = verticalLeavingBand {
                    performExternalVerticalSlide(
                        target: controller,
                        leavingBand: band,
                        direction: direction,
                        sourceColorHex: sourceColorHex,
                        targetColorHex: targetColorHex
                    )
                } else {
                    performSwap(
                        from: previous,
                        to: controller,
                        direction: direction,
                        verticalLeavingBand: verticalLeavingBand,
                        sourceColorHex: sourceColorHex,
                        targetColorHex: targetColorHex
                    )
                }
            }
        }
        manager?.notifySlotBecameKey(self)
    }

    /// Swap the move/resize observers onto `controller`'s window so any drag
    /// or resize of the visible window is mirrored onto every sibling in this
    /// slot immediately — siblings stay pre-aligned to the user's current
    /// position/size, so any subsequent swap surfaces them at the right place
    /// regardless of which code path runs (swap or spawn).
    ///
    /// Observing only the visible window is essential: siblings receive the
    /// propagated `setFrame` and fire their own didMove/didResize, but no
    /// observer is hooked to them, so there is no echo. Hooking every window
    /// would create an A→B→A feedback loop.
    private func observeFrameChanges(on controller: MainBrowserWindowController?) {
        for token in visibleFrameObservers {
            NotificationCenter.default.removeObserver(token)
        }
        visibleFrameObservers.removeAll()
        guard let window = controller?.window else { return }
        let propagate: (Notification) -> Void = { [weak self, weak window] _ in
            guard let self,
                  !self.isAnimatingWindowSlide,
                  let window,
                  let visible = self.visibleController,
                  visible.window === window else { return }
            let frame = window.frame
            // The visible window is the slot's authoritative position now;
            // record it so a later spawn/switch inherits the user's drag even
            // if the source window is gone by then.
            self.lastKnownFrame = frame
            for (_, sibling) in self.windowsBySpaceId where sibling !== visible {
                sibling.window?.setFrame(frame, display: false)
            }
        }
        let move = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main,
            using: propagate
        )
        let resize = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main,
            using: propagate
        )
        visibleFrameObservers = [move, resize]
    }

    /// The frame a window surfaced in this slot should adopt so every Space
    /// reads as one window whose contents change. Prefers the live `source`
    /// window's current frame — the freshest signal — and refreshes
    /// `lastKnownFrame` from it; falls back to the cache when `source` is gone
    /// or was never positioned (an async cross-profile spawn whose source
    /// window closed during the profile load, a tab-driven hand-off from a
    /// window mid-close). Returns nil only before the slot has ever had a
    /// positioned window.
    private func resolveInheritedFrame(from source: MainBrowserWindowController?) -> NSRect? {
        if let frame = source?.window?.frame, !frame.isEmpty {
            lastKnownFrame = frame
        }
        return lastKnownFrame
    }

    /// Tears down every NotificationCenter registration this slot owns —
    /// the per-window `didBecomeKey` observations and the visible-window
    /// frame observers. The blocks capture the slot weakly, but without
    /// explicit removal NotificationCenter keeps the registrations (and
    /// blocks) alive until app exit, firing as no-ops against a slot the
    /// manager no longer tracks. Called by `SpaceManager.unbind` when the
    /// account goes away while windows may still be open, and from `deinit`.
    fileprivate func invalidate() {
        for token in keyObservationsByWindowId.values {
            NotificationCenter.default.removeObserver(token)
        }
        keyObservationsByWindowId.removeAll()
        for token in visibleFrameObservers {
            NotificationCenter.default.removeObserver(token)
        }
        visibleFrameObservers.removeAll()
    }

    deinit {
        // Weak-var auto-nil-out of `visibleController` does NOT trigger its
        // didSet, so observers must be torn down here too — without this,
        // NotificationCenter holds stale entries until app exit.
        invalidate()
    }
}

/// Transient overlay that hosts the two sidebar snapshots while a Space
/// swap animates. Clipped to its bounds so the off-screen halves of the
/// snapshots don't bleed onto the web content during the slide.
private final class SidebarSwapOverlay: NSView {
    private let leavingImageView = NSImageView()
    private let enteringImageView = NSImageView()
    private let direction: SpaceWindowSlot.SwapDirection
    private var didCancel = false

    init(
        frame: NSRect,
        leavingImage: NSImage,
        enteringImage: NSImage,
        direction: SpaceWindowSlot.SwapDirection
    ) {
        self.direction = direction
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = true
        if #available(macOS 14.0, *) {
            clipsToBounds = true
        }

        leavingImageView.image = leavingImage
        leavingImageView.imageScaling = .scaleAxesIndependently
        leavingImageView.imageAlignment = .alignTopLeft
        leavingImageView.frame = bounds
        leavingImageView.autoresizingMask = []
        addSubview(leavingImageView)

        enteringImageView.image = enteringImage
        enteringImageView.imageScaling = .scaleAxesIndependently
        enteringImageView.imageAlignment = .alignTopLeft
        let enterDx: CGFloat = direction == .forward ? bounds.width : -bounds.width
        enteringImageView.frame = bounds.offsetBy(dx: enterDx, dy: 0)
        enteringImageView.autoresizingMask = []
        addSubview(enteringImageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func runAnimation(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !didCancel else {
            completion()
            return
        }
        let leaveDx: CGFloat = direction == .forward ? -bounds.width : bounds.width
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            leavingImageView.animator().frame = bounds.offsetBy(dx: leaveDx, dy: 0)
            enteringImageView.animator().frame = bounds
        }, completionHandler: completion)
    }

    /// Aborts an in-flight animation by snapping both image views to their
    /// resting positions and removing the overlay. Called when a newer swap
    /// supersedes this one.
    func cancel() {
        didCancel = true
        leavingImageView.layer?.removeAllAnimations()
        enteringImageView.layer?.removeAllAnimations()
        removeFromSuperview()
    }
}

