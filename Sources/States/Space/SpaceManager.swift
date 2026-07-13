// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation

private enum NativeWindowTabBarSuppressor {
    private static let slotTabbingIdentifierPrefix = "phi.space.slot."

    static func installIfNeeded() {
        _ = install
    }

    private static let install: Void = {
        if let tabBarClass = NSClassFromString("NSTabBar") {
            swizzleInstanceMethod(
                on: tabBarClass,
                originalSelector: #selector(NSView.viewWillMove(toWindow:)),
                replacementProviderClass: NSView.self,
                replacementSelector: #selector(NSView.phi_spaceTabBar_viewWillMove(toWindow:))
            )
            swizzleInstanceMethod(
                on: tabBarClass,
                originalSelector: #selector(NSView.viewDidMoveToWindow),
                replacementProviderClass: NSView.self,
                replacementSelector: #selector(NSView.phi_spaceTabBar_viewDidMoveToWindow)
            )
            swizzleInstanceMethod(
                on: tabBarClass,
                originalSelector: #selector(NSView.layout),
                replacementProviderClass: NSView.self,
                replacementSelector: #selector(NSView.phi_spaceTabBar_layout)
            )
            swizzleInstanceMethod(
                on: tabBarClass,
                originalSelector: #selector(setter: NSView.isHidden),
                replacementProviderClass: NSView.self,
                replacementSelector: #selector(NSView.phi_spaceTabBar_setHidden(_:))
            )
        }

        swizzleInstanceMethod(
            on: NSWindow.self,
            originalSelector: NSSelectorFromString("_setTabBarAccessoryViewController:"),
            replacementProviderClass: NSWindow.self,
            replacementSelector: #selector(NSWindow.phi_spaceTabBar_setTabBarAccessoryViewController(_:))
        )
    }()

    private static func swizzleInstanceMethod(
        on targetClass: AnyClass,
        originalSelector: Selector,
        replacementProviderClass: AnyClass,
        replacementSelector: Selector
    ) {
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let replacementMethod = class_getInstanceMethod(replacementProviderClass, replacementSelector) else {
            return
        }

        _ = class_addMethod(
            targetClass,
            originalSelector,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        )
        guard class_addMethod(
            targetClass,
            replacementSelector,
            method_getImplementation(replacementMethod),
            method_getTypeEncoding(replacementMethod)
        ),
              let targetOriginalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let targetReplacementMethod = class_getInstanceMethod(targetClass, replacementSelector) else {
            return
        }

        method_exchangeImplementations(targetOriginalMethod, targetReplacementMethod)
    }

    static func isManagedSlotWindow(_ window: NSWindow?) -> Bool {
        window?.tabbingIdentifier.hasPrefix(slotTabbingIdentifierPrefix) == true
    }

    static func hideIfNativeTabBar(_ view: NSView, in window: NSWindow? = nil) {
        guard isNativeTabBar(view),
              isManagedSlotWindow(window ?? view.window) else {
            return
        }

        if !view.isHidden {
            view.isHidden = true
        }
        view.alphaValue = 0
        view.wantsLayer = true
        view.layer?.opacity = 0
    }

    static func hideNativeTabBarDescendants(of view: NSView, in window: NSWindow? = nil) {
        hideIfNativeTabBar(view, in: window)
        for subview in view.subviews {
            hideNativeTabBarDescendants(of: subview, in: window)
        }
    }

    static func containsNativeTabBar(in view: NSView) -> Bool {
        if isNativeTabBar(view) {
            return true
        }

        for subview in view.subviews {
            if containsNativeTabBar(in: subview) {
                return true
            }
        }

        return false
    }

    private static func isNativeTabBar(_ view: NSView) -> Bool {
        String(describing: type(of: view)) == "NSTabBar"
    }
}

private extension NSWindow {
    @objc func phi_spaceTabBar_setTabBarAccessoryViewController(
        _ controller: NSTitlebarAccessoryViewController?
    ) {
        guard NativeWindowTabBarSuppressor.isManagedSlotWindow(self),
              let controller,
              NativeWindowTabBarSuppressor.containsNativeTabBar(in: controller.view) else {
            phi_spaceTabBar_setTabBarAccessoryViewController(controller)
            return
        }

        NativeWindowTabBarSuppressor.hideNativeTabBarDescendants(of: controller.view, in: self)
        phi_spaceTabBar_setTabBarAccessoryViewController(nil)
    }
}

private extension NSView {
    @objc func phi_spaceTabBar_viewWillMove(toWindow newWindow: NSWindow?) {
        NativeWindowTabBarSuppressor.hideIfNativeTabBar(self, in: newWindow)
        phi_spaceTabBar_viewWillMove(toWindow: newWindow)
        NativeWindowTabBarSuppressor.hideIfNativeTabBar(self, in: newWindow)
    }

    @objc func phi_spaceTabBar_viewDidMoveToWindow() {
        phi_spaceTabBar_viewDidMoveToWindow()
        NativeWindowTabBarSuppressor.hideIfNativeTabBar(self)
    }

    @objc func phi_spaceTabBar_layout() {
        NativeWindowTabBarSuppressor.hideIfNativeTabBar(self)
        phi_spaceTabBar_layout()
        NativeWindowTabBarSuppressor.hideIfNativeTabBar(self)
    }

    @objc func phi_spaceTabBar_setHidden(_ hidden: Bool) {
        if NativeWindowTabBarSuppressor.isManagedSlotWindow(window) {
            phi_spaceTabBar_setHidden(true)
            NativeWindowTabBarSuppressor.hideIfNativeTabBar(self)
            return
        }

        phi_spaceTabBar_setHidden(hidden)
    }
}

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

    /// spaceId prefix shared by every Incognito Space. Their ids are minted
    /// at creation (`createIncognitoSpace`) and never persisted — each Space
    /// is a detached `SpaceModel` appended in `handleSpacesUpdate`, so store
    /// mutations keyed by such an id are no-ops. The prefix also matches the
    /// pre-multi-Space sentinel id ("space.incognito"), keeping legacy
    /// persisted references (URL rules, restore snapshots) classified as
    /// incognito.
    static let incognitoSpaceIdPrefix = "space.incognito"

    /// Whether `spaceId` names an Incognito Space (live or already gone).
    static func isIncognitoSpaceId(_ spaceId: String) -> Bool {
        spaceId.hasPrefix(incognitoSpaceIdPrefix)
    }

    /// The synthetic wire profileId Chromium reports for Incognito Space
    /// windows (see PhiChromiumBridgeHeader's ChromiumBrowserTypeIncognitoSpace
    /// note — the Spaces' shared OTR profile has no on-disk identity of its
    /// own). Binding every Incognito Space to it keeps
    /// `spaceId(boundTo:preferring:)` a pass-through on the spawn path.
    static let incognitoProfileId = "PhiIncognitoSpace"
    /// Default icon of an Incognito Space (the ninja emoji, in the IconPicker
    /// emoji storage scheme). The user can change it like any Space's icon;
    /// the choice lives on the runtime descriptor and dies with the Space.
    static let incognitoSpaceDefaultIcon = "emoji:1F977"

    /// Runtime record of one live Incognito Space. All descriptors share the
    /// single Chromium OTR profile (`incognitoProfileId`); the Space itself
    /// exists only while this record does — nothing about it is persisted.
    private struct IncognitoSpaceDescriptor {
        let spaceId: String
        /// 1-based display number, the lowest free at creation time. Stable
        /// for the Space's lifetime so siblings don't get renamed when
        /// another Incognito Space closes.
        let ordinal: Int
        var iconName: String
        /// Position in the strip captured by `reorder`; nil = after every
        /// other Space, in ordinal order.
        var sortIndex: Int?
    }

    /// Live Incognito Spaces, in creation order. Appended by
    /// `createIncognitoSpace`, removed by `closeIncognitoSpace` and
    /// `reapIncognitoSpaceIfWindowless` (a window-driven teardown that took
    /// the Space's last window with it).
    private var incognitoSpaces: [IncognitoSpaceDescriptor] = []

    /// Builds the detached `SpaceModel` for one live Incognito Space,
    /// backed by the shared Chromium off-the-record profile (in-memory only;
    /// destroyed when the last Incognito Space window closes or the app
    /// quits). Detached from SwiftData by construction (never inserted into
    /// a model context), so nothing about it persists through the store.
    /// Rebuilt on every spaces emission. A single Incognito Space is plainly
    /// "Incognito"; siblings are told apart by their ordinal ("Incognito 1",
    /// "Incognito 2", …).
    private func makeIncognitoSpace(descriptor: IncognitoSpaceDescriptor, sortOrder: Int) -> SpaceModel {
        let name: String
        if incognitoSpaces.count > 1 {
            name = String(
                format: NSLocalizedString("Incognito %d", comment: "Incognito Space name when several are open; %d is its number"),
                descriptor.ordinal
            )
        } else {
            name = NSLocalizedString("Incognito", comment: "Built-in Incognito Space name")
        }
        return SpaceModel(
            spaceId: descriptor.spaceId,
            profileId: Self.incognitoProfileId,
            name: name,
            colorHex: "#5F6368",
            iconName: descriptor.iconName,
            sortOrder: sortOrder
        )
    }

    /// Stable target id for URL rules that route into Incognito. Rules
    /// persist across launches while Incognito Spaces don't, so rules carry
    /// this generic id (the bare prefix — also the pre-multi-Space sentinel,
    /// which revives legacy incognito rules) instead of a runtime Space id;
    /// `routeAskedURL` resolves it to a live Incognito Space, created on
    /// demand.
    static let incognitoRuleTargetId = incognitoSpaceIdPrefix

    /// Whether a persisted URL rule with this target should route: user-Space
    /// targets and the generic Incognito target do; any other id under the
    /// incognito prefix is a stale runtime Space id and stays inert.
    static func isRoutableRuleTarget(_ spaceId: String) -> Bool {
        !isIncognitoSpaceId(spaceId) || spaceId == incognitoRuleTargetId
    }

    /// Detached stand-in for the generic Incognito rule target, shown as ONE
    /// "Incognito" entry — regardless of how many Incognito Spaces are live —
    /// by the rules editor's target picker and the ask-rule Space chooser.
    /// Never inserted into a model context and never part of `spaces`.
    func incognitoRuleTargetSpace() -> SpaceModel {
        SpaceModel(
            spaceId: Self.incognitoRuleTargetId,
            profileId: Self.incognitoProfileId,
            name: NSLocalizedString("Incognito", comment: "Built-in Incognito Space name"),
            colorHex: "#5F6368",
            iconName: Self.incognitoSpaceDefaultIcon,
            sortOrder: spaces.count
        )
    }

    @Published private(set) var spaces: [SpaceModel] = []

    /// Whether an AUTOMATIC switch (deletion retreat, slot reconciliation,
    /// new-slot seeding, tab-driven hand-off) may land on this Space. Agent
    /// Spaces are ephemeral task workspaces and an Incognito Space is a
    /// deliberate destination — both are surfaced only by an explicit user
    /// switch, never picked as a fallback.
    fileprivate func isAutomaticSwitchTarget(_ space: SpaceModel) -> Bool {
        !Self.isIncognitoSpaceId(space.spaceId) && !space.isAgentSpace
    }

    /// Raw store emission backing `spaces`, without the synthetic Incognito
    /// Spaces. Kept so `refreshIncognitoSpacePresence()` can recompute when
    /// an Incognito Space is created or closed without waiting for the next
    /// SwiftData write.
    private var lastStoreSpaces: [SpaceModel] = []

    /// Live slots, one per user-perceived browser window. A slot is created
    /// when a new Chromium window can't be matched to an existing slot's
    /// pending spawn intent, and destroyed when its last controller closes.
    private(set) var slots: [SpaceWindowSlot] = []

    /// True once any slot has registered a Chromium window this session.
    /// Distinguishes "the user closed the last window mid-session" — where a
    /// Dock-click reopen must respawn the persisted Space
    /// (`reopenOnPersistedSpaceIfWindowless`) — from a launch that hasn't
    /// surfaced a window yet (e.g. a hidden login-item start), where the
    /// first Dock click must stay with Chromium's reopen so its session
    /// restore can run (`PhiAttemptSessionRestore`).
    fileprivate(set) var hasEverHostedSlotWindow = false

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
        /// True when the slot's visible window was in native macOS fullscreen
        /// at snapshot time. Restored windows always come back as normal
        /// windows (Chromium forces kNormal so macOS doesn't spawn a separate
        /// fullscreen Space per restored window); when this is set the live
        /// slot re-enters fullscreen on its active window once restore settles,
        /// so the slot reopens fullscreen as ONE Space instead of orphaning
        /// blank Spaces. See `SpaceWindowSlot.applyPendingRestoreFullScreen`.
        let wasFullScreen: Bool
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
    /// Restored windows do not always arrive with their previous-session
    /// windowId: Chromium's multi-profile startup opens one *fresh* window per
    /// last-open profile (`restoredFromWindowId == 0`), which the windowId key
    /// below cannot match. For a short grace period after a snapshot loads,
    /// `claimRestoredWindow` may reattach such a window to its remembered macOS
    /// window (slot) by matching the window's profile instead — keeping Spaces
    /// that shared one macOS window grouped as native tabs. The deadline stops
    /// a genuinely new window opened later in the session (Cmd+N) from being
    /// absorbed into a stale, never-claimed snapshot slot.
    private var restoreReattachDeadline: Date?
    private static let restoreReattachGracePeriod: TimeInterval = 60

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
        let fallback = persistedActiveSpaceId
            ?? (spaces.first(where: isAutomaticSwitchTarget) ?? spaces.first)?.spaceId
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
        // Drop any restore-snapshot reattach binding pointing at this slot.
        // `restoredSlotsByIndex` holds a STRONG reference, consulted only during
        // the launch grace period; without this a slot the user closes
        // mid-session would be retained here (and never deinit) until the next
        // account bind clears the map.
        restoredSlotsByIndex = restoredSlotsByIndex.filter { $0.value !== slot }
    }

    /// Re-asserts every slot's one-visible-window invariant after an app
    /// reopen (Dock-icon click). Chromium's reopen handler surfaces every
    /// browser window it owns — including a slot's hidden sibling Space
    /// windows — so all Spaces in a slot momentarily appear on screen. This is
    /// the same symptom the cold-launch session-restore burst produces, so the
    /// fix reuses each slot's coalesced restore reconcile to drop the siblings
    /// back behind the active Space. Idempotent: a settled slot does no work.
    func reconcileSlotVisibilityAfterReopen() {
        for slot in slots {
            slot.scheduleRestoreVisibilityReconcile()
        }
    }

    /// Handles a Dock-icon reopen when no browser window survives (the user
    /// closed the last window and the app kept running). Spawns the persisted
    /// last-active Space through the normal spawn path — which requests the
    /// Space's OWN profile via `createBrowser(withWindowType:profileId:)` —
    /// and returns true. Returns false when the reopen should stay with
    /// Chromium's handler: a browser window still exists (Chromium focuses
    /// it), or no slot window has been hosted yet this session (Chromium's
    /// session restore owns the hidden-login-item first click).
    ///
    /// Why Chromium must not create this window itself: its reopen seeds the
    /// window from Chromium's last-used-profile pref
    /// (`GetStartupProfilePathMac`), a value the window-close cascade
    /// pollutes — closing the visible window promotes the slot's hidden
    /// sibling Space windows to key one by one, and each promotion rewrites
    /// the pref (`ProfileManager::OnBrowserActivated`; its
    /// `closing_all_browsers_` suppression covers only full quit, not the
    /// per-window cascade). The coordinator's profile-consistency rule
    /// (`spaceId(boundTo:preferring:)`) then re-resolves the persisted Space
    /// to one bound to that polluted profile, so the reopen lands on the
    /// wrong (typically default) Space instead of the one the user closed.
    func reopenOnPersistedSpaceIfWindowless() -> Bool {
        guard hasEverHostedSlotWindow, slots.isEmpty else { return false }
        // Non-slot windows don't count as "windowless": a standalone
        // Incognito window is focused by Chromium's own reopen, and shadow
        // windows are invisible background hosts either way.
        guard !MainBrowserWindowControllersManager.shared.getAllWindows()
            .contains(where: { $0.browserType != .shadow }) else { return false }
        // Same resolution shape as `handleSpacesUpdate`'s fallback: the
        // persisted id when it names a live, automatically-switchable Space,
        // else the first such Space. `activate` refuses unknown spaceIds, so
        // an unvalidated stale id would silently spawn nothing.
        let resolved: String? = {
            if let persisted = persistedActiveSpaceId,
               let model = spaces.first(where: { $0.spaceId == persisted }),
               isAutomaticSwitchTarget(model) {
                return persisted
            }
            return (spaces.first(where: isAutomaticSwitchTarget) ?? spaces.first)?.spaceId
        }()
        guard let spaceId = resolved else { return false }
        AppLogInfo("[SpaceManager] windowless reopen — spawning persisted Space \(spaceId)")
        createSlot(initialSpaceId: spaceId).activate(spaceId: spaceId)
        return true
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
            // Stash the sidebar metadata against this windowId so
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
    /// the persisted snapshot by accident.
    ///
    /// When the previous-session windowId is present it is the exact key.
    /// When it is absent (`0`) — Chromium's multi-profile startup opens one
    /// *fresh* window per last-open profile, so those restored windows carry
    /// no previous id — the window is still reattached to its remembered macOS
    /// window (slot) by matching `profileId` against the saved snapshot, for a
    /// short grace period after launch (`restoreReattachDeadline`). This is
    /// what keeps Spaces that lived in one macOS window grouped as native tabs
    /// instead of each spawning a separate window. Outside the grace period a
    /// zero id never claims, so Cmd+N and other later Chromium-initiated
    /// windows can't be misclaimed by stale snapshot entries.
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
    func claimRestoredWindow(forRestoredFromWindowId restoredFromWindowId: Int,
                             profileId: String) -> (slot: SpaceWindowSlot, spaceId: String)? {
        // Primary: exact previous-session windowId match.
        if restoredFromWindowId != 0,
           let index = restoreIndexByWindowId[restoredFromWindowId],
           index < restoreEntries.count,
           let spaceId = restoreEntries[index].windowMap[restoredFromWindowId] {
            restoreIndexByWindowId.removeValue(forKey: restoredFromWindowId)
            return (slotForRestoreIndex(index, fallbackSpaceId: spaceId), spaceId)
        }
        // Fallback: ONLY for a window with no usable previous-session id
        // (`restoredFromWindowId == 0` — Chromium's multi-profile startup opens
        // one fresh window per last-open profile). Within the launch grace
        // period, reattach by profile — claim the first not-yet-restored
        // snapshot window, in saved-slot order, whose Space is bound to
        // `profileId`.
        //
        // A NON-zero id that misses the primary lookup is a window genuinely not
        // in the snapshot (e.g. opened while the live count was below the
        // session peak, so the monotonic persist guard never recorded it). It
        // must NOT be reattached by profile to some stale closed slot — that
        // would surface it as a closed Space (and force fullscreen). Returning
        // nil lets the coordinator mint a fresh slot on the resolved Space.
        guard restoredFromWindowId == 0,
              !profileId.isEmpty,
              let deadline = restoreReattachDeadline,
              Date() < deadline else { return nil }
        for index in restoreEntries.indices {
            for windowId in restoreEntries[index].windowMap.keys.sorted()
                where restoreIndexByWindowId[windowId] == index {
                guard let spaceId = restoreEntries[index].windowMap[windowId],
                      boundProfileId(forSpaceId: spaceId) == profileId else { continue }
                restoreIndexByWindowId.removeValue(forKey: windowId)
                return (slotForRestoreIndex(index, fallbackSpaceId: spaceId), spaceId)
            }
        }
        return nil
    }

    /// Resolves (and reuses for later siblings) the live slot for a saved
    /// snapshot entry, initialized to the originally-visible Space so the
    /// slot's `registerWindow` picks the right controller as visible when that
    /// Space's window arrives.
    private func slotForRestoreIndex(_ index: Int, fallbackSpaceId: String) -> SpaceWindowSlot {
        if let existing = restoredSlotsByIndex[index] {
            return existing
        }
        let initial = restoreEntries[index].activeSpaceId ?? fallbackSpaceId
        let slot = createSlot(initialSpaceId: initial)
        if restoreEntries[index].wasFullScreen {
            slot.markPendingRestoreFullScreen()
        }
        restoredSlotsByIndex[index] = slot
        return slot
    }

    /// The profileId a Space is bound to, or nil if unknown. Reads the live
    /// `spaces` cache, falling back to a direct main-context fetch on the
    /// cold-launch path where the async publisher hasn't delivered yet (same
    /// assumption as `spaceId(boundTo:preferring:)`).
    private func boundProfileId(forSpaceId spaceId: String) -> String? {
        if let cached = spaces.first(where: { $0.spaceId == spaceId })?.profileId {
            return cached
        }
        guard let account = boundAccount else { return nil }
        return MainActor.assumeIsolated {
            account.localStorage.getAllSpaces().first(where: { $0.spaceId == spaceId })?.profileId
        }
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

    /// Set once app termination begins (see `markTerminating`). Quit tears the
    /// slots down window-by-window, and every teardown step that reaches
    /// `persistSlotsSnapshot` would otherwise rewrite the snapshot with the
    /// dismantled (eventually empty) layout — wiping the healthy grouping the
    /// next launch needs to reattach restored windows. Freeze persistence here.
    private var isTerminating = false

    /// Called when quit begins, from `AppController`'s handler for
    /// `PhiWillTryToTerminateApplicationNotification` — posted by
    /// phi_app_controller_mac.mm's -tryToTerminateApplication: BEFORE
    /// chrome::CloseAllBrowsers(), the only quit signal that fires ahead of the
    /// window teardown (the AppKit applicationWillTerminate hook runs after it).
    /// Once set, `persistSlotsSnapshot` no-ops, freezing the snapshot at the last
    /// healthy layout for the rest of the process's life.
    func markTerminating() {
        isTerminating = true
    }

    /// Writes the current slot/window/Space layout to
    /// `AccountUserDefaults.slotsRestoreSnapshot`. Called from
    /// `SpaceWindowSlot.registerWindow` (and a few live-state mutations) so the
    /// persisted snapshot reflects the most recent healthy layout — sufficient
    /// to reattach Chromium-restored windows next launch. Frozen during
    /// termination (`isTerminating`, set before the teardown cascade) and never
    /// overwrites a non-empty snapshot with an empty one, so quit teardown can't
    /// drain it before the next launch reads it.
    fileprivate func persistSlotsSnapshot() {
        guard !isTerminating else { return }
        guard let userDefaults = boundAccount?.userDefaults else { return }
        var dicts: [[String: Any]] = []
        for slot in slots {
            // Incognito Spaces are excluded from the snapshot wholesale: their
            // sessions intentionally die with their windows, so restoring one
            // would surface an empty Space (and its runtime-only spaceId would
            // point restore at a Space that no longer exists by then).
            let windowMap = slot.snapshotWindowMap()
                .filter { !SpaceManager.isIncognitoSpaceId($0.value) }
            guard !windowMap.isEmpty else { continue }
            var dict: [String: Any] = [:]
            // Plist keys must be strings; convert the windowId map.
            dict["windowMap"] = Dictionary(
                uniqueKeysWithValues: windowMap.map { (String($0.key), $0.value) }
            )
            if let active = slot.activeSpaceId {
                // Ephemeral Spaces are rewritten to the default Space: an
                // Incognito Space's session dies with its windows, and an
                // agent Space is orphan-swept at the next launch — restoring
                // a slot ONTO either would surface a Space that no longer
                // exists (or is about to be deleted).
                let isEphemeral = SpaceManager.isIncognitoSpaceId(active)
                    || spaces.first(where: { $0.spaceId == active })?.isAgentSpace == true
                dict["activeSpaceId"] = isEphemeral ? LocalStore.defaultSpaceId : active
            }
            // Only written when set, so a normal slot's plist entry stays small.
            if slot.snapshotIsFullScreen() {
                dict["isFullScreen"] = true
            }
            dicts.append(dict)
        }
        // Backstop: never overwrite a saved snapshot with an empty one. A
        // transient "no live slots" moment (teardown, or all windows closed
        // while the app stays alive) must not erase the layout the next launch
        // restores into.
        guard !dicts.isEmpty else { return }
        userDefaults.set(dicts, forKey: AccountUserDefaults.DefaultsKey.slotsRestoreSnapshot.rawValue)
    }

    private func loadRestoreSnapshot() {
        restoreEntries.removeAll()
        restoreIndexByWindowId.removeAll()
        restoredSlotsByIndex.removeAll()
        restoreReattachDeadline = nil
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
                windowMap: windowMap,
                wasFullScreen: (dict["isFullScreen"] as? Bool) ?? false
            )
            let index = restoreEntries.count
            restoreEntries.append(entry)
            for windowId in windowMap.keys {
                restoreIndexByWindowId[windowId] = index
            }
        }
        // Arm the profile-match fallback only when there is something to
        // reattach, and only briefly — long enough for the cold-launch restore
        // burst to land, short enough that later user-opened windows aren't
        // absorbed (see `claimRestoredWindow`).
        if !restoreEntries.isEmpty {
            restoreReattachDeadline = Date().addingTimeInterval(Self.restoreReattachGracePeriod)
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
                     profileId: String,
                     makeDefaultActive: Bool = true) -> String? {
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
        // Theme is the caller's responsibility: the create form sets the new
        // Space's theme explicitly via `setTheme` right after this returns, so
        // createSpace stays theme-agnostic (no implicit inherit-from-active).
        // Record the new Space as the persisted default so the first window
        // that opens with no spawn/restore claim lands on it. This is cheap and
        // does NOT spawn the Space's Chromium window. Bringing the new Space to
        // the front of the *currently-focused* window — which does require that
        // spawn — is the caller's job via `activateInFocusedWindow`, so a create
        // made with no window open still seeds the pointer without paying the
        // spawn cost. Agent Spaces pass `makeDefaultActive: false`: they are
        // background workspaces and must not steal the next window's landing
        // Space.
        if makeDefaultActive {
            persistActiveSpaceId(newSpaceId)
        }
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
        // `keySlot` is weak and can be nil in edge states (e.g. right after a
        // sheet held key, or mid slot-teardown); falling back to the first
        // live slot beats silently dropping the switch — the agent-handoff
        // prompt's "Switch to Agent Space" button lands here.
        guard let slot = keySlot ?? slots.first else {
            AppLogWarn("[SpaceManager] activateInFocusedWindow(\(spaceId)): no live slot")
            return
        }
        slot.activate(spaceId: spaceId)
    }

    /// Moves `tab` out of its current Space and into the Space identified by
    /// `targetSpaceId`, then surfaces that Space with the tab focused.
    ///
    /// Two paths, chosen by profile:
    ///  - **Same profile** — a true move. The target Space's window is
    ///    spawned/surfaced in the tab's own slot, then Chromium runs an atomic
    ///    cross-window detach + insert (`moveSelfToWindow:atIndex:`), preserving
    ///    the live WebContents, its history and tab identity. Chromium activates
    ///    the inserted tab in the target, satisfying the "focus the moved tab"
    ///    contract for free — exactly as the cross-window drag path relies on.
    ///  - **Different profile** — a live WebContents cannot cross a profile
    ///    (BrowserContext) boundary, so the tab's URL is opened as a fresh,
    ///    focused tab in the target Space and the origin tab is closed.
    ///
    /// Either path needs the target window to exist before the tab can land in
    /// it, so the work runs inside `activate`'s `onSwapSettled` — by then the
    /// target controller is registered and on screen, whether it was an existing
    /// window (swap) or freshly spawned.
    ///
    /// Callers (the tab context menu) only offer this for plain normal tabs;
    /// pinned / split / bookmark-backed tabs are filtered out there because
    /// their per-Space persistence bindings would be stranded by a move.
    func moveTab(_ tab: Tab, toSpaceId targetSpaceId: String) {
        guard let sourceState = MainBrowserWindowControllersManager.shared
                .getBrowserState(for: tab.windowId) else {
            AppLogWarn("[SpaceManager] moveTab: no BrowserState for windowId \(tab.windowId)")
            return
        }
        // Already in the target Space — nothing to do.
        guard targetSpaceId != sourceState.spaceId else { return }
        guard let targetSpace = spaces.first(where: { $0.spaceId == targetSpaceId }) else {
            AppLogWarn("[SpaceManager] moveTab: unknown target space \(targetSpaceId)")
            return
        }
        guard let slot = slot(forWindowId: tab.windowId) else {
            AppLogWarn("[SpaceManager] moveTab: no slot owns windowId \(tab.windowId)")
            return
        }

        // A live WebContents can only be detached+inserted within one profile.
        // Incognito windows expose no Spaces, so "non-incognito source with a
        // matching profileId" is the complete same-profile condition.
        let sameProfile = !sourceState.isIncognito
            && targetSpace.profileId == sourceState.profileId
        let tabGuid = tab.guid
        let url = tab.url
        let sourceWrapper = sameProfile ? tab.webContentWrapper : nil

        // Cross-profile recreation needs a URL to copy; bail if there is none.
        if !sameProfile, (url ?? "").isEmpty {
            AppLogWarn("[SpaceManager] moveTab: cross-profile move with empty URL — ignoring")
            return
        }
        if sameProfile, sourceWrapper == nil {
            AppLogWarn("[SpaceManager] moveTab: source tab lost its web contents")
            return
        }

        // `slot` is weak to avoid a retain cycle (the slot owns the swap
        // machinery that holds this closure); `tab` and `sourceWrapper` are
        // captured strongly so they outlive the swap animation / async spawn.
        slot.activate(spaceId: targetSpaceId) { [weak slot] in
            // `onSwapSettled` always fires on the main thread (swap-animation
            // completion or the spawn path's `DispatchQueue.main.async`), so we
            // can synchronously assume main-actor isolation for the tab moves —
            // `Tab.close()` and the native state updates are main-actor isolated.
            MainActor.assumeIsolated {
                guard let slot,
                      let targetState = slot.windowController(for: targetSpaceId)?.browserState else {
                    AppLogWarn("[SpaceManager] moveTab: target window unavailable after activate")
                    return
                }
                if sameProfile {
                    guard let sourceWrapper else { return }
                    // Append to the end of the target's normal tabs; the scheduled
                    // insertion lands the arriving tab there, mirroring the
                    // cross-window drag path in `TabStrip.moveTabToWindow`.
                    let normalIndex = targetState.normalTabs.count
                    targetState.scheduleNormalTabInsertion(tabGuid: tabGuid, at: normalIndex)
                    sourceWrapper.moveSplit(toWindow: targetState.windowId.int64Value,
                                            at: targetState.tabs.count)
                } else {
                    targetState.createTab(url, focusAfterCreate: true)
                    SpaceMoveTabUnit.tab(tab).closeSourceTabsAfterCrossProfileMove()
                }
            }
        }
    }

    enum SpaceMoveTabUnit {
        case tab(Tab)
        case split(left: Tab, right: Tab)

        var tabs: [Tab] {
            switch self {
            case .tab(let tab):
                return [tab]
            case .split(let left, let right):
                return [left, right]
            }
        }

        var hasRequiredURLs: Bool {
            tabs.allSatisfy { ($0.url ?? "").isEmpty == false }
        }

        var normalTabCount: Int {
            tabs.count
        }

        var moveWrapper: (WebContentWrapper & NSObject)? {
            switch self {
            case .tab(let tab):
                return tab.webContentWrapper
            case .split(let left, let right):
                return left.webContentWrapper ?? right.webContentWrapper
            }
        }

        @MainActor
        func closeSourceTabsAfterCrossProfileMove() {
            tabs.forEach { $0.close() }
        }
    }

    func tabMoveUnits(from tabs: [Tab], sourceState: BrowserState) -> [SpaceMoveTabUnit] {
        let requestedIds = Set(tabs.map(\.guid))
        var units: [SpaceMoveTabUnit] = []
        var consumedSplitIds = Set<String>()

        for tab in sourceState.normalTabs where requestedIds.contains(tab.guid) {
            guard sourceState.tabs.contains(where: { $0.guid == tab.guid }),
                  !tab.isPinned else {
                continue
            }

            guard let splitGroup = sourceState.splitGroup(forTabId: tab.guid) else {
                units.append(.tab(tab))
                continue
            }
            guard !splitGroup.isPinned,
                  !consumedSplitIds.contains(splitGroup.id),
                  let left = sourceState.tabs.first(where: { $0.guid == splitGroup.primaryTabId }),
                  let right = sourceState.tabs.first(where: { $0.guid == splitGroup.secondaryTabId }),
                  !left.isPinned,
                  !right.isPinned else {
                continue
            }

            consumedSplitIds.insert(splitGroup.id)
            units.append(.split(left: left, right: right))
        }

        return units
    }

    /// Batch variant used by multi-selection actions. The caller filters
    /// bookmark-backed selections before entering this API; live split tabs are
    /// preserved as split units instead of being torn into separate tabs.
    /// `completion(true)` means every target-side command was issued after the
    /// target window resolved; it does not wait for Chromium's later tab events.
    @discardableResult
    func moveTabs(_ tabs: [Tab],
                  from sourceState: BrowserState,
                  toSpaceId targetSpaceId: String,
                  completion: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        let movingUnits = tabMoveUnits(from: tabs, sourceState: sourceState)
        guard !movingUnits.isEmpty else { return false }
        guard targetSpaceId != sourceState.spaceId else { return false }
        guard let targetSpace = spaces.first(where: { $0.spaceId == targetSpaceId }) else {
            AppLogWarn("[SpaceManager] moveTabs: unknown target space \(targetSpaceId)")
            return false
        }
        guard let slot = slot(forWindowId: sourceState.windowId) else {
            AppLogWarn("[SpaceManager] moveTabs: no slot owns windowId \(sourceState.windowId)")
            return false
        }

        let sameProfile = !sourceState.isIncognito
            && targetSpace.profileId == sourceState.profileId
        if !sameProfile, movingUnits.contains(where: { !$0.hasRequiredURLs }) {
            AppLogWarn("[SpaceManager] moveTabs: cross-profile move contains an empty URL")
            return false
        }
        let moveOperations = movingUnits.compactMap { unit in
            unit.moveWrapper.map { (unit: unit, wrapper: $0) }
        }
        if sameProfile, moveOperations.count != movingUnits.count {
            AppLogWarn("[SpaceManager] moveTabs: source selection lost its web contents")
            return false
        }

        slot.activate(spaceId: targetSpaceId) { [weak slot] in
            MainActor.assumeIsolated {
                guard let slot,
                      let targetState = slot.windowController(for: targetSpaceId)?.browserState else {
                    AppLogWarn("[SpaceManager] moveTabs: target window unavailable after activate")
                    completion(false)
                    return
                }

                if sameProfile {
                    let baseNormalIndex = targetState.normalTabs.count
                    let baseStripIndex = targetState.tabs.count
                    var normalOffset = 0
                    var stripOffset = 0
                    for operation in moveOperations {
                        let unit = operation.unit
                        switch unit {
                        case .tab(let tab):
                            targetState.scheduleNormalTabInsertion(tabGuid: tab.guid,
                                                                   at: baseNormalIndex + normalOffset)
                            operation.wrapper.moveSplit(toWindow: targetState.windowId.int64Value,
                                                        at: baseStripIndex + stripOffset)
                            normalOffset += 1
                            stripOffset += 1
                        case .split:
                            operation.wrapper.moveSplit(toWindow: targetState.windowId.int64Value,
                                                        at: baseStripIndex + stripOffset)
                            normalOffset += unit.normalTabCount
                            stripOffset += unit.normalTabCount
                        }
                    }
                } else {
                    for (offset, unit) in movingUnits.enumerated() {
                        switch unit {
                        case .tab(let tab):
                            targetState.createTab(tab.url, focusAfterCreate: offset == movingUnits.count - 1)
                            unit.closeSourceTabsAfterCrossProfileMove()
                        case .split(let left, let right):
                            guard let primaryURL = left.url, !primaryURL.isEmpty,
                                  let secondaryURL = right.url, !secondaryURL.isEmpty else {
                                AppLogWarn(
                                    "[SpaceManager] moveTabs: source split " +
                                    "\(left.guid),\(right.guid) lost its URLs"
                                )
                                continue
                            }
                            targetState.openTwoURLsAsSplit(primaryURL: primaryURL,
                                                           secondaryURL: secondaryURL)
                            unit.closeSourceTabsAfterCrossProfileMove()
                        }
                    }
                }
                completion(true)
            }
        }
        return true
    }

    /// Recreates a multi-selection in another Space without changing the
    /// source tabs. Split units are opened as splits in their original order.
    @discardableResult
    func cloneTabs(_ tabs: [Tab],
                   from sourceState: BrowserState,
                   toSpaceId targetSpaceId: String,
                   completion: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        let cloningUnits = tabMoveUnits(from: tabs, sourceState: sourceState)
        guard !cloningUnits.isEmpty else { return false }
        guard targetSpaceId != sourceState.spaceId else { return false }
        guard spaces.contains(where: { $0.spaceId == targetSpaceId }) else {
            AppLogWarn("[SpaceManager] cloneTabs: unknown target space \(targetSpaceId)")
            return false
        }
        guard let slot = slot(forWindowId: sourceState.windowId) else {
            AppLogWarn("[SpaceManager] cloneTabs: no slot owns windowId \(sourceState.windowId)")
            return false
        }
        guard cloningUnits.allSatisfy(\.hasRequiredURLs) else {
            AppLogWarn("[SpaceManager] cloneTabs: source selection contains an empty URL")
            return false
        }

        slot.activate(spaceId: targetSpaceId) { [weak slot] in
            MainActor.assumeIsolated {
                guard let slot,
                      let targetState = slot.windowController(for: targetSpaceId)?.browserState else {
                    AppLogWarn("[SpaceManager] cloneTabs: target window unavailable after activate")
                    completion(false)
                    return
                }

                for (offset, unit) in cloningUnits.enumerated() {
                    switch unit {
                    case .tab(let tab):
                        targetState.createTab(tab.url,
                                              focusAfterCreate: offset == cloningUnits.count - 1)
                    case .split(let left, let right):
                        guard let primaryURL = left.url, !primaryURL.isEmpty,
                              let secondaryURL = right.url, !secondaryURL.isEmpty else {
                            continue
                        }
                        targetState.openTwoURLsAsSplit(primaryURL: primaryURL,
                                                       secondaryURL: secondaryURL)
                    }
                }
                completion(true)
            }
        }
        return true
    }

    func renameSpace(spaceId: String, to name: String) {
        boundAccount?.localStorage.updateSpace(spaceId: spaceId, name: name)
    }

    func recolorSpace(spaceId: String, colorHex: String) {
        boundAccount?.localStorage.updateSpace(spaceId: spaceId, colorHex: colorHex)
    }

    func changeIcon(spaceId: String, iconName: String) {
        // An Incognito Space has no SpaceModel row — its icon lives on the
        // runtime descriptor; rebuild the synthetic entry so the strip
        // updates immediately.
        if Self.isIncognitoSpaceId(spaceId) {
            guard let index = incognitoSpaces.firstIndex(where: { $0.spaceId == spaceId }) else { return }
            incognitoSpaces[index].iconName = iconName
            refreshIncognitoSpacePresence()
            return
        }
        boundAccount?.localStorage.updateSpace(spaceId: spaceId, iconName: iconName)
    }

    func deleteSpace(spaceId: String) {
        // Incognito Spaces have no store rows to delete — "delete" for them
        // is closing the Space. No UI offers delete for them; this redirect
        // is a safety net for stray callers.
        if Self.isIncognitoSpaceId(spaceId) {
            MainActor.assumeIsolated { closeIncognitoSpace(spaceId: spaceId) }
            return
        }
        guard spaceId != LocalStore.defaultSpaceId else {
            AppLogWarn("[SpaceManager] refusing to delete the default space")
            return
        }
        // An import currently writing into this Space must finish first, or its
        // pending bookmark snapshot would be stranded under a root whose Space
        // we just deleted. Refuse and tell the user rather than racing the write.
        guard !ImportTargetLock.shared.isImporting(into: spaceId) else {
            AppLogWarn("[SpaceManager] refusing to delete space \(spaceId): import in progress")
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Can’t delete this Space yet",
                comment: "Title shown when deleting a Space is blocked by an in-progress import"
            )
            alert.informativeText = NSLocalizedString(
                "An import is still adding bookmarks to this Space. Wait for it to finish, then try again.",
                comment: "Body shown when deleting a Space is blocked by an in-progress import"
            )
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss button"))
            alert.runModal()
            return
        }
        // If this Space hosts a live agent task, drop the task record with the
        // Space — otherwise it lingers and a stateless CDP client keeps
        // "finding" a task whose window is gone, forcing a dedicated purge
        // round. Main thread: deletes are UI-driven (same assumption as the
        // other AgentSpaceManager hooks in this file).
        MainActor.assumeIsolated {
            AgentSpaceManager.shared.spaceWasDeleted(spaceId: spaceId)
        }
        // A queued profile-change reopen for this Space is moot once the
        // Space itself goes away.
        pendingProfileChangeReopens.removeValue(forKey: spaceId)
        closeSpaceWindows(spaceId: spaceId)
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

    /// Closes every live window this Space has, across all slots — the
    /// window-teardown half of `deleteSpace`, also used on its own when a
    /// PERSISTENT agent task completes: the task's window must go, but the
    /// Space row (and its tagged rows) stays in the switcher for the user,
    /// and for a later task to re-bind to.
    func closeSpaceWindows(spaceId: String) {
        // Any slot currently active on this Space retreats — back to the last
        // regular Space it surfaced (so a completed agent task lands the user
        // on the Space they came from, not the global default), falling back
        // to the default Space when that Space is the one being deleted or no
        // longer exists — with the usual switch animation, then closes the
        // deleted Space's window, but only once the slide settles
        // (`onSwapSettled`). By then the retreat has fronted the target Space
        // and ordered the leaving window out, so the close lands on an
        // already off-screen window and the browser never blinks. Closing it
        // synchronously here would race the in-flight slide and tear down the
        // still-front window mid-animation, which is why the retreat used to
        // be instant.
        let retreatingSlots = slots.filter { $0.activeSpaceId == spaceId }
        for slot in retreatingSlots {
            let retreatTarget: String = {
                if let last = slot.lastRegularSpaceId, last != spaceId,
                   spaces.contains(where: { $0.spaceId == last }) {
                    return last
                }
                return LocalStore.defaultSpaceId
            }()
            slot.activate(spaceId: retreatTarget) { [weak slot] in
                guard let slot,
                      let controller = slot.windowController(for: spaceId) else { return }
                // If the retreat never completed (e.g. its window spawn failed
                // on a profile-load error) the deleted Space's window is still
                // the slot's visible one. Closing it now would be classified as
                // a window-driven close and cascade the entire slot shut —
                // worst case terminating the app over a Space delete. Leave it
                // open instead; the Space row is still removed below.
                guard slot.visibleController !== controller else {
                    AppLogWarn("[SpaceManager] deleteSpace: not closing \(spaceId)'s window — it is still visible (retreat did not complete)")
                    return
                }
                // Evict before closing (as `changeProfile` does) so the window
                // teardown's late `unregisterWindow` fails its identity check and
                // skips the visible-close side effects. Without this the close is
                // classified as window-driven and cascades the whole slot shut —
                // the user-perceived window vanishes on a Space delete.
                // `closeRetiredWindow` parks key on the visible window first:
                // the deleted Space's window can still hold key (the user was
                // just watching it), and closing a key window lets AppKit
                // promote a hidden sibling that would then be adopted as a
                // Space switch.
                slot.evictWindow(for: spaceId)
                slot.closeRetiredWindow(controller)
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
            // Defensive parity with the retreating closure above and
            // `changeProfile`: if a slot's visible window lags its activeSpaceId
            // (e.g. a failed cross-profile switch left it on the deleted Space's
            // still-visible window), don't close it — that would drop the
            // user-perceived window. The Space row is removed regardless.
            guard slot.visibleController !== controller else { continue }
            // Evict before closing for the same reason as the retreating slots
            // above: a late window-driven unregister would otherwise cascade the
            // slot shut. `closeRetiredWindow` also parks key on the slot's
            // visible window first so the close can't hand key to a hidden
            // sibling.
            slot.evictWindow(for: spaceId)
            slot.closeRetiredWindow(controller)
        }
    }

    /// Removes agent Spaces that have no live task. Agent Spaces are ephemeral
    /// (owned by `AgentSpaceManager` only for the life of a task); one that was
    /// persisted and outlived its in-memory task — typically across a relaunch —
    /// is an orphan and must not linger as a stale "Agent" pip. Matched by the
    /// agent-Space visual signature and confirmed taskless before deletion.
    @MainActor
    private func deleteOrphanedAgentSpaces(from allSpaces: [SpaceModel]) {
        for space in allSpaces {
            guard AgentSpaceManager.isAgentSpaceModel(
                    name: space.name,
                    iconName: space.iconName,
                    colorHex: space.colorHex),
                  !AgentSpaceManager.shared.isAgentSpace(space.spaceId) else { continue }
            AppLogInfo("[SpaceManager] sweeping orphaned agent Space \(space.spaceId)")
            deleteSpace(spaceId: space.spaceId)
        }
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
        // An agent Space is bound to the profile its task runs against;
        // re-profiling replaces its windows and would break the running agent.
        // Refuse regardless of ownership — even after the user takes control.
        // Matched by signature (ephemeral) OR by live task: a PERSISTENT agent
        // Space looks like a regular Space, but while a task drives it the
        // same window-replacement hazard applies. Once its task ends it can be
        // re-profiled like any Space.
        let hostsLiveAgentTask = MainActor.assumeIsolated {
            AgentSpaceManager.shared.isAgentSpace(spaceId)
        }
        if hostsLiveAgentTask
            || spaces.first(where: { $0.spaceId == spaceId })?.isAgentSpace == true {
            AppLogWarn("[SpaceManager] refusing to change profile of agent Space \(spaceId)")
            return
        }
        // An import currently writing into this Space must finish first:
        // re-profiling re-stamps the Space's bookmark rows, so the deferred
        // import snapshot would be stranded under the old (profileId, spaceId)
        // and silently dropped by the persist backstop. Refuse and tell the user.
        guard !ImportTargetLock.shared.isImporting(into: spaceId) else {
            AppLogWarn("[SpaceManager] refusing to change profile of space \(spaceId): import in progress")
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Can’t change this Space’s profile yet",
                comment: "Title shown when changing a Space's profile is blocked by an in-progress import"
            )
            alert.informativeText = NSLocalizedString(
                "An import is still adding bookmarks to this Space. Wait for it to finish, then try again.",
                comment: "Body shown when a Space action is blocked by an in-progress import"
            )
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss button"))
            alert.runModal()
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
        // Incognito Spaces have no SpaceModel rows to renumber; each one's
        // position is captured on its runtime descriptor (as an index into
        // the full list) and the store write gets the remaining ids. The
        // explicit refresh republishes the arrangement right away — a drag
        // that only moved an Incognito Space may leave every user Space's
        // sortOrder unchanged, so the store emission alone can't be relied on.
        var ordered = spaceIds
        for (index, spaceId) in spaceIds.enumerated() where Self.isIncognitoSpaceId(spaceId) {
            if let descriptorIndex = incognitoSpaces.firstIndex(where: { $0.spaceId == spaceId }) {
                incognitoSpaces[descriptorIndex].sortIndex = index
            }
        }
        ordered.removeAll { Self.isIncognitoSpaceId($0) }
        let known = Set(spaces.map(\.spaceId))
        account.localStorage.reorderSpaces(
            orderedSpaceIds: ordered.filter { known.contains($0) }
        )
        if ordered.count != spaceIds.count {
            refreshIncognitoSpacePresence()
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
        for (spaceId, drafts) in byTargetSpaceId where Self.isRoutableRuleTarget(spaceId) {
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
            guard rule.spaceId != spaceId,
                  Self.isRoutableRuleTarget(rule.spaceId) else { return nil }
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

        // User-Space rules and the generic Incognito target route; any other
        // id under the incognito prefix would be a stale runtime Space id —
        // keep such a row inert instead of routing into a Space that no
        // longer exists.
        let effectiveRules = cachedURLRules.filter { Self.isRoutableRuleTarget($0.spaceId) }
        var rulesPayload: [[String: Any]] = effectiveRules.map { rule in
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

    /// Opens `urlString` in a Space after a URL rule routed it there: an "ask
    /// first" match the user resolved in `PhiChromiumCoordinator`'s prompt, the
    /// right-click "Open link as" submenu, or a silent auto-route to a Space with
    /// no open window (`routeURL`). `spaceId == nil` means "keep it here": the
    /// URL opens as a new foreground tab in the source window. Otherwise the
    /// chosen Space is brought to the front in the source window's slot (spawning
    /// its window when the Space isn't currently open) and the URL opens there.
    ///
    /// The matching navigation was already cancelled on the Chromium side, so
    /// this always opens *something* — if the chosen Space's window can't be
    /// resolved (rare cold-spawn race), it falls back to the source window so
    /// the URL is never silently dropped.
    @MainActor
    func routeAskedURL(_ urlString: String, toSpaceId spaceId: String?, sourceWindowId: Int64, sourceIsNewTab: Bool) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        // Bypass space routing for the re-open: the URL matched an ask-rule,
        // so a plain new tab would be caught by the same rule and prompt
        // again in a loop. The bridge exempts this one (url, window) pair.
        //
        // `activateWindow` is false when the slot's switch animation owns
        // fronting the target: the vertical push-in keeps the LEAVING window
        // front for its whole duration, so Chromium's window Activate() on the
        // open would surface the target mid-animation and the routed switch
        // would land with no visible animation. It stays true when no slot
        // switch is choreographing the window (same-Space opens and the
        // spawn-failure fallback), where surfacing is the point.
        let open: (_ windowId: Int64, _ activateWindow: Bool) -> Void = { windowId, activateWindow in
            bridge.openTabBypassingSpaceRouting(
                withUrl: urlString, windowId: windowId, activateWindow: activateWindow)
        }

        let sourceController = MainBrowserWindowControllersManager.shared
            .controller(for: Int(sourceWindowId))
        let currentSpaceId = sourceController?.spaceId
        // An incognito target — the rules' generic Incognito id, or a Space
        // that closed since the chooser was shown — resolves to a live
        // Incognito Space here, created on demand.
        let spaceId = spaceId.map {
            Self.isIncognitoSpaceId($0)
                ? resolveIncognitoRouteTarget($0, currentSpaceId: currentSpaceId)
                : $0
        }
        // Whether the source is a stranded new tab / NTP. The Chromium-side
        // `sourceIsNewTab` covers the regular web NTP path, and the Swift
        // focusing-tab fallback covers the native incognito NTP path.
        let sourceIsStranded = sourceIsNewTab
            || (sourceController?.browserState.focusingTab.map(Self.isStrandedNewTab) ?? false)

        // Staying in the source window's current Space: the user kept the URL
        // here (`spaceId == nil`) or chose the Space it already lives in. When
        // the navigation started from a new tab / NTP, open the URL directly in
        // that NTP (in place, exempted from routing so an ask-rule doesn't
        // re-prompt) instead of spawning a separate tab; otherwise keep the
        // new-tab behavior.
        guard let spaceId, spaceId != currentSpaceId else {
            if sourceIsStranded {
                bridge.navigateActiveTabBypassingSpaceRouting(
                    withUrl: urlString, windowId: sourceWindowId)
            } else {
                open(sourceWindowId, true)
            }
            return
        }

        // The URL is going to a DIFFERENT Space. Keep the source new tab and
        // reset it to a clean NTP because the source navigation was cancelled
        // before it could complete. Do it before the slot swaps the source
        // window out of view so the reset lands while it's still mounted.
        if sourceIsStranded {
            refreshActiveNewTab(inWindow: sourceWindowId)
        }

        let sourceSlot = slots.first { $0.contains(windowId: Int(sourceWindowId)) }
        let slot = sourceSlot ?? keySlot ?? slots.first
        // Re-key the source window before a cold spawn. When the target Space
        // has no window yet, `activate` spawns one and, in native fullscreen,
        // tabs it into the source window's single macOS Space (`syncSlotTabGroup`
        // → `addTabbedWindow`). AppKit only keeps the spawned window in that
        // Space when the source window is the key window at spawn time. The
        // swipe/click and "ask first" paths satisfy this implicitly — they run
        // inside an AppKit user event on the focused window, and the chooser
        // dismissal even calls `makeKey()` on the source window — but the silent
        // auto-route reaches here straight from a Chromium IPC callback with no
        // such event, so the spawn strands the new window in its own macOS Space
        // (the stray window the user sees over the fullscreen). Asserting key
        // focus first mirrors the path that already works.
        if slot?.windowController(for: spaceId) == nil,
           let sourceWindow = MainBrowserWindowControllersManager.shared
               .controller(for: Int(sourceWindowId))?.window {
            sourceWindow.makeKey()
        }
        slot?.activate(spaceId: spaceId)
        if let controller = slot?.windowController(for: spaceId) {
            // The activate above is animating the slot to the target — the
            // slot fronts the target window when the animation settles, so
            // the open must not activate it early.
            open(Int64(controller.windowId), false)
            return
        }
        // Cold path: the Space's window spawns asynchronously. A
        // cross-/unloaded-profile target's `ensureProfileLoaded` completion can
        // land hundreds of ms later (the first cross-profile activation of a
        // session pays a disk profile load), so a single next-tick retry
        // deterministically misses it — the URL would then open in the source
        // window while a blank target window surfaces moments later. Retry on a
        // short escalating schedule, opening in the target as soon as its window
        // registers, and only fall back to the source window after the last
        // attempt, so the routed URL reaches the chosen Space when the spawn
        // merely lagged and is still never silently dropped. Mirrors
        // `scheduleRestoreVisibilityReconcile`'s coalesced-delay pattern.
        let retryDelays: [TimeInterval] = [0.05, 0.25, 0.6, 1.2]
        var didOpen = false
        for (index, delay) in retryDelays.enumerated() {
            let isLastAttempt = index == retryDelays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak slot] in
                guard !didOpen else { return }
                if let controller = slot?.windowController(for: spaceId) {
                    didOpen = true
                    // The slot surfaced (or is surfacing) the spawned window
                    // itself; activating here would cut any present animation
                    // short.
                    open(Int64(controller.windowId), false)
                } else if isLastAttempt {
                    didOpen = true
                    // Spawn failed — nothing choreographs the source window
                    // anymore, so activate it to honor "never silently
                    // dropped".
                    open(sourceWindowId, true)
                }
            }
        }
    }

    /// True when `tab` is a stranded new tab / NTP, the only source state for
    /// which Space routing reuses or refreshes the tab in place.
    static func isStrandedNewTab(_ tab: Tab) -> Bool {
        tab.isShowingNativeNTP || tab.isNTP || (tab.url?.isEmpty ?? true)
    }

    /// Resets `windowId`'s active new-tab page to a clean state after a Space
    /// URL rule routed a new-tab navigation to a DIFFERENT Space. Shared by
    /// `routeAskedURL`'s different-Space path and the `refreshNewTabInWindow`
    /// bridge callback.
    @MainActor
    func refreshActiveNewTab(inWindow windowId: Int64) {
        // Gate here too: the auto-route C++ callback can fire for a non-NTP
        // source, and only a stranded new tab should be reset.
        guard let controller = MainBrowserWindowControllersManager.shared
                .controller(for: Int(windowId)),
              let tab = controller.browserState.focusingTab,
              Self.isStrandedNewTab(tab) else { return }
        controller.mainSplitViewController.webContentContainerViewController
            .refreshActiveNewTab()
    }

    /// Picks one windowId per Space that is currently VISIBLE on screen. A
    /// Space can be active in multiple slots simultaneously; the keySlot wins
    /// the tiebreak so cross-Space routing lands in the window the user just had
    /// focused.
    ///
    /// Only each slot's visible window is reported — never a non-visible sibling
    /// (a Space whose window the slot keeps off-screen, e.g. a session-restored
    /// window the slot hides behind the active Space). This is what makes the
    /// C++ router (`PhiURLRouter`) treat routing to a non-visible Space as
    /// `kRouteToSpace` (hand to `routeAskedURL`) instead of `kRoute` (surface
    /// the window directly via `Navigate(kShowWindow)`). The direct path
    /// bypasses the slot's swap logic: in fullscreen a restored sibling window
    /// is detached from the native tab group, so surfacing it that way strands
    /// it in its own macOS Space (a stray window over the fullscreen). Routing
    /// through `routeAskedURL` re-enters the slot's fullscreen-aware swap, which
    /// re-attaches the window into the fullscreen Space before surfacing it.
    /// `visibleController`'s didSet re-pushes this map so a Space switch keeps it
    /// fresh.
    private func currentSpaceWindowMap() -> [String: Int] {
        var result: [String: Int] = [:]
        var ordered: [SpaceWindowSlot] = []
        if let key = keySlot { ordered.append(key) }
        ordered.append(contentsOf: slots.filter { $0 !== keySlot })
        for slot in ordered {
            guard let controller = slot.visibleController,
                  result[controller.spaceId] == nil else { continue }
            result[controller.spaceId] = controller.windowId
        }
        // Alias the generic Incognito rule target to the first (strip-order)
        // Incognito Space's visible window, so the C++ router surfaces it
        // directly exactly as it would any other Space with an on-screen
        // window. With no live window the id stays unmapped and the router
        // hands the navigation to `routeAskedURL`, which resolves the target
        // — creating the Space when none exists.
        if let first = spaces.first(where: { Self.isIncognitoSpaceId($0.spaceId) }),
           let windowId = result[first.spaceId] {
            result[Self.incognitoRuleTargetId] = windowId
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
        // Never remember an Incognito Space as last-active: cold launch and
        // new slots must always land on a persistent Space. Agent Spaces are
        // excluded for the same reason — they are deleted on completion (or
        // orphan-swept at launch), so a user watching one must not make it
        // the seed for the next window. Checked both by live task and by
        // model signature so a mid-deletion Space (task record already
        // dropped) is still caught.
        guard !Self.isIncognitoSpaceId(spaceId) else { return }
        guard !MainActor.assumeIsolated({ AgentSpaceManager.shared.isAgentSpace(spaceId) }),
              spaces.first(where: { $0.spaceId == spaceId })?.isAgentSpace != true else { return }
        boundAccount?.userDefaults.set(spaceId, forKey: .activeSpaceId)
    }

    // MARK: - Account / login binding

    @objc private func handleLoginCompleted() {
        if let account = AccountController.shared.account {
            bind(to: account)
        }
        // Re-run the reconcile skipped while logged out. Async so it lands after
        // the window manager registers the dangling windows on this same
        // `.loginCompleted` post, so `activate` swaps instead of spawning.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Read fresh from the bound account; `self.spaces` may still hold the
            // pre-login default-account emission (bind refreshes it async).
            let spaces = self.boundAccount?.localStorage.getAllSpaces() ?? self.spaces
            // Empty while `ensureDefaultSpace` is still in flight; let the
            // publisher emission reconcile once the store is populated.
            guard !spaces.isEmpty else { return }
            self.handleSpacesUpdate(spaces)
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
            // Agent Spaces are ephemeral — they should exist only while their
            // (in-memory) task runs. Any that were persisted and outlived their
            // task, e.g. across this relaunch, are orphans with no live task;
            // sweep them so a stale "Agent" pip never lingers in the switcher.
            self.deleteOrphanedAgentSpaces(from: account.localStorage.getAllSpaces())
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

    /// Re-derives `spaces` from the last store emission after the set of
    /// Incognito Spaces changes (create, close, icon, reorder). Reuses
    /// `handleSpacesUpdate` wholesale so the slot reconciliation (switch
    /// slots off a closed Incognito Space) runs exactly as it would for a
    /// store-driven change.
    func refreshIncognitoSpacePresence() {
        handleSpacesUpdate(lastStoreSpaces)
    }

    /// Creates a new Incognito Space and puts it in the strip. All Incognito
    /// Spaces share the single Chromium OTR profile; the parent profile is
    /// warmed here so the first activation doesn't pay the load. The Space
    /// lives until `closeIncognitoSpace` tears it down or its last window
    /// closes (`reapIncognitoSpaceIfWindowless`); nothing about it persists.
    /// Bringing it to the front is the caller's job, as with `createSpace`.
    @MainActor
    @discardableResult
    func createIncognitoSpace() -> String {
        // The lowest display number not in use, so a fresh Space never
        // shadows a live sibling and numbering restarts once all are closed.
        let usedOrdinals = Set(incognitoSpaces.map(\.ordinal))
        let ordinal = (1...).first { !usedOrdinals.contains($0) } ?? incognitoSpaces.count + 1
        let descriptor = IncognitoSpaceDescriptor(
            spaceId: "\(Self.incognitoSpaceIdPrefix).\(UUID().uuidString)",
            ordinal: ordinal,
            iconName: Self.incognitoSpaceDefaultIcon,
            sortIndex: nil
        )
        incognitoSpaces.append(descriptor)
        ChromiumLauncher.sharedInstance().bridge?.ensureIncognitoSpaceProfileLoaded { success in
            if !success {
                AppLogWarn("[SpaceManager] Incognito Space profile warm-up failed; first activation will retry")
            }
        }
        refreshIncognitoSpacePresence()
        pushSpaceStateToChromium()
        return descriptor.spaceId
    }

    /// Resolves an incognito route target to a live Incognito Space, creating
    /// one when none exists. An exact live id routes to itself (the "Open
    /// Link In Space" submenu names specific Incognito Spaces); the generic
    /// rule target (`incognitoRuleTargetId`, or a Space that closed since the
    /// chooser was shown) prefers the Space the navigation started in when
    /// that is already incognito — every Incognito Space shares one session,
    /// so hopping between them buys nothing — then the first live one in
    /// strip order.
    @MainActor
    private func resolveIncognitoRouteTarget(_ spaceId: String, currentSpaceId: String?) -> String {
        if spaces.contains(where: { $0.spaceId == spaceId }) {
            return spaceId
        }
        if let currentSpaceId, Self.isIncognitoSpaceId(currentSpaceId),
           spaces.contains(where: { $0.spaceId == currentSpaceId }) {
            return currentSpaceId
        }
        if let first = spaces.first(where: { Self.isIncognitoSpaceId($0.spaceId) }) {
            return first.spaceId
        }
        return createIncognitoSpace()
    }

    /// Asks the user to confirm closing the Incognito Space `spaceId` — the
    /// close also ends the Space itself — then tears it down. The prompt is
    /// skipped once "Do not ask again" has been checked. Returns true when
    /// the Space was closed. Called by the "Close Incognito Space" menu item
    /// and by both last-tab close paths (⌘W and the tab-row ✕).
    @MainActor
    @discardableResult
    func requestCloseIncognitoSpace(spaceId: String) -> Bool {
        guard incognitoSpaces.contains(where: { $0.spaceId == spaceId }) else { return false }
        if !PhiPreferences.GeneralSettings.suppressCloseIncognitoSpaceWarning.loadValue() {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "This will also close this Incognito Space, are you sure?",
                comment: "Title of the confirmation shown when a close would tear down an Incognito Space")
            alert.alertStyle = .warning
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = NSLocalizedString(
                "Do not ask again",
                comment: "Suppression checkbox of the close-Incognito-Space confirmation")
            alert.addButton(withTitle: NSLocalizedString("Close", comment: "Confirm closing an Incognito Space"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(
                    true,
                    forKey: PhiPreferences.GeneralSettings.suppressCloseIncognitoSpaceWarning.rawValue
                )
            }
        }
        closeIncognitoSpace(spaceId: spaceId)
        return true
    }

    /// Tears down the Incognito Space `spaceId`: closes its windows in every
    /// slot (retreat-first for slots currently showing it), then removes it
    /// from the strip. Closing the last Incognito Space window overall is
    /// what makes Chromium destroy the shared OTR profile and clear the
    /// private session — with another Incognito Space still open, the session
    /// data lives on in it.
    @MainActor
    func closeIncognitoSpace(spaceId: String) {
        guard Self.isIncognitoSpaceId(spaceId) else { return }
        closeIncognitoSpaceWindows(spaceId: spaceId)
        removeIncognitoSpaceDescriptor(spaceId)
    }

    /// Retires the Incognito Space `spaceId` once no slot holds a window for
    /// it anymore. Called (a runloop turn deferred) from
    /// `SpaceWindowSlot.unregisterWindow` so close paths that bypass
    /// `closeIncognitoSpace` — a window-driven slot cascade, a scripted
    /// window.close, the tab-driven hand-off — still take the Space with
    /// them instead of stranding an empty pip in the strip.
    fileprivate func reapIncognitoSpaceIfWindowless(_ spaceId: String) {
        guard incognitoSpaces.contains(where: { $0.spaceId == spaceId }),
              !slots.contains(where: { $0.windowController(for: spaceId) != nil }) else { return }
        removeIncognitoSpaceDescriptor(spaceId)
    }

    /// Drops the runtime record of an Incognito Space and republishes the
    /// strip. Its per-Space theme override is cleared too — the id is
    /// runtime-only, so a leftover entry could never be read again.
    private func removeIncognitoSpaceDescriptor(_ spaceId: String) {
        guard incognitoSpaces.contains(where: { $0.spaceId == spaceId }) else { return }
        incognitoSpaces.removeAll { $0.spaceId == spaceId }
        if themeId(forSpaceId: spaceId) != nil {
            setTheme(forSpaceId: spaceId, themeId: nil)
        }
        refreshIncognitoSpacePresence()
        pushSpaceStateToChromium()
    }

    /// Closes every slot's window for the Incognito Space `spaceId`,
    /// retreat-first for slots currently showing it. The mechanics mirror
    /// `deleteSpace`'s two loops — see the comments there for why the
    /// visible window's close must wait for the retreat to settle
    /// (`onSwapSettled`) and why windows are evicted before closing (a
    /// window-driven close would cascade the whole slot shut).
    @MainActor
    private func closeIncognitoSpaceWindows(spaceId: String) {
        let retreatingSlots = slots.filter { $0.activeSpaceId == spaceId }
        for slot in retreatingSlots {
            slot.activate(spaceId: LocalStore.defaultSpaceId) { [weak slot] in
                guard let slot,
                      let controller = slot.windowController(for: spaceId) else { return }
                guard slot.visibleController !== controller else {
                    AppLogWarn("[SpaceManager] close Incognito: not closing its window — still visible (retreat did not complete)")
                    return
                }
                slot.evictWindow(for: spaceId)
                controller.window?.close()
            }
        }
        for slot in slots where !retreatingSlots.contains(where: { $0 === slot }) {
            guard let controller = slot.windowController(for: spaceId) else { continue }
            guard slot.visibleController !== controller else { continue }
            slot.evictWindow(for: spaceId)
            controller.window?.close()
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
        restoreReattachDeadline = nil
        pendingProfileChangeReopens.removeAll()
        // Incognito Spaces are session-scoped; sign-out ends them with
        // everything else.
        incognitoSpaces.removeAll()
        // spaces is now empty, so this also clears the "Open link as" submenu.
        pushSpaceStateToChromium()
    }

    private func handleURLRulesUpdate(_ rules: [SpaceURLRule]) {
        cachedURLRules = rules
        pushRoutingTableToChromium()
    }

    private func handleSpacesUpdate(_ storeSpaces: [SpaceModel]) {
        // Strip any synthetic entry from the input first: callers like
        // `handleLoginCompleted` can fall back to re-feeding `self.spaces`,
        // which already carries the appended Incognito Spaces — without this
        // the append below would duplicate them. Also keeps a stray persisted
        // row under an incognito id (never written by this code) from
        // shadowing a synthetic Space.
        var updated = storeSpaces.filter { !Self.isIncognitoSpaceId($0.spaceId) }
        lastStoreSpaces = updated
        // Every live Incognito Space joins the list at its runtime position —
        // after all user Spaces (in ordinal order) until it's dragged,
        // clamped in case Spaces were deleted since. Because they flow
        // through `spaces` (and thus `validIds`), a slot sitting on one
        // survives unrelated store writes; on close its id drops out of
        // `validIds` and the reconciliation below switches those slots back
        // to a real Space.
        for descriptor in incognitoSpaces.sorted(by: {
            ($0.sortIndex ?? Int.max, $0.ordinal) < ($1.sortIndex ?? Int.max, $1.ordinal)
        }) {
            let index = min(max(descriptor.sortIndex ?? updated.count, 0), updated.count)
            updated.insert(makeIncognitoSpace(descriptor: descriptor, sortOrder: index), at: index)
        }
        spaces = updated
        let validIds = Set(updated.map(\.spaceId))

        // Reconcile each slot: if its active Space has been deleted out
        // from under it, fall back to the persisted default (still valid)
        // or the first known Space. Slots that are still on a valid Space
        // are left alone. Agent and Incognito Spaces are skipped as
        // fallbacks (`isAutomaticSwitchTarget`): deleting a watched agent
        // Space must land the user on a regular Space, not the next agent
        // Space or Incognito. The unfiltered first Space stays as the last
        // resort so a degenerate list still resolves somewhere.
        let fallback: String? = {
            if let restored = persistedActiveSpaceId,
               let restoredModel = updated.first(where: { $0.spaceId == restored }),
               isAutomaticSwitchTarget(restoredModel) {
                return restored
            }
            return (updated.first(where: isAutomaticSwitchTarget) ?? updated.first)?.spaceId
        }()

        // Gate on login: before login, windows are dangling and not yet in any
        // slot's `windowsBySpaceId`, so `activate`'s spawn guard can't see them
        // and would spawn a duplicate empty window for a Space that already owns
        // one (stray windows after a User-Data reset + re-login).
        // `handleLoginCompleted` re-runs this once windows are registered.
        if AuthManager.shared.checkLoginStatusOnChromiumLaunch() {
            for slot in slots {
                // A slot mid-cascade is on its way out: activating a fallback
                // would respawn a window into it and fight the teardown. Hit
                // when an Incognito Space is reaped while its slot's
                // window-driven cascade is still draining.
                if slot.isTearingDown {
                    continue
                }
                if let current = slot.activeSpaceId, validIds.contains(current) {
                    continue
                }
                if let fallback {
                    slot.activate(spaceId: fallback)
                } else {
                    slot.clearActiveSpace()
                }
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

    /// The last REGULAR Space (not agent, not Incognito) this slot surfaced.
    /// This is where a deletion retreat returns the user when the Space they
    /// are standing on goes away: a completed agent task must land them back
    /// on the Space they came from, not the global default. Updated wherever
    /// the slot surfaces a Space (`activate`, external-switch adoption);
    /// ephemeral Spaces are skipped so watching one never redirects the
    /// retreat.
    private(set) var lastRegularSpaceId: String?

    /// Bumped to ask this window's Spaces strip to open the icon/emoji picker for
    /// the active Space, anchored below its icon. Driven by the tab-area menu's
    /// "Change Icon…" item, which has no view of its own to anchor a popover.
    @Published var iconPickerRequestToken: Int = 0

    func requestIconPicker() {
        iconPickerRequestToken &+= 1
    }

    /// True while this window's inline "Create a Space" overlay is open in the
    /// sidebar. The Spaces strip stays visible above the form for reference and
    /// observes this to disable pip clicks — switching Spaces would swap the
    /// form's window away — while keeping the hover info card live (see
    /// `SpacesStripView.spacePip` / `isHoverCardPresented`).
    @Published var isCreatingSpace: Bool = false

    /// The Space the user just deliberately switched to by clicking or picking
    /// it. The interaction dismisses its hover card, and the card must stay
    /// down while the pointer rests on that pip — including in the TARGET
    /// Space window's strip, a different view instance whose fresh hover would
    /// otherwise re-present the card right after the swap (a
    /// disappear-then-reappear blink). Lives on the slot because it must
    /// survive that window hand-off. Armed via `suppressHoverCard(spaceId:)`
    /// (so the timestamp is recorded) by every deliberate-switch affordance: a
    /// sidebar pip click, the horizontal chip's click (just before its
    /// switcher menu pops), and any switcher-menu pick — the chip's menu, the
    /// menu-bar Spaces menu, and the sidebar's "…" overflow menu, which all
    /// share `activateSpaceFromMenu`. Cleared when the pointer leaves the pip
    /// in the visible window's strip, moves onto another pip, or re-enters the
    /// clicked pip past the hand-off window (see `SpacesStripView` and
    /// `isHoverCardSuppressionStale`).
    @Published var hoverCardSuppressedSpaceId: String?

    /// When the suppression was armed, driving `isHoverCardSuppressionStale`.
    private var hoverCardSuppressedAt: Date?

    /// How long after the click an enter on the clicked pip can still be the
    /// window hand-off's own re-enter rather than the user coming back. The
    /// target strip's hover tracking comes up with the swap animation
    /// (0.3–0.4s); the margin past that is kept tight because a real
    /// move-out during the animation is ignored by the exit guard (its exit
    /// comes from the leaving window's strip), so this window is also how
    /// long a quick return to the pip can be wrongly swallowed.
    private static let hoverCardSuppressionHandOffWindow: TimeInterval = 0.6

    /// True once the suppression is old enough that a fresh enter on the
    /// clicked pip must be a genuine re-hover, not the swap hand-off. The
    /// strip lifts the suppression on such an enter — without this, a pointer
    /// that left the pip with no delivered hover-exit (moved away
    /// mid-animation before the target strip ever tracked it, or `.onHover`
    /// dropped the exit) would strand the suppression and silently swallow
    /// that pip's next hover card.
    var isHoverCardSuppressionStale: Bool {
        guard hoverCardSuppressedSpaceId != nil, let hoverCardSuppressedAt else { return false }
        return Date().timeIntervalSince(hoverCardSuppressedAt) > Self.hoverCardSuppressionHandOffWindow
    }

    /// Arms the click suppression for `spaceId` and records when, so a later
    /// enter on that pip can tell the swap's hand-off from a genuine re-hover.
    func suppressHoverCard(spaceId: String) {
        hoverCardSuppressedSpaceId = spaceId
        hoverCardSuppressedAt = Date()
    }

    /// True while the pointer is over the Spaces strip's row, revealing the
    /// strip's trailing add button. Lives on the slot because a Space switch
    /// swaps in a different window's strip — a fresh view instance whose local
    /// hover state would start false and blink the "+" off and back on while
    /// the pointer never left the row. `.onHover` alone cannot maintain this
    /// flag: the leaving window's strip receives a spurious hover-exit when it
    /// orders out at the end of the swap (the pointer never moved), while a
    /// genuine mid-swap move-off is delivered only to that same strip — or
    /// dropped outright. So exits are verified against the real pointer
    /// (`stripRowContainsPointer()`), and the watchdog below clears the flag
    /// once the pointer has actually left the row.
    @Published var isStripRowHovered: Bool = false {
        didSet {
            guard oldValue != isStripRowHovered else { return }
            if isStripRowHovered {
                startStripRowPointerWatchdog()
            } else {
                stopStripRowPointerWatchdog()
            }
        }
    }

    /// Whether the real pointer (`NSEvent.mouseLocation`) is inside the
    /// visible window's strip row right now — the authoritative signal
    /// `.onHover` is not (see `SpaceHoverTooltipController.pointerWatchdog`
    /// for the same technique). The row view is resolved from
    /// `visibleController` on EVERY call (same UI-chain the vertical swap's
    /// band snapshot uses) rather than registered once by whichever strip
    /// last joined a window: hover events come from the visible strip's own
    /// tracking area, so the geometry they are verified against must come
    /// from that same window — a hidden sibling's rect goes stale the moment
    /// the visible sidebar is resized or the window is moved (slot windows
    /// are only re-aligned at swap time) and would veto genuine hovers.
    /// Nil when no row is resolvable (incognito, previews, early bring-up):
    /// no authority, callers fall back to trusting the delivered event. The
    /// hair of outward inset keeps sub-pixel jitter at the row's edge from
    /// reading as "left".
    func stripRowContainsPointer() -> Bool? {
        guard let view = activeStripRowView(),
              let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow).insetBy(dx: -2, dy: -2)
        return screenRect.contains(NSEvent.mouseLocation)
    }

    /// The strip row actually presenting in the visible window. While the
    /// floating sidebar panel is up, the docked sidebar is collapsed — its
    /// row is out of the hierarchy (or zero-width), and verifying hovers
    /// against it would veto genuine floating-strip hovers — so the floating
    /// panel's row is the authority then; the docked sidebar's row otherwise.
    private func activeStripRowView() -> NSView? {
        guard let split = visibleController?.mainSplitViewController else { return nil }
        let webContent = split.webContentContainerViewController
        if let panel = webContent.floatingSidebarContainerView, panel.isHidden == false,
           let floatingRow = webContent.floatingSidebarViewController?.spacesStripRowView {
            return floatingRow
        }
        return split.sidebarViewController.spacesStripRowView
    }

    /// The sidebar surface a vertical Space switch should animate on in
    /// `controller`'s window: the floating panel while it is up (the docked
    /// sidebar is collapsed then, so its band is zero-sized and snapshots
    /// would come back nil), the docked sidebar otherwise. Same
    /// pointer-vs-presenting reasoning as `activeStripRowView`.
    private func spaceSwitchSurface(of controller: MainBrowserWindowController) -> any SpaceSwitchBandSurface {
        let webContent = controller.mainSplitViewController.webContentContainerViewController
        if let panel = webContent.floatingSidebarContainerView, panel.isHidden == false,
           let floating = webContent.floatingSidebarViewController {
            return floating
        }
        return controller.mainSplitViewController.sidebarViewController
    }

    /// Clears `isStripRowHovered` once the pointer actually leaves the row,
    /// independent of `.onHover` exit delivery: mid-swap the only strip
    /// tracking the row belongs to the leaving window (whose exits cannot be
    /// told apart from the spurious order-out one by event alone), and a fast
    /// leave can drop the exit entirely. Runs only while the flag is true;
    /// same 0.1s/`.common` cadence as the tooltip pointer watchdog. The flip
    /// animates via the strip's `.animation(_:value:)` on the add button.
    private var stripRowPointerWatchdog: Timer?

    /// Consecutive watchdog ticks that found the pointer outside the row.
    /// The row's screen rect lies for a beat while a spawned sibling window
    /// surfaces (observed: the rect sits ~17.5pt lower until
    /// `makeKeyAndOrderFrontHidingSlotTabBar`'s tab-bar hide settles the
    /// layout), so a single outside reading must never clear the flag — only
    /// a sustained one may.
    private var stripRowOutsideTickCount = 0
    private static let stripRowOutsideTicksToClear = 3

    private func startStripRowPointerWatchdog() {
        guard stripRowPointerWatchdog == nil else { return }
        stripRowOutsideTickCount = 0
        // `.common` mode so it keeps firing through scroll/resize tracking loops.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.stripRowContainsPointer() == false else {
                self.stripRowOutsideTickCount = 0
                return
            }
            self.stripRowOutsideTickCount += 1
            guard self.stripRowOutsideTickCount >= Self.stripRowOutsideTicksToClear else { return }
            self.isStripRowHovered = false
        }
        RunLoop.main.add(timer, forMode: .common)
        stripRowPointerWatchdog = timer
    }

    private func stopStripRowPointerWatchdog() {
        stripRowPointerWatchdog?.invalidate()
        stripRowPointerWatchdog = nil
        stripRowOutsideTickCount = 0
    }

    /// AppKit tab-group identity for every Chromium NSWindow hosted by this
    /// slot. This keeps all Space windows for one user-perceived window in
    /// the same native tab group, so AppKit owns frame/fullscreen desktop
    /// affinity while `SpaceWindowSlot` still owns Space selection and
    /// animations.
    private let tabbingIdentifier = "phi.space.slot.\(UUID().uuidString)"

    /// Whether this slot's visible window is currently in native macOS
    /// fullscreen. Maintained from the will-enter / will-exit fullscreen hooks
    /// (`windowFullScreenStateChanged`) rather than read from a live styleMask:
    /// the restore snapshot can be written during the will-enter callback,
    /// before AppKit has flipped the styleMask. Persisted in
    /// `slotsRestoreSnapshot` so the slot can reopen fullscreen next launch.
    private var isFullScreen = false

    /// Set when this slot is recreated for a snapshot entry that was fullscreen
    /// last session. Once `reconcileRestoreVisibility` has surfaced the active
    /// window the slot re-enters fullscreen on it exactly once, then clears
    /// this. See `applyPendingRestoreFullScreen`.
    private var pendingRestoreFullScreen = false

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
            updateWindowsMenuExclusion()
            // The Space→window routing map reports only the visible window per
            // slot (see `SpaceManager.currentSpaceWindowMap`), so re-push it
            // whenever the visible Space changes — otherwise the C++ router
            // would keep resolving the previously-visible window for a now-hidden
            // Space and surface it directly instead of routing through the slot.
            manager?.pushSpaceStateToChromium()
        }
    }

    /// Set while a window-driven slot close is cascading its windows shut,
    /// one per runloop turn, via `cascadeCloseRemainingWindows`. While set,
    /// each window's `unregisterWindow` just drops it from the map instead of
    /// re-running the hand-off/cascade logic, so the controlled sequence owns
    /// the order and timing. Serializing is what makes the teardown reliable:
    /// closing several windows of one native tab group in a single
    /// synchronous loop let AppKit's tab-bar selection promotion drop a
    /// programmatic `close()`, stranding a background Space with live tabs.
    private var isCascadingSlotClose = false

    /// True while a window-driven close is cascading this slot's windows
    /// shut. Read by `SpaceManager.handleSpacesUpdate`'s reconciliation so a
    /// Space removal landing mid-cascade (an Incognito Space reaped as its
    /// windows close) doesn't respawn a window into a dying slot.
    var isTearingDown: Bool { isCascadingSlotClose }

    /// windowId → spaceId we asked Chromium to spawn that window for, for
    /// THIS slot. `activate(spaceId:)` populates this synchronously right
    /// after calling `bridge.createBrowserWithWindowType` so the asynchronous
    /// `mainBrowserWindowCreated` callback can tag the resulting window
    /// correctly — even if the user has clicked a different Space pip in the
    /// gap between request and callback.
    private var pendingSpawnSpaceIdByWindowId: [Int: String] = [:]

    /// spaceIds this slot has a spawn in flight for. Unlike
    /// `pendingSpawnSpaceIdByWindowId` (keyed by a windowId that only exists
    /// AFTER `createBrowser` returns), this is set BEFORE the async
    /// `ensureProfileLoaded` + `createBrowser`, so it can gate a repeat
    /// activation of the same Space during that gap — the window when a second
    /// pip click would otherwise queue a duplicate spawn (see `activate`'s
    /// spawn path). Drained in `registerWindow` (success) and every spawn bail.
    private var pendingSpawnSpaceIds: Set<String> = []

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

    /// windowId → titlebar accessory KVO. AppKit recreates the native window
    /// tab bar as a titlebar accessory when tab-group selection changes; remove
    /// it synchronously as it appears to avoid a one-frame flash.
    private var tabBarAccessoryObservationsByWindowId: [Int: NSKeyValueObservation] = [:]

    /// windowId → occlusion-state observation, installed only on agent-Space
    /// windows. An agent-Space window must stay off screen while it isn't the
    /// slot's surfaced Space, but Chromium orders it front whenever its
    /// WebContents grabs focus (e.g. on navigation) — a bare `orderFront` that
    /// fires no key notification, so `handleWindowDidBecomeKey` never sees it.
    /// Occlusion DOES change when a window goes off→on screen, so this catches
    /// every surfacing path and pushes the window straight back out.
    private var agentOcclusionObservationsByWindowId: [Int: NSObjectProtocol] = [:]

    /// Armed when `handleWindowDidBecomeKey` suppresses a spurious key on a
    /// hidden agent-Space (or mid-deletion) window — i.e. whenever key status
    /// is known to be parked on a window the user never surfaced. While armed,
    /// a key change to any window other than the slot's on-screen one is
    /// AppKit fallout, not a switch: the parked window losing key (Chromium
    /// hiding it, or the deferred re-hide) makes AppKit promote a successor
    /// itself, and with every slot window sharing one native tab group that
    /// pick can be a HIDDEN sibling. Adopting it as an external switch lands
    /// the user on a Space they never chose — observed as the agent-handoff
    /// "wrong Space" yank, where key escaped to a sibling within one busy
    /// main-thread turn, faster than any deferred re-key could run. Disarmed
    /// when the visible window regains key; time-boxed by
    /// `agentKeyFalloutWindow` so a genuine external switch (URL-rule route)
    /// arriving later is never refused.
    private var agentKeyFalloutArmedAt: Date?

    /// How long after a suppressed spurious key the fallout guard above stays
    /// armed. Observed fallout lands within ~100ms; the margin covers busy
    /// main-thread turns. Kept short so a coincidental legitimate external
    /// switch is refused for at most this long.
    private static let agentKeyFalloutWindow: TimeInterval = 3.0

    /// Space IDs whose imminent window close is driven by the user
    /// closing the last tab in the active Space via the tab-row ✕
    /// button, not by closing the window itself. Populated by
    /// `markTabDrivenClose` from `Tab.close()` just before dispatching
    /// `IDC_CLOSE_TAB` when only one tab remains; drained by
    /// `unregisterWindow` to decide whether to switch to a sibling
    /// Space (tab-driven) or cascade-close every Space (window-driven,
    /// the default). Note ⌘W is intentionally NOT tagged: it is treated
    /// as window-driven so it tears the whole slot down like ⇧⌘W. In an
    /// Incognito Space neither last-tab path gets this far — both are
    /// intercepted up front and routed into the confirmed Space teardown
    /// (`SpaceManager.requestCloseIncognitoSpace`) instead of dispatching
    /// the close.
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

    /// Post-swap frame pin. When a switch/spawn surfaces a window, Chromium
    /// asynchronously re-applies that window's stale *creation* bounds a few
    /// hundred ms later, clobbering the position the swap set — the user-visible
    /// "jump back to where the window was before I moved it". The user's drag
    /// updates the live NSWindow frame (and our `lastKnownFrame`) but never
    /// reaches whatever stored bounds Chromium re-applies on re-show, so a
    /// one-shot re-assert at surface time is simply too early to win.
    ///
    /// While armed, the frame observer holds the surfaced window at this frame:
    /// a programmatic reposition (Chromium's stale re-apply — no mouse button
    /// held) is reverted and the pin then releases, having served its purpose;
    /// a user drag (mouse held) instead moves the pin *with* the user and keeps
    /// it armed, so a re-apply that lands mid/post-drag still snaps back to the
    /// user's chosen spot. This is event-driven rather than time-bounded: it
    /// waits for the actual re-apply however late it lands, and never fights a
    /// deliberate drag. Nil when disarmed.
    private var pinnedFrame: NSRect?

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

    /// True while a Space-switch animation is mid-flight — the horizontal
    /// window slide (`isAnimatingWindowSlide`) or the vertical sidebar push-in
    /// (`verticalSwapCancel` stays armed until its deferred swap finalizes;
    /// `performExternalVerticalSlide` arms it too). `activate` reads this to
    /// drop further *user-initiated* switches so a second trigger — pip/icon
    /// click, keyboard shortcut, swipe, or menu selection — can't interrupt or
    /// stack on the animation already running. Both flags are set synchronously
    /// within the initiating `activate` call, so the next event-loop trigger
    /// always observes them.
    private var isSwitchAnimationInFlight: Bool {
        isAnimatingWindowSlide || verticalSwapCancel != nil
    }

    /// Animation timing for the cross-Space slide. Routed through
    /// `PhiPreferences` so the sidebar tint cross-fade in vertical layout
    /// stays in sync with this slide — both pick up the debug override
    /// when present.
    private static var swapAnimationDuration: TimeInterval {
        PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration()
    }

    /// Grace period added past `swapAnimationDuration` before a vertical swap
    /// force-settles itself. The vertical paths finalize off `NSAnimationContext`'s
    /// completion handler, which can be dropped when the window is pushed to
    /// another macOS Space (or the app is occluded) mid-slide — stranding the
    /// band snapshot on the sidebar. A settled animation always fires its real
    /// completion within `duration`, so this margin only ever covers a lost one.
    private static let swapFinalizeFallbackMargin: TimeInterval = 0.5

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
    func activate(spaceId: String, leavingSnapshotOverride: NSImage? = nil, animated: Bool = true, userInitiated: Bool = false, onSwapSettled: (() -> Void)? = nil) {
        // A Space-switch animation is treated as atomic: once it starts, further
        // user-initiated switches (pip/icon click, keyboard shortcut, swipe,
        // menu selection) are dropped until it settles, so a second trigger
        // can't interrupt or stack on the animation already in progress.
        // Programmatic switches (deletion retreat, profile-change respawn, tab
        // move, instant `animated: false` presents) pass `userInitiated: false`
        // and always run — they must, to keep the slot consistent. Re-activating
        // the current Space is a no-op and never gated.
        AppLogInfo("[SpaceWindowSlot] activate(\(spaceId)) from=\(activeSpaceId ?? "nil") userInitiated=\(userInitiated) animated=\(animated)")
        if userInitiated, spaceId != activeSpaceId, isSwitchAnimationInFlight {
            AppLogInfo("[SpaceWindowSlot] activate(\(spaceId)) dropped: switch animation in flight")
            return
        }
        isPerformingActivate = true
        defer { isPerformingActivate = false }
        guard let manager,
              manager.spaces.contains(where: { $0.spaceId == spaceId }) else {
            AppLogWarn("[SpaceWindowSlot] activate ignored: unknown spaceId \(spaceId)")
            return
        }

        // Agent Space pre-hook. An agent Space's hidden window is spawned into a
        // single slot; if the user switches to it from a DIFFERENT slot, adopt
        // the existing hidden window here instead of spawning a second one (a
        // Space maps 1:1 to a Chromium window). Then mark the surface so the
        // agent overlay mounts in watch mode. `windowsBySpaceId` is per-slot, so
        // only adopt when another slot currently owns it. Runs on the main
        // thread (all activation is UI-driven), so the main-actor manager is
        // reachable synchronously.
        MainActor.assumeIsolated {
            guard AgentSpaceManager.shared.isAgentSpace(spaceId) else { return }
            if windowsBySpaceId[spaceId] == nil {
                for other in manager.slots where other !== self {
                    if let adopted = other.evictWindow(for: spaceId) {
                        registerWindow(adopted, for: spaceId)
                        break
                    }
                }
            }
            AgentSpaceManager.shared.userDidSurface(spaceId: spaceId)
        }

        let previousSpaceId = activeSpaceId

        // Agent Space post-hook: leaving an agent-owned Space orders its window
        // out, and macOS occlusion then marks its WebContents hidden. Have the
        // manager re-assert agent-mode visibility shortly after the swap so the
        // agent's renderer keeps painting off screen.
        if let previousSpaceId, previousSpaceId != spaceId {
            MainActor.assumeIsolated {
                AgentSpaceManager.shared.userDidLeave(spaceId: previousSpaceId)
            }
        }

        // Vertical push-in reads the leaving Space's sidebar band and color
        // BEFORE `activeSpaceId` flips below: the SpacesStrip name and the tint
        // gradient are bound to the shared slot, so capturing afterward would
        // bake in the TARGET Space (the name would change before the animation
        // and the background wouldn't transition).
        let isVerticalSwitch = spaceId != activeSpaceId
            && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let verticalLeavingBand: NSImage? = isVerticalSwitch
            ? visibleController.flatMap { spaceSwitchSurface(of: $0).snapshotSpaceSwitchBand() }
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
        recordRegularSpace(spaceId)

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
                    // Hold this position against Chromium's late re-apply of the
                    // window's stale creation bounds after it surfaces. A one-shot
                    // re-assert is too early; the pin reverts that re-apply
                    // whenever it lands. See `pinnedFrame`. Not armed in
                    // fullscreen: the inherited frame is the screen-sized rect
                    // there, no didMove fires in fullscreen to consume the pin,
                    // and a stale pin would then "revert" AppKit's windowed-frame
                    // restore on fullscreen exit, leaving the window screen-sized.
                    if !slotHasFullScreenWindow {
                        pinnedFrame = inheritedFrame
                    }
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
                    // The floating sidebar panel is per-window: when the
                    // switch is driven from the leaving window's open panel
                    // (a pip click in its Spaces strip), the target would
                    // surface with its own panel hidden and the sidebar
                    // would vanish from under the pointer. Present the
                    // target's panel before it fronts — same "reads as one
                    // window" continuity as the sidebar sync above — at the
                    // leaving panel's width, so the panel doesn't jump to the
                    // target window's own cached width mid-switch. Must run
                    // after syncSidebar: showFloatingSidebar() is gated on
                    // the target's sidebarCollapsed, which that sync just set.
                    let previousWebContent = previous.mainSplitViewController.webContentContainerViewController
                    if previousWebContent.floatingSidebarContainerView?.isHidden == false {
                        let targetWebContent = target.mainSplitViewController.webContentContainerViewController
                        targetWebContent.lastKnownSidebarWidth = previousWebContent.currentFloatingWidth
                        targetWebContent.updateFloatingSidebarWidth()
                        targetWebContent.showFloatingSidebar()
                    }
                }
                // Switching into a tab-less Space (its window outlived a
                // last-tab close in placeholder mode) should greet the user
                // with a usable tab, not the placeholder. Create it before
                // the swap so the entering window surfaces on the new tab
                // page. Re-activating the already-visible Space is excluded
                // (`target !== previous`): the placeholder after closing the
                // last tab is deliberate, only a real switch replaces it.
                // Agent Spaces are also excluded: the agent owns that
                // window's tabs (the spawn path seeds one), and a tab
                // injected by a user surfacing to watch would flip the
                // agent's active tab out from under it.
                if target.browserState.tabs.isEmpty,
                   !MainActor.assumeIsolated({
                       AgentSpaceManager.shared.isAgentSpace(spaceId)
                   }) {
                    target.browserState.createQuickLookupTab()
                }
                // After a cold-launch restore into fullscreen,
                // `reconcileRestoreVisibility` hard-`orderOut`s the sibling
                // Space windows, which AppKit pops out of this slot's native
                // tab group. The swap below assumes the target is still a tab
                // in the fullscreen window's group — surfacing a detached,
                // normal-styleMask window while the leaving window owns its own
                // macOS fullscreen Space makes macOS spawn a blank fullscreen
                // Space (the black workspace in Mission Control). Rebuild the
                // group first, anchored on the fullscreen window
                // (`slotTabGroupAnchor`) and keeping the leaving window selected
                // so the slide animation still reads it as front, so the target
                // re-enters the fullscreen group and the swap selects a tab in
                // the same Space instead of creating a new one.
                if slotHasFullScreenWindow {
                    syncSlotTabGroup(selecting: previous?.window)
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
                    // front the target and hide the leaving window in the same
                    // turn, then fire `onSwapSettled` with the target already
                    // on screen and `visibleController` repointed — so a
                    // post-swap close (e.g. `deleteSpace`) lands off-screen.
                    makeKeyAndOrderFrontHidingSlotTabBar(target.window)
                    orderOutIfNotTabbedWithTarget(previous?.window, targetWindow: target.window)
                    visibleController = target
                    onSwapSettled?()
                }
            }
            return
        }

        // Spawn path — no live window in this slot for this Space yet.
        //
        // Guard against a second activation of the SAME Space while its first
        // spawn is still in flight. The first cross-profile activation of a
        // session awaits an async `ensureProfileLoaded` (~100–300ms); during
        // that gap `activeSpaceId` is already flipped to the target (so the
        // animation gate above passes) and `windowsBySpaceId[spaceId]` is still
        // nil (so the existing-window branch above misses), leaving a repeat
        // pip click free to queue a SECOND spawn. Both completions would call
        // `createBrowser`, and `registerWindow` would overwrite the first
        // window's map entry — orphaning a live window the slot can no longer
        // hide or close. Bail here; the in-flight spawn will surface the Space.
        if pendingSpawnSpaceIds.contains(spaceId) {
            AppLogInfo("[SpaceWindowSlot] activate(\(spaceId)): spawn already in flight, ignoring repeat")
            return
        }
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
        // An Incognito Space spawns its own window type instead: Chromium
        // ignores the profileId and binds the Browser to the shared
        // off-the-record profile all Incognito Spaces live on.
        let isIncognitoSpace = SpaceManager.isIncognitoSpaceId(spaceId)
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
            let dict = bridge.createBrowser(withWindowType: isIncognitoSpace ? .incognitoSpace : .normal,
                                            profileId: isIncognitoSpace ? nil : targetProfileId)
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
                self.pendingSpawnSpaceIds.remove(spaceId)
                return
            }
            guard let windowIdNumber = dict["windowId"] as? NSNumber else {
                AppLogWarn("[SpaceWindowSlot] createBrowserWithWindowType returned no windowId")
                self.pendingSpawnSpaceIds.remove(spaceId)
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
            // A spawned Browser starts with zero tabs, so the Space would
            // surface as an empty window — UNLESS something repopulates it.
            // Two repopulators exist:
            //   1. A profile-change reopen queued for this (Space, profile)
            //      pair — replay those URLs immediately.
            //   2. Chromium session restore. After a window-driven close
            //      cascades the slot shut, SessionService saves the session;
            //      re-entering a Space spawns a fresh Browser into which
            //      Chromium then replays the saved tabs (kind=restore) ~tens
            //      of ms later. The window is NOT flagged restored
            //      (restoredFromWindowId==0), so it lands here, not on the
            //      restore path.
            // Because restore is asynchronous, a synchronous tabs.isEmpty check
            // can't see it — creating a quick-lookup tab now leaves a spurious
            // new tab page beside the restored tabs (the close-recover double).
            // So defer the new-tab page past the restore burst and create it
            // only if the Space still has nothing in its normal tab list. Any
            // real tab arriving first (restore or otherwise) cancels it.
            // Routed by windowId rather than the controller's BrowserState so
            // the rare async-registration path is covered too.
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
                    let wid = windowIdNumber.int64Value
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self,
                              let state = self.windowsBySpaceId[spaceId]?.browserState,
                              state.normalTabs.isEmpty else { return }
                        // Off-the-record windows render the NATIVE new-tab
                        // page: mark the arriving tab before creating it,
                        // exactly like `newBrowserTab` does. Without this the
                        // Incognito Space's first tab shows the raw web
                        // chrome://newtab, which is blank for its OTR profile.
                        if state.isIncognito {
                            state.enqueueNativeNTP()
                        }
                        ChromiumLauncher.sharedInstance().bridge?
                            .createQuickLookupTab(withWindowId: wid, customGuid: nil)
                    }
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
                    self.orderOutIfNotTabbedWithTarget(previous?.window, targetWindow: registered.window)
                    // The spawned target is up and the leaving window is
                    // hidden — let a post-swap close (e.g. `deleteSpace`) run
                    // now that it lands off-screen. No-op for ordinary
                    // switches, which pass no handler.
                    onSwapSettled?()
                }
            }
        }
        // Mark the spawn in flight across the (possibly async) profile load and
        // window creation, so a repeat activation of this Space is gated above.
        // Drained by `registerWindow` on success and by every bail below.
        pendingSpawnSpaceIds.insert(spaceId)
        // Lazy-load the Space's profile before spawning. Completion fires
        // synchronously when the profile is already in memory (the common
        // case), so this is free for warm switches. First cross-profile
        // activation of the session pays the load cost (~100–300ms) — the
        // deferred orderOut inside `spawn` keeps the previous window on
        // screen until the new window paints, hiding that latency.
        if isIncognitoSpace {
            // The Incognito Space loads through its own path: its synthetic
            // wire profileId names no on-disk profile, so
            // `ensureProfileLoaded` would refuse it. This ensures the Space's
            // parent profile is in memory; the OTR itself is materialized
            // synchronously at spawn.
            bridge.ensureIncognitoSpaceProfileLoaded { [weak self] success in
                guard success else {
                    AppLogWarn("[SpaceWindowSlot] ensureIncognitoSpaceProfileLoaded failed; not spawning")
                    self?.pendingSpawnSpaceIds.remove(spaceId)
                    return
                }
                spawn()
            }
        } else if let pid = targetProfileId, !pid.isEmpty {
            bridge.ensureProfileLoaded(pid) { [weak self] success in
                guard success else {
                    // Spawning anyway would hand the Space a window on
                    // whatever profile Chromium substitutes — another
                    // profile's pinned tabs inside this Space. The bridge
                    // refuses unresolved profiles too (returns nil); bail
                    // here so the previous window simply stays on screen.
                    AppLogWarn("[SpaceWindowSlot] ensureProfileLoaded failed for \(pid); not spawning")
                    self?.pendingSpawnSpaceIds.remove(spaceId)
                    return
                }
                spawn()
            }
        } else {
            spawn()
        }
    }

    /// Spawns an agent Space's Chromium window WITHOUT surfacing or activating
    /// it. Reuses the same spawn primitives as `activate` (the pendingSpawn
    /// gate, `ensureProfileLoaded`, the `currentSpawn` attribution the
    /// coordinator claims, and the deferred quick-lookup tab), but skips the
    /// activeSpaceId flip, persistActiveSpaceId, swap animation, frame
    /// inheritance, and orderOut — the window is created in agent mode
    /// (`createAgentBrowser`), which Chromium never Show()s, so it stays ordered
    /// out until the user switches to its Space. `completion` receives the new
    /// windowId (or nil on failure).
    func spawnHiddenWindow(forSpaceId spaceId: String,
                           completion: @escaping (Int?) -> Void) {
        guard let manager else { completion(nil); return }
        if pendingSpawnSpaceIds.contains(spaceId) {
            AppLogInfo("[SpaceWindowSlot] spawnHiddenWindow(\(spaceId)): spawn already in flight")
            completion(nil)
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("[SpaceWindowSlot] spawnHiddenWindow cannot spawn: bridge unavailable")
            completion(nil)
            return
        }
        let targetProfileId = manager.spaces.first(where: { $0.spaceId == spaceId })?.profileId

        let spawn: () -> Void = { [weak self, weak manager] in
            guard let self = self else { completion(nil); return }
            manager?.currentSpawn = SpaceManager.SpawnContext(
                slot: self,
                spaceId: spaceId,
                inheritedFrame: nil,
                inheritedSidebarWidth: 0,
                inheritedSidebarCollapsed: nil
            )
            let dict = bridge.createAgentBrowser(withProfileId: targetProfileId)
            manager?.currentSpawn = nil
            guard let dict else {
                AppLogWarn("[SpaceWindowSlot] createAgentBrowser returned nil")
                self.pendingSpawnSpaceIds.remove(spaceId)
                completion(nil)
                return
            }
            guard let windowIdNumber = dict["windowId"] as? NSNumber else {
                AppLogWarn("[SpaceWindowSlot] createAgentBrowser returned no windowId")
                self.pendingSpawnSpaceIds.remove(spaceId)
                completion(nil)
                return
            }
            let id = windowIdNumber.intValue
            if !self.contains(windowId: id),
               self.pendingSpawnSpaceIdByWindowId[id] == nil {
                self.pendingSpawnSpaceIdByWindowId[id] = spaceId
            }
            // The agent drives navigation itself, but seed a quick-lookup tab so
            // the window has a live tab for the runtime to bind to, deferred past
            // any session-restore burst exactly like the normal spawn path.
            let wid = windowIdNumber.int64Value
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self,
                      let state = self.windowsBySpaceId[spaceId]?.browserState,
                      state.normalTabs.isEmpty else { return }
                ChromiumLauncher.sharedInstance().bridge?
                    .createQuickLookupTab(withWindowId: wid, customGuid: nil)
            }
            completion(id)
        }

        pendingSpawnSpaceIds.insert(spaceId)
        if let pid = targetProfileId, !pid.isEmpty {
            bridge.ensureProfileLoaded(pid) { [weak self] success in
                guard success else {
                    AppLogWarn("[SpaceWindowSlot] spawnHiddenWindow: ensureProfileLoaded failed for \(pid)")
                    self?.pendingSpawnSpaceIds.remove(spaceId)
                    completion(nil)
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
            if let previousWindow = previous?.window {
                orderOutRearmingMoveToActiveSpace(previousWindow)
            }
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
            makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
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
            self.makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            self.orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
            onSwapSettled?()
        }

        // Animate on whichever sidebar surface each window is presenting —
        // the docked sidebar, or the floating panel while the sidebar is
        // collapsed (a pip click there has `activate` present the target's
        // panel before this runs, so both sides resolve to the same kind).
        let targetSurface = spaceSwitchSurface(of: target)
        let duration = Self.swapAnimationDuration
        guard duration > 0,
              let previousWindow,
              previousWindow.isVisible,
              let previous,
              let leavingImage = leavingBand else {
            presentInstantly()
            return
        }
        let prevSurface = spaceSwitchSurface(of: previous)

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

        let bandFrame = prevSurface.spaceSwitchBandFrame
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
        prevSurface.setSwitchBandContentHidden(true)
        let placeholder = NSImageView(frame: bandFrame)
        placeholder.image = leavingImage
        placeholder.imageScaling = .scaleAxesIndependently
        placeholder.imageAlignment = .alignTopLeft
        placeholder.autoresizingMask = []
        prevSurface.view.addSubview(placeholder, positioned: .above, relativeTo: nil)

        var didFinish = false
        let finalize: () -> Void = { [weak self, weak prevSurface, weak placeholder] in
            guard !didFinish else { return }
            didFinish = true
            if let self {
                // The leaving window can have entered native fullscreen DURING
                // the slide (it stays front for the whole animation, so it owns
                // the green-button click) — after `activate`'s pre-swap group
                // rebuild already ran. The target may then still be detached,
                // and fronting it would surface a stray window over the
                // fullscreen Space. Rebuild the group first, exactly like the
                // pre-swap fullscreen path, so the front below is a tab
                // selection inside the same fullscreen Space.
                if self.slotHasFullScreenWindow {
                    self.syncSlotTabGroup(selecting: previousWindow)
                }
                self.makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            } else {
                targetWindow.makeKeyAndOrderFront(nil)
            }
            self?.orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
            placeholder?.removeFromSuperview()
            self?.activeSidebarOverlay?.cancel()
            prevSurface?.setSwitchBandContentHidden(false)
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
        scheduleVerticalSwapFinalizeFallback(token: token, duration: duration, finalize: finalize)

        // Defer the entering snapshot + slide one runloop so the target
        // sidebar's strip shows the new Space name (bail if superseded).
        DispatchQueue.main.async { [weak self, weak prevSurface] in
            guard let self, self.verticalSwapToken == token, !didFinish,
                  let prevSurface else { return }
            targetSurface.view.layoutSubtreeIfNeeded()
            guard let enteringImage = targetSurface.snapshotSpaceSwitchBand() else {
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
            prevSurface.view.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.activeSidebarOverlay = overlay
            // The overlay's leaving half sits at rest (x=0) exactly where the
            // placeholder was, so removing the placeholder is seamless.
            placeholder.removeFromSuperview()
            // Ramp the whole-window theme AND the sidebar tint in lockstep with
            // the slide so the background transitions source -> target across
            // the same window, landing on the target's colors at the swap.
            self.rampWindowTheme(prevThemeContext, from: sourceTheme, to: targetTheme, duration: duration)
            prevSurface.rampSpaceTint(fromHex: sourceColorHex, toHex: targetColorHex, duration: duration)
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
        scheduleVerticalSwapFinalizeFallback(token: token, duration: duration, finalize: finalize)

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

    /// Force-settles a vertical swap if its `NSAnimationContext` completion is
    /// never delivered. Both vertical paths finalize off that completion, so a
    /// dropped one — as happens when the window is pushed to another macOS Space
    /// (or the app is occluded) mid-slide — would leave `verticalSwapCancel`
    /// armed indefinitely, freezing the band snapshot over the sidebar and
    /// gating every later switch. `finalize` is idempotent (`didFinish`), so
    /// this is a no-op whenever the real completion fired; the token guard keeps
    /// a superseded slide's fallback from touching the one that replaced it.
    private func scheduleVerticalSwapFinalizeFallback(
        token: Int,
        duration: TimeInterval,
        finalize: @escaping () -> Void
    ) {
        let deadline = DispatchTime.now() + duration + Self.swapFinalizeFallbackMargin
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.verticalSwapToken == token else { return }
            finalize()
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
            makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
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
            makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
            onSwapSettled?()
            return
        }

        // Force layout on the target so its content reflects the just-synced
        // shape before we snapshot it. The window is still off-screen here,
        // but AppKit layout is independent of visibility.
        targetContent.layoutSubtreeIfNeeded()

        guard let targetImage = snapshotContent(of: targetContent) else {
            makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
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

        makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
        orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)

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
            makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
            orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)
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

        makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
        orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: targetWindow)

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

    // MARK: - Native window tab group

    /// Marks a Chromium NSWindow as belonging to this slot's native AppKit tab
    /// group. The identifier is slot-scoped so automatic AppKit behavior never
    /// merges windows across user-perceived Phi windows.
    private func configureWindowForSlotTabGroup(_ window: NSWindow) {
        NativeWindowTabBarSuppressor.installIfNeeded()
        window.tabbingIdentifier = tabbingIdentifier
        window.tabbingMode = .preferred
    }

    /// Reconciles every live Space window in this slot into one native tab
    /// group. When the slot is already full screen, keep the existing full
    /// screen window as the grouping anchor; anchoring on a freshly-spawned
    /// normal window makes AppKit tear down the full screen Space before the
    /// new window can join it as a tab.
    private func syncSlotTabGroup(selecting selectedWindow: NSWindow? = nil) {
        let windows = windowsBySpaceId.values.compactMap(\.window)
        guard let anchor = slotTabGroupAnchor(selecting: selectedWindow, in: windows) else { return }

        for window in windows {
            configureWindowForSlotTabGroup(window)
            inheritFullScreenTabEligibility(from: anchor, to: window)
        }

        for window in windows where window !== anchor {
            guard !windowsShareTabGroup(anchor, window) else { continue }
            anchor.addTabbedWindow(window, ordered: .below)
        }

        if let selectedWindow,
           let tabGroup = selectedWindow.tabGroup,
           tabGroup.windows.contains(where: { $0 === selectedWindow }) {
            tabGroup.selectedWindow = selectedWindow
        }
        hideSlotTabBars(in: windows)
    }

    private func slotTabGroupAnchor(selecting selectedWindow: NSWindow?, in windows: [NSWindow]) -> NSWindow? {
        if let visibleWindow = visibleController?.window,
           visibleWindow.styleMask.contains(.fullScreen),
           windows.contains(where: { $0 === visibleWindow }) {
            return visibleWindow
        }

        if let fullScreenWindow = windows.first(where: { $0.styleMask.contains(.fullScreen) }) {
            return fullScreenWindow
        }

        return selectedWindow ?? visibleController?.window ?? windows.first
    }

    /// True when any window in this slot is currently in native macOS
    /// fullscreen. In fullscreen the slot's whole native tab group shares one
    /// macOS Space, so a sibling Space window that has been detached from the
    /// group must be re-attached before it is surfaced (a cold-launch restore
    /// reconcile hard-`orderOut`s siblings, which AppKit pops out of the group
    /// — see `reconcileRestoreVisibility`). Surfacing a still-detached window
    /// while the leaving window owns its own fullscreen Space otherwise makes
    /// macOS spawn a blank fullscreen Space. Consumed by `activate`'s switch
    /// path.
    private var slotHasFullScreenWindow: Bool {
        windowsBySpaceId.values.contains {
            $0.window?.styleMask.contains(.fullScreen) == true
        }
    }


    private func inheritFullScreenTabEligibility(from anchor: NSWindow, to window: NSWindow) {
        guard anchor.styleMask.contains(.fullScreen) else { return }

        var behavior = window.collectionBehavior
        behavior.remove(.fullScreenNone)
        behavior.insert(.fullScreenPrimary)
        // A window grouped into a fullscreen anchor joins that single macOS
        // fullscreen Space. Leaving `.moveToActiveSpace` on it lets a later app
        // activation in another Space (e.g. a second slot's own fullscreen
        // Space) drag it back out, blanking the Space — see
        // `windowFullScreenStateChanged`.
        behavior.remove(.moveToActiveSpace)
        window.collectionBehavior = behavior
    }

    /// Adds or removes `.moveToActiveSpace` across every window in this slot in
    /// response to its visible window entering/leaving native fullscreen.
    /// Forwarded from `MainBrowserWindowController`'s will-enter / will-exit
    /// fullscreen notifications.
    ///
    /// `.moveToActiveSpace` (armed on hidden slot windows — see
    /// `scheduleMoveToActiveSpaceStrip` for the lifecycle) makes macOS pull a
    /// window into the frontmost Space when it is shown or the app activates —
    /// exactly what a hidden sibling needs so it surfaces on the user's
    /// current desktop. But it is destructive for a window that owns its own
    /// native fullscreen Space: once a SECOND user-perceived window enters
    /// fullscreen (its own macOS Space), the next app activation drags this
    /// slot's fullscreen window out of its Space, leaving an empty black
    /// desktop in Mission Control. So a window must not carry
    /// `.moveToActiveSpace` while its slot is in fullscreen. Applied across
    /// the whole slot because its windows share one fullscreen Space (hidden
    /// siblings are re-grouped into it by `syncSlotTabGroup` on the next
    /// switch); the exit hook re-arms the slot's hidden windows. Corrections
    /// for transitions that settle differently than the will-hooks promised
    /// come in through `reconcileFullScreenWithWindowState`.
    func windowFullScreenStateChanged(isFullScreen: Bool) {
        self.isFullScreen = isFullScreen
        // A Space switch's frame pin must not survive a fullscreen transition:
        // armed inside fullscreen it holds the screen-sized rect, no didMove
        // ever fires in fullscreen to consume it, and AppKit's programmatic
        // frame restore on exit looks exactly like the "stale re-apply" the
        // pin exists to revert — snapping the window back to full-screen size.
        pinnedFrame = nil
        for controller in windowsBySpaceId.values {
            guard let window = controller.window else { continue }
            if isFullScreen {
                window.collectionBehavior.remove(.moveToActiveSpace)
            } else if !window.isVisible {
                // Re-arm hidden siblings only. The on-screen window must not
                // carry the flag in steady state — it breaks macOS's
                // per-desktop focus restoration (see
                // `scheduleMoveToActiveSpaceStrip`); a tabbed sibling still
                // stacked on screen is re-armed when the next sweep orders it
                // out.
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
        }
        // Capture the new fullscreen state in the cross-launch snapshot so the
        // slot reopens fullscreen (or not) next launch. The will-enter/exit
        // hooks can fire before AppKit flips the styleMask, so the snapshot
        // reads `isFullScreen` (tracked here) rather than a live styleMask.
        manager?.persistSlotsSnapshot()
        if isFullScreen {
            // Will-enter is a promise, not a fact: AppKit can fail or cancel
            // the enter transition without ever firing will-exit (Chromium's
            // own fullscreen controller handles the same case). Re-derive from
            // the styleMask once the transition has settled — a no-op when the
            // enter completed or the user has already exited again.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fullScreenEnterVerifyDelay) { [weak self] in
                self?.reconcileFullScreenWithWindowState()
            }
        }
    }

    /// How long after a will-enter fullscreen notification the slot verifies
    /// the transition actually landed. AppKit's enter animation settles well
    /// under a second; the margin covers slow machines and displays. A failed
    /// or cancelled enter fires NO will-exit, so without this check the flag —
    /// and everything keyed off it — would stay fullscreen forever.
    private static let fullScreenEnterVerifyDelay: TimeInterval = 3.0

    /// Re-derives `isFullScreen` from the slot windows' live styleMask and, on
    /// a mismatch, routes the correction through `windowFullScreenStateChanged`
    /// — the flag's single writer — so `.moveToActiveSpace` and the restore
    /// snapshot are corrected with it. Only called at transition SETTLE points
    /// (did-enter/did-exit, after a window close, the failed-enter verify):
    /// mid-transition the mask and the will-hooks legitimately disagree, so
    /// this must not run from arbitrary code.
    ///
    /// Heals the two paths that change fullscreen state without a will-exit:
    ///  - closing a fullscreen window (a tab-driven hand-off previously left
    ///    the flag stuck true — siblings kept `.moveToActiveSpace` stripped
    ///    and the snapshot force-restored fullscreen next launch);
    ///  - a failed/cancelled enter transition.
    /// Derived from the surviving windows rather than assumed false because
    /// AppKit can promote a tabbed sibling INTO a dying window's fullscreen
    /// Space — the flag staying true is then correct.
    func reconcileFullScreenWithWindowState() {
        guard isFullScreen != slotHasFullScreenWindow else { return }
        windowFullScreenStateChanged(isFullScreen: slotHasFullScreenWindow)
    }

    /// Marks this slot for fullscreen re-entry after a cold-launch restore. Set
    /// by `SpaceManager.slotForRestoreIndex` for a snapshot entry that was
    /// fullscreen last session; consumed once by `applyPendingRestoreFullScreen`.
    func markPendingRestoreFullScreen() {
        pendingRestoreFullScreen = true
    }

    /// Re-enters native fullscreen on the slot's active window after restore,
    /// if it was fullscreen last session. Runs at most once. The active window
    /// owns the slot's single fullscreen Space; siblings stay normal/hidden and
    /// re-group into it on the next switch (`syncSlotTabGroup`). Letting each
    /// restored window keep its own fullscreen state instead would make macOS
    /// spawn a separate Space per window and orphan the hidden ones — which is
    /// why restore comes back normal first (see Chromium session_restore.cc).
    private func applyPendingRestoreFullScreen(activeWindow: NSWindow) {
        guard pendingRestoreFullScreen, activeWindow.isVisible else { return }
        pendingRestoreFullScreen = false
        guard !activeWindow.styleMask.contains(.fullScreen) else { return }
        // Defer one runloop turn so the just-surfaced window has settled before
        // the fullscreen transition begins; re-check the state at fire time.
        DispatchQueue.main.async { [weak activeWindow] in
            guard let activeWindow,
                  !activeWindow.styleMask.contains(.fullScreen) else { return }
            activeWindow.toggleFullScreen(nil)
        }
    }

    private func makeKeyAndOrderFrontHidingSlotTabBar(_ window: NSWindow?) {
        guard let window else { return }

        hideSlotTabBars()
        if let tabGroup = window.tabGroup,
           tabGroup.windows.count > 1,
           tabGroup.windows.contains(where: { $0 === window }) {
            tabGroup.selectedWindow = window
            hideSlotTabBars(in: tabGroup.windows)
        }
        removeNativeTabBarAccessories(from: window)

        window.makeKeyAndOrderFront(nil)

        removeNativeTabBarAccessories(from: window)
        hideSlotTabBars()
        scheduleMoveToActiveSpaceStrip(for: window)
    }

    /// Drops `.moveToActiveSpace` from a window once it has settled on screen.
    ///
    /// Hidden slot windows carry the flag so that ANY show — a pip switch, a
    /// URL-rule route, Chromium re-surfacing a restored window — lands them on
    /// the user's CURRENT desktop instead of switching desktops back to
    /// wherever they were last shown. But the flag must not stay on the
    /// on-screen window: the window server treats a `.moveToActiveSpace`
    /// window as residing on no particular desktop, so after the user switches
    /// desktops away and back, macOS's per-desktop focus restoration skips it
    /// and the app is left deactivated — the browser visibly "loses focus" on
    /// every desktop round-trip. It is the same window-server behavior that
    /// drags a fullscreen window out of its own Space on app activation (see
    /// `windowFullScreenStateChanged`).
    ///
    /// Deferred one runloop turn so the order-front's move-to-active-space has
    /// been processed first; the `isVisible` guard keeps a superseded switch's
    /// strip from disarming a window that was already hidden (and re-armed) in
    /// the meantime. Re-armed by `orderOutRearmingMoveToActiveSpace` when the
    /// window next goes off screen.
    private func scheduleMoveToActiveSpaceStrip(for window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            window.collectionBehavior.remove(.moveToActiveSpace)
        }
    }

    /// Orders a slot window off screen and re-arms `.moveToActiveSpace` on it
    /// so its next show surfaces on the user's current desktop (see
    /// `scheduleMoveToActiveSpaceStrip` for the full lifecycle). The re-arm is
    /// skipped while the slot owns a fullscreen Space or is about to restore
    /// into one — a window carrying the flag is dragged out of its own
    /// fullscreen Space on the next app activation, blanking it (see
    /// `windowFullScreenStateChanged`); the fullscreen-exit hook re-arms the
    /// slot's hidden windows instead.
    private func orderOutRearmingMoveToActiveSpace(_ window: NSWindow) {
        window.orderOut(nil)
        if !slotHasFullScreenWindow && !pendingRestoreFullScreen {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }

    private func observeNativeTabBarAccessories(for controller: MainBrowserWindowController) {
        guard tabBarAccessoryObservationsByWindowId[controller.windowId] == nil,
              let window = controller.window else {
            return
        }

        tabBarAccessoryObservationsByWindowId[controller.windowId] = window.observe(
            \.titlebarAccessoryViewControllers,
            options: [.new]
        ) { [weak self, weak window] _, _ in
            guard let self, let window else { return }
            self.removeNativeTabBarAccessories(from: window)
        }
        removeNativeTabBarAccessories(from: window)
    }

    /// Hides the previously-visible window once the target is fronted. AppKit is
    /// supposed to drop a tab group's non-selected window for us, but selecting
    /// the target tab alone does NOT reliably hide the leaving window: it stays
    /// stacked directly behind the target and, because the Space sidebar is
    /// translucent, bleeds through as a ghost Space-strip + shadow during and
    /// after a switch. A hard `orderOut` is what reliably drops it — the same
    /// finding `reconcileRestoreVisibility` relies on. It detaches the window
    /// from the native tab group; `registerWindow`/`syncSlotTabGroup` regroup
    /// windows as they resurface, and the ungrouped branch below keeps hiding
    /// the leaving window in the meantime.
    ///
    /// Skipped while the slot owns a macOS fullscreen window: ordering a tab
    /// out from a group that shares a fullscreen Space makes macOS flash a
    /// blank fullscreen workspace (see `slotHasFullScreenWindow`), so there we
    /// keep relying on tab selection.
    private func orderOutIfNotTabbedWithTarget(_ previousWindow: NSWindow?, targetWindow: NSWindow?) {
        hideSlotTabBars()

        // In a shared macOS fullscreen Space, ordering a sibling tab out flashes
        // a blank workspace, so keep relying on native tab selection there — but
        // an ungrouped hand-off window (not part of the group) still needs the
        // explicit hide it always got. Never orderOut a window that is ITSELF
        // fullscreen, though: the leaving window can have entered fullscreen
        // after the swap started (the vertical push-in defers this call to its
        // completion), and ordering it out blanks the fullscreen Space it owns.
        guard !slotHasFullScreenWindow else {
            if let previousWindow,
               !windowsShareTabGroup(previousWindow, targetWindow),
               !previousWindow.styleMask.contains(.fullScreen) {
                orderOutRearmingMoveToActiveSpace(previousWindow)
            }
            // Tabbed siblings can't be ordered out in a shared fullscreen Space
            // (it flashes a blank workspace), so they stay stacked behind the
            // target.
            return
        }

        // Selecting the target's native tab does NOT reliably hide the slot's
        // other windows: they stay stacked behind it and, because the Space
        // sidebar is translucent, bleed through as a ghost Space-strip + shadow.
        // A hard `orderOut` of every non-target slot window is what reliably
        // drops them (the same finding `reconcileRestoreVisibility` relies on).
        // It detaches them from the native tab group; `syncSlotTabGroup`
        // regroups on the next switch.
        sweepNonTargetSlotWindows(keeping: targetWindow, alsoHide: previousWindow)

        // Drop any leaked snapshot overlay stranded on a slot window by a
        // superseded / instant-present switch (the live push-in's overlay is
        // spared) — it would otherwise ghost through the translucent sidebar.
        stripLeakedSwapOverlays()

        // Chromium re-surfaces a background Space window a runloop+ after the
        // swap settles — its restored tabs finishing load call
        // `BrowserWindow::Show()` — landing behind the target where the one-shot
        // sweep above can't see it yet (confirmed: a sibling flips visible=true
        // one runloop after the switch). Re-assert across a short coalesced
        // ladder, skipping while a swap animates (the push-in overlay draws on
        // the still-front leaving window, so hiding it mid-animation would break
        // the slide).
        scheduleNonTargetSlotWindowSweep()
    }

    /// Orders out every window in this slot except `keepWindow` (the target that
    /// should remain visible). `extra` covers an ungrouped hand-off window that
    /// may not be in `windowsBySpaceId`. Only touches windows that are actually
    /// on screen, so a settled slot does no work.
    private func sweepNonTargetSlotWindows(keeping keepWindow: NSWindow?, alsoHide extra: NSWindow?) {
        if let extra, extra !== keepWindow, extra.isVisible {
            orderOutRearmingMoveToActiveSpace(extra)
        }
        for controller in windowsBySpaceId.values {
            guard let window = controller.window,
                  window !== keepWindow,
                  window.isVisible else { continue }
            orderOutRearmingMoveToActiveSpace(window)
        }
    }

    /// Re-asserts the slot's one-window invariant over a few coalesced delays
    /// after a switch. Two things break it after the swap "settles":
    ///  - Chromium re-surfaces a background Space window a runloop+ later (its
    ///    restored tabs finishing load call `BrowserWindow::Show()`), stacking
    ///    it behind the target.
    ///  - A superseded / instant-present switch can strand a `SidebarSwapOverlay`
    ///    (the leaving-band snapshot) on a slot window; with the sidebar
    ///    translucent, either one bleeds through as the ghost strip + shadow.
    /// Each pass — once no swap is animating — strips any stray overlay and
    /// forces exactly the active Space's window on screen (see
    /// `enforceSlotSingleWindowInvariant`). Each switch supersedes the prior
    /// ladder (`sweepToken`); passes bail in fullscreen.
    private var sweepToken = 0
    private func scheduleNonTargetSlotWindowSweep() {
        sweepToken += 1
        let token = sweepToken
        for delay in [0.05, 0.15, 0.4, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.sweepToken == token else { return }
                // Strip leaked overlays every pass — safe even mid-animation
                // since the one live overlay (`activeSidebarOverlay`) is spared.
                self.stripLeakedSwapOverlays()
                // Re-order windows only when idle.
                self.enforceSlotSingleWindowInvariant()
            }
        }
    }

    /// Removes any `SidebarSwapOverlay` still parented in a slot window that is
    /// NOT the currently-animating one. Such an overlay is a leftover snapshot
    /// from a superseded / instant-present switch; the translucent sidebar makes
    /// it ghost through. Safe to run at any time — the live overlay is spared.
    private func stripLeakedSwapOverlays() {
        for controller in windowsBySpaceId.values {
            if let root = controller.window?.contentView {
                removeStraySwapOverlays(in: root)
            }
        }
    }

    /// Forces the slot back to "only the active Space's window is on screen, no
    /// leftover swap overlay". No-op while a swap animates (the push-in draws on
    /// the still-front leaving window, and its overlay is legitimately live) or
    /// in a shared fullscreen Space (ordering a tab out flashes a blank
    /// workspace). Keyed on `activeSpaceId` — the slot's source of truth — not
    /// `visibleController`, which rapid switching can leave transiently stale.
    private func enforceSlotSingleWindowInvariant() {
        guard !isSwitchAnimationInFlight, !slotHasFullScreenWindow else { return }
        guard let activeId = activeSpaceId,
              let activeController = windowsBySpaceId[activeId],
              let activeWindow = activeController.window else { return }

        var hidCount = 0
        for (spaceId, controller) in windowsBySpaceId where spaceId != activeId {
            guard let window = controller.window, window.isVisible else { continue }
            orderOutRearmingMoveToActiveSpace(window)
            hidCount += 1
        }
        // Re-front the active window if anything was hidden or it somehow fell
        // off screen; the guard keeps a settled slot from stealing focus.
        if hidCount > 0 || !activeWindow.isVisible {
            makeKeyAndOrderFrontHidingSlotTabBar(activeWindow)
        }
        visibleController = activeController
    }

    /// Removes any `SidebarSwapOverlay` in a window's view tree except the one
    /// live overlay (`activeSidebarOverlay`) belonging to an in-flight push-in,
    /// so a leaked overlay can be cleared without disturbing a running slide.
    private func removeStraySwapOverlays(in view: NSView) {
        for subview in view.subviews {
            if let overlay = subview as? SidebarSwapOverlay {
                if overlay !== activeSidebarOverlay {
                    overlay.removeFromSuperview()
                }
            } else {
                removeStraySwapOverlays(in: subview)
            }
        }
    }

    /// Used by restore-time callers that need to keep a sibling Space window
    /// off-screen. If AppKit is already managing that sibling as a non-selected
    /// tab in this slot's tab group, doing nothing preserves the group.
    func orderOutIfNotManagedBySlotTabGroup(_ controller: MainBrowserWindowController) {
        guard let window = controller.window else { return }
        if isTabbedWithAnySibling(window) {
            hideSlotTabBars()
            return
        }
        orderOutRearmingMoveToActiveSpace(window)
    }

    /// Re-asserts this slot's one-visible-window invariant after Chromium
    /// surfaces several of the slot's windows at once. Scheduled (coalesced)
    /// by `PhiChromiumCoordinator.mainBrowserWindowCreated` for every restored
    /// window on a cold-launch session-restore burst, and by
    /// `SpaceManager.reconcileSlotVisibilityAfterReopen` after a Dock-icon
    /// reopen (which surfaces the slot's hidden sibling Space windows the same
    /// way).
    ///
    /// On session restore a slot owns several Chromium windows (one per Space
    /// ever surfaced). Chromium surfaces every one with its own
    /// `makeKeyAndOrderFront` post-construction, and keeps re-ordering them as
    /// their restored tabs finish loading, so multiple of the slot's windows
    /// end up on screen at once — selecting the active native tab is NOT enough
    /// to drop the others behind it. The reconcile runs over a few runloop
    /// turns (Chromium's re-orders trail window creation by up to ~2s) and each
    /// pass orders every non-active window off screen, then re-fronts the
    /// active one.
    private var restoreVisibilityReconcileScheduled = false
    func scheduleRestoreVisibilityReconcile() {
        guard !restoreVisibilityReconcileScheduled else { return }
        restoreVisibilityReconcileScheduled = true
        for delay in [0.0, 0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if delay == 3.0 { self.restoreVisibilityReconcileScheduled = false }
                self.reconcileRestoreVisibility()
            }
        }
    }

    private func reconcileRestoreVisibility() {
        // `activeSpaceId` names the Space that belongs on screen (it tracks the
        // restored windows' key events; a genuine mid-restore user switch also
        // lands here, and showing that Space while hiding the rest stays
        // correct). Bail when the active Space's window hasn't restored yet; a
        // later restored window reschedules the pass.
        guard let activeId = activeSpaceId,
              let activeController = windowsBySpaceId[activeId],
              let activeWindow = activeController.window else { return }
        // Order every still-on-screen sibling off. `isVisible` stays true for a
        // background native tab but flips to false once ordered out, so this is
        // self-limiting: only windows Chromium (re-)surfaced are touched, and a
        // settled slot does no work. A hard `orderOut` — not tab selection — is
        // what reliably hides them, at the cost of detaching them from the
        // native tab group (rebuilt by `syncSlotTabGroup` on the next switch).
        //
        // EXCEPT for a tabbed sibling in a shared fullscreen Space: this
        // routine also runs on every Dock-icon reopen
        // (`reconcileSlotVisibilityAfterReopen`), and ordering a tab out of a
        // group that shares a fullscreen Space makes macOS flash a blank
        // fullscreen workspace — the same finding that makes
        // `enforceSlotSingleWindowInvariant` bail and
        // `orderOutIfNotTabbedWithTarget` fall back to tab selection. Tabbed
        // siblings stay stacked behind the re-selected active tab and the
        // strip bleed guard hides their ghost rows; a DETACHED sibling (never
        // part of the fullscreen Space) still gets the hard hide.
        let inSharedFullScreen = slotHasFullScreenWindow
        var hidCount = 0
        for (siblingSpaceId, controller) in windowsBySpaceId where siblingSpaceId != activeId {
            guard let window = controller.window, window.isVisible else { continue }
            if inSharedFullScreen, windowsShareTabGroup(window, activeWindow) {
                continue
            }
            orderOutRearmingMoveToActiveSpace(window)
            hidCount += 1
        }
        visibleController = activeController
        // Re-front the active window only when something was actually hidden (or
        // it isn't the selected tab yet), so settled passes don't repeatedly
        // steal key focus.
        if hidCount > 0 || activeWindow.tabGroup?.selectedWindow !== activeWindow {
            makeKeyAndOrderFrontHidingSlotTabBar(activeWindow)
        }
        updateWindowsMenuExclusion()
        // The active window is now surfaced; re-enter fullscreen on it if this
        // slot was fullscreen last session (no-op otherwise / after the first
        // successful pass).
        applyPendingRestoreFullScreen(activeWindow: activeWindow)
        if hidCount > 0 {
            AppLogInfo("[SpaceWindowSlot] restore reconcile: showing \(activeId), hid \(hidCount) sibling window(s)")
        }
    }

    /// Keeps the macOS Window menu (and Dock window list) showing exactly one
    /// entry per user-perceived window: the slot's visible Space. The sibling
    /// Space windows are real NSWindows tabbed into the slot's group but hidden
    /// behind the active one, so without this they'd each list as a separate
    /// "window" the user never opened. Re-run whenever the visible Space or the
    /// set of slot windows changes.
    private func updateWindowsMenuExclusion() {
        let visibleWindow = visibleController?.window
        for controller in windowsBySpaceId.values {
            guard let window = controller.window else { continue }
            window.isExcludedFromWindowsMenu = window !== visibleWindow
        }
    }

    /// AppKit does not expose a public setter for `NSWindowTabGroup`'s tab bar.
    /// The tab bar is installed as a titlebar accessory, so keep this
    /// compatibility shim narrow and local to the native tab-group experiment.
    private func hideSlotTabBars(in windows: [NSWindow]? = nil) {
        let targetWindows = windows ?? windowsBySpaceId.values.compactMap(\.window)
        for window in targetWindows {
            removeNativeTabBarAccessories(from: window)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let targetWindows = windows ?? self.windowsBySpaceId.values.compactMap(\.window)
            for window in targetWindows {
                self.removeNativeTabBarAccessories(from: window)
            }
        }
    }

    private func removeNativeTabBarAccessories(from window: NSWindow) {
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            let accessory = window.titlebarAccessoryViewControllers[index]
            guard NativeWindowTabBarSuppressor.containsNativeTabBar(in: accessory.view) else { continue }
            NativeWindowTabBarSuppressor.hideNativeTabBarDescendants(of: accessory.view, in: window)
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    private func isTabbedWithAnySibling(_ window: NSWindow) -> Bool {
        windowsBySpaceId.values.contains { sibling in
            guard let siblingWindow = sibling.window,
                  siblingWindow !== window else { return false }
            return windowsShareTabGroup(window, siblingWindow)
        }
    }

    private func windowsShareTabGroup(_ lhs: NSWindow?, _ rhs: NSWindow?) -> Bool {
        guard let lhs,
              let rhs,
              lhs !== rhs,
              let lhsGroup = lhs.tabGroup,
              let rhsGroup = rhs.tabGroup else {
            return false
        }
        return lhsGroup === rhsGroup
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
        // Defense in depth against a double-spawn for one (slot, Space): if a
        // live, DIFFERENT controller is already registered here, don't silently
        // overwrite it — that orphans a window the slot's sweeps and cascade
        // (which iterate `windowsBySpaceId`) can no longer reach. The
        // `pendingSpawnSpaceIds` gate in `activate` is the primary guard; this
        // catches any other path that manages to double-register. Tear down the
        // orphan's observers now (mirroring `evictWindow`) so its stale
        // didBecomeKey can't adopt this replacement, then retire its window via
        // the same deferred-close path a profile-change respawn uses (drained
        // near the end of this method).
        if let existing = windowsBySpaceId[spaceId], existing !== controller {
            AppLogWarn("[SpaceWindowSlot] registerWindow(\(spaceId)): replacing already-registered window \(existing.windowId) with \(controller.windowId)")
            if let token = keyObservationsByWindowId.removeValue(forKey: existing.windowId) {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = agentOcclusionObservationsByWindowId.removeValue(forKey: existing.windowId) {
                NotificationCenter.default.removeObserver(token)
            }
            tabBarAccessoryObservationsByWindowId.removeValue(forKey: existing.windowId)?.invalidate()
            pendingCloseOnReplacementBySpaceId[spaceId] = existing
        }
        windowsBySpaceId[spaceId] = controller
        manager?.hasEverHostedSlotWindow = true
        // The spawn for this Space has landed — clear the in-flight gate.
        pendingSpawnSpaceIds.remove(spaceId)
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
            observeNativeTabBarAccessories(for: controller)
            // Follow the user across macOS desktops. Each sibling NSWindow
            // is tied to whatever desktop it was last shown on; without
            // this, dragging the visible window to a new desktop and then
            // switching Phi Spaces yanks the user back to the sibling's
            // original desktop. `.moveToActiveSpace` makes the sibling
            // surface on the user's current desktop on each show instead.
            // The flag is transient, not permanent: a window that keeps it
            // while on screen is credited to no desktop by the window server,
            // so a macOS desktop round-trip skips the app during focus
            // restoration and the browser loses focus. It is stripped once
            // the window settles front (`scheduleMoveToActiveSpaceStrip`) and
            // re-armed when it goes back off screen
            // (`orderOutRearmingMoveToActiveSpace`).
            // Skip it while this slot already owns a fullscreen Space: a
            // window carrying `.moveToActiveSpace` is dragged out of its own
            // fullscreen Space on the next app activation, blanking it. The
            // window joins the slot's fullscreen Space via `syncSlotTabGroup`
            // below, and the fullscreen-exit hook re-arms hidden siblings. See
            // `windowFullScreenStateChanged`.
            // Also skip while the slot is pending a restore into fullscreen:
            // its active window registers BEFORE `applyPendingRestoreFullScreen`
            // toggles it, so `slotHasFullScreenWindow` is still false here.
            // Inserting `.moveToActiveSpace` now lets a SECOND restored slot's
            // fullscreen entry drag this window out before it goes fullscreen,
            // leaving a blank Space (the will-enter hook would clear it, but too
            // late). The flag is cleared once the toggle fires.
            if !slotHasFullScreenWindow && !pendingRestoreFullScreen {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
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
        let shouldBecomeVisible = visibleController == nil || spaceId == activeSpaceId
        syncSlotTabGroup(selecting: shouldBecomeVisible ? controller.window : visibleController?.window)
        if shouldBecomeVisible {
            visibleController = controller
        }
        // Exclude this newly registered window from the Window menu unless it's
        // the visible one. `visibleController`'s didSet covers the case where it
        // changed above; this also covers a sibling joining without changing it.
        updateWindowsMenuExclusion()
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

        // Agent-Space windows: keep them off screen unless the user has
        // explicitly surfaced them. Chromium re-orders the window on screen on
        // navigation focus without any key change, so watch occlusion (which
        // does flip off→on) and shove it back out. See
        // `agentOcclusionObservationsByWindowId`.
        if MainActor.assumeIsolated({ AgentSpaceManager.shared.isAgentSpace(spaceId) }) {
            let occlusionToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.scheduleEnforceAgentWindowHidden(controller)
            }
            agentOcclusionObservationsByWindowId[controller.windowId] = occlusionToken
        }
    }

    /// Orders an agent-Space window back off screen on the NEXT runloop turn.
    /// The re-hide must never run synchronously from a window notification: the
    /// key/occlusion events that trigger it fire INSIDE AppKit's
    /// `makeKeyAndOrderFront` / native tab-group mutation (during the agent
    /// window's spawn and seed-tab insert), and reentrant `orderOut` there
    /// corrupts AppKit's window-stack controller and throws — crashing the app,
    /// reliably once a slot owns two agent windows. Deferring runs the ordering
    /// on a clean stack, mirroring the deferred `window.close()` in
    /// `registerWindow` (unsafe to close re-entrantly from a Chromium callback).
    private func scheduleEnforceAgentWindowHidden(_ controller: MainBrowserWindowController) {
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.enforceAgentWindowHidden(controller)
        }
    }

    /// Pushes an agent-Space window back off screen if it surfaced without the
    /// user switching to it, and reclaims any key status it holds. No-op while
    /// `activate` is surfacing it deliberately (watch mode) or once it IS the
    /// slot's surfaced controller. Idempotent — bails when the window is
    /// already off screen and not key — so the two schedulers (spurious key
    /// event, occlusion flip) can both fire harmlessly. Always invoked
    /// deferred; see `scheduleEnforceAgentWindowHidden`.
    ///
    /// Ordering is load-bearing: the visible window takes key and native-tab-
    /// group selection BEFORE the agent window is ordered out. Ordering out a
    /// window that still holds key (or tab-group selection) makes AppKit pick
    /// the successor itself — and with every slot window sharing one native
    /// tab group that pick can be a HIDDEN sibling, whose didBecomeKey is then
    /// adopted as an external Space switch (`handleWindowDidBecomeKey`),
    /// yanking the user onto a Space they never chose. For the same reason the
    /// key reclaim must also run when the agent window holds key while off
    /// screen (a suppressed spurious key that never became occlusion-visible,
    /// e.g. the ownership flip of an agent handoff): key parked on a hidden
    /// agent window is handed to an arbitrary sibling by the next
    /// Chromium-side hide.
    private func enforceAgentWindowHidden(_ controller: MainBrowserWindowController) {
        guard !isPerformingActivate else { return }
        guard controller !== visibleController else { return }
        guard let window = controller.window else { return }
        // `isVisible` (ordered in), not just occlusion: a freshly keyed window
        // is ordered in before occlusion flips, and a fully covered one never
        // flips at all — both still need to be ordered out.
        let isOrderedIn = window.isVisible || window.occlusionState.contains(.visible)
        guard isOrderedIn || window.isKeyWindow else { return }
        AppLogInfo("[SpaceWindowSlot] re-hiding agent-Space window \(controller.windowId) (orderedIn=\(isOrderedIn) key=\(window.isKeyWindow) activeSpaceId=\(activeSpaceId ?? "nil"))")
        if let visible = visibleController?.window {
            makeKeyAndOrderFrontHidingSlotTabBar(visible)
        }
        if isOrderedIn {
            window.orderOut(nil)
        }
    }

    /// Records that `spaceId`'s next window close is going to be the
    /// result of the user closing the last tab in this Space, not
    /// the result of closing the window itself. Called from the tab-
    /// row ✕ button (`Tab.close()`) right before dispatching the
    /// IDC_CLOSE_TAB command, when the active Space's tab count is
    /// about to drop to zero. ⌘W (`CommandDispatcher` IDC_CLOSE_TAB)
    /// deliberately does NOT call this: closing the last tab with ⌘W
    /// tears the whole slot down like ⇧⌘W instead of switching to a
    /// sibling Space. Incognito Spaces never get here on a last-tab
    /// close — both paths intercept it and route into the confirmed
    /// Space teardown (`SpaceManager.requestCloseIncognitoSpace`).
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

    /// Drops the controller for `spaceId`. Behavior splits on whether the
    /// close was tab-driven or window-driven:
    ///
    /// - Tab-driven (the user just closed the last tab in the visible Space)
    ///   AND another Space in the slot still has tabs: activate that
    ///   sibling. The user-perceived window stays alive showing the
    ///   sibling Space's content.
    /// - Otherwise (user closed the window itself, OR every other
    ///   Space is also empty): tear down every remaining Space via
    ///   `cascadeCloseRemainingWindows`, which calls `NSWindow.close()` one
    ///   window per runloop turn so the entire user-perceived window goes away
    ///   as a unit. Serializing matters — closing all of one native tab
    ///   group's windows in a single synchronous loop let AppKit drop a
    ///   programmatic close and strand a background Space with live tabs. If
    ///   this leaves SpaceManager with no slots at all, the slot is simply
    ///   dropped and the app keeps running with no windows (closing a window
    ///   never quits the app; only Cmd+Q / the Quit menu item terminate).
    ///
    /// The window-driven cascade fires even when the closed controller was
    /// not the tracked `visibleController`, as long as the close was not
    /// tab-driven: in the slot's native tab group `visibleController` can lag
    /// AppKit's selected tab, and gating the cascade on `wasVisible` alone let
    /// a real window close strand the slot's other Spaces with live tabs.
    /// Background closes that should NOT cascade (deleteSpace / changeProfile /
    /// respawnWindow) evict the controller first, so they early-return on the
    /// identity guard below and never reach this branch.
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
        if let token = agentOcclusionObservationsByWindowId.removeValue(forKey: controller.windowId) {
            NotificationCenter.default.removeObserver(token)
        }
        tabBarAccessoryObservationsByWindowId.removeValue(forKey: controller.windowId)?.invalidate()
        // An Incognito Space lives only as long as it has windows: once the
        // last one anywhere is gone, retire the Space itself. This covers
        // every close path that bypasses `closeIncognitoSpace` — a
        // window-driven slot cascade, a scripted window.close, the
        // tab-driven hand-off. Deferred a turn so a mid-cascade teardown
        // finishes reshaping this slot before the strip republishes
        // (`closeIncognitoSpace`'s own closes evict first and never get
        // here — the identity guard above already returned).
        if SpaceManager.isIncognitoSpaceId(spaceId) {
            DispatchQueue.main.async { [weak manager] in
                manager?.reapIncognitoSpaceIfWindowless(spaceId)
            }
        }
        // Closing a window fires no will-exit fullscreen notification, so a
        // fullscreen window that closes (e.g. a tab-driven close handing off
        // to a sibling below) would leave `isFullScreen` stuck true — siblings
        // keep `.moveToActiveSpace` stripped and the snapshot keeps
        // force-restoring fullscreen next launch. Deferred one turn: AppKit
        // may instead promote a tabbed sibling INTO the dying window's
        // fullscreen Space (the flag staying true is then correct), and that
        // promotion lands after willClose.
        if isFullScreen {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileFullScreenWithWindowState()
            }
        }
        // A window the controlled slot teardown is closing. It is already out
        // of the map (above); don't re-run a hand-off/cascade — the driver
        // (`cascadeCloseRemainingWindows`) already issued closes for the rest.
        // Just finish the slot once this drains the last window.
        if isCascadingSlotClose {
            if windowsBySpaceId.isEmpty {
                isCascadingSlotClose = false
                manager?.removeSlot(self)
            }
            return
        }
        let wasVisible = (visibleController === controller)
        // Was the closing window the user's on-screen window? True when it is the
        // tracked `visibleController`, OR — covering the case the cascade was
        // widened for — the native tab group's currently-selected window. In the
        // slot's native tab group `visibleController` can lag AppKit's selected
        // tab, so a real window-driven close can arrive on a controller that
        // isn't the tracked visible one; at `willClose` time that window is still
        // the group's selected tab, so this still classifies it as on-screen.
        // Crucially it EXCLUDES a genuinely-hidden sibling (a background tab, or
        // an `orderOut`'d restore sibling) closed out from under us by an
        // extension / script `window.close()` / Chromium-internal teardown: that
        // window is not the selected tab, so it must NOT cascade the visible
        // window shut — it is just dropped from the map below.
        let closingWindow = controller.window
        let wasOnScreen = wasVisible
            || (closingWindow != nil && closingWindow === closingWindow?.tabGroup?.selectedWindow)
        // A tab-driven hand-off only applies to the visible window closing —
        // computed (and `firstSiblingWithTabs` only consulted) in that case.
        let siblingWithTabs = (wasVisible && isTabDriven) ? firstSiblingWithTabs() : nil
        if let siblingWithTabs {
            // Tab-driven close with a viable sibling: hand off to
            // the sibling instead of tearing the slot down.
            // `visibleController` is left pointing at the closing
            // controller so the pre-close composite snapshot can be
            // threaded into the per-style animation even after the
            // closing window's GPU surface has been drained.
            AppLogInfo("[SpaceWindowSlot] tab-driven close of \(spaceId); switching to sibling \(siblingWithTabs)")
            activate(spaceId: siblingWithTabs, leavingSnapshotOverride: leavingSnapshot)
        } else if wasVisible || (wasOnScreen && !isTabDriven) {
            // Window-driven slot close. Two ways in:
            //  - the visible window closed (window-driven, or tab-driven with
            //    no viable sibling), or
            //  - a non-tab-driven close landed on a controller that wasn't the
            //    tracked `visibleController` but WAS the on-screen window (the
            //    `visibleController`-lags-the-selected-tab case above).
            // Either way the user closed the window, so tear down every
            // remaining Space in the slot, one by one, leaving no background
            // Space holding live tabs. A non-tab-driven close of a genuinely
            // hidden sibling does NOT reach here (`wasOnScreen` is false): it
            // drops from the map without cascading the visible window.
            // Legitimate background closes (deleteSpace / changeProfile /
            // respawnWindow) evict first and never reach here at all (identity
            // guard at the top of this method).
            visibleController = nil
            if windowsBySpaceId.isEmpty {
                AppLogInfo("[SpaceWindowSlot] window-driven close of \(spaceId); no siblings")
            } else {
                AppLogInfo("[SpaceWindowSlot] window-driven close of \(spaceId); cascading \(windowsBySpaceId.count) sibling(s) via Chromium")
                isCascadingSlotClose = true
                cascadeCloseRemainingWindows()
                scheduleCascadeVetoRecovery()
            }
        }
        if windowsBySpaceId.isEmpty {
            // The slot's last window is gone, so drop the slot from the
            // registry — but do NOT terminate the app when this empties the
            // slot map. Closing the last window (red X, Cmd+Shift+W, or
            // Cmd+W on the last tab) leaves the app running with no windows,
            // the standard macOS behavior (`applicationShouldTerminate-
            // AfterLastWindowClosed` is false). A dock-click reopen or Cmd+N
            // rebuilds a window+slot on the persisted active Space. Cmd+Q /
            // the Quit menu item remain the explicit way to fully quit.
            manager?.removeSlot(self)
        }
    }

    /// Drives a window-driven slot teardown: closes every window still
    /// registered to this slot through Chromium (`chrome::ExecuteCommand` →
    /// `BrowserWindow::Close`), the same path the user's own window close
    /// takes.
    ///
    /// AppKit's `NSWindow.close()` dropped the teardown of hidden,
    /// tab-grouped browser windows unpredictably — with several Spaces in a
    /// slot, some survived with live tabs — because closing several windows of
    /// one native tab group races AppKit's tab-bar selection promotion, even
    /// when serialized one per runloop turn. Routing each close through
    /// Chromium tears each Browser down deterministically and independently of
    /// the AppKit tab group. Each teardown later re-enters `unregisterWindow`,
    /// which (under `isCascadingSlotClose`) just drops that window from the
    /// map; the last drop clears the flag and removes the slot.
    ///
    /// Trade-off vs. the old AppKit path: `IDC_CLOSE_WINDOW` honors
    /// `beforeunload`, so a background Space with an unsaved-changes prompt can
    /// surface a dialog — the same behavior the visible window already has.
    private func cascadeCloseRemainingWindows() {
        let bridge = ChromiumLauncher.sharedInstance().bridge
        // Snapshot: each close re-enters `unregisterWindow` (which mutates the
        // map). Stale windowIds resolve to no browser and no-op in the bridge.
        for controller in Array(windowsBySpaceId.values) {
            bridge?.executeCommand(
                Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue),
                windowId: Int64(controller.windowId))
        }
    }

    /// Grace period after arming a window-driven cascade before it is treated
    /// as vetoed. Each `IDC_CLOSE_WINDOW` roundtrip (Chromium close → browser
    /// teardown → `windowWillClose` → `unregisterWindow`) is well under 100ms,
    /// so a genuine cascade — even of several siblings — empties the slot far
    /// inside this window; anything still standing at the deadline was blocked
    /// by a `beforeunload` prompt the user cancelled. Matches the
    /// `tabDrivenCloseTTL` reasoning for the tab-level version of this veto.
    private static let cascadeVetoRecoveryDelay: TimeInterval = 2.0

    /// Recovers a slot whose window-driven teardown was vetoed. The cascade
    /// issues `IDC_CLOSE_WINDOW` for every remaining Space window; each honors
    /// `beforeunload`, so a background Space with an unsaved-changes prompt the
    /// user cancels never re-enters `unregisterWindow`. That drop is the ONLY
    /// thing that clears `isCascadingSlotClose`, so a veto leaves the flag stuck
    /// for the slot's life: `handleWindowDidBecomeKey` early-returns (the
    /// surviving window is never adopted as visible), `keySlot` goes stale, and
    /// with `visibleController` nil the slot vanishes from
    /// `currentSpaceWindowMap` — its Spaces become unroutable and drop out of
    /// the "Open Link In Space" menu. If the cascade hasn't emptied the slot by
    /// the deadline, treat it as vetoed and re-adopt a surviving window.
    private func scheduleCascadeVetoRecovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cascadeVetoRecoveryDelay) { [weak self] in
            guard let self, self.isCascadingSlotClose,
                  !self.windowsBySpaceId.isEmpty else { return }
            self.recoverFromVetoedCascade()
        }
    }

    private func recoverFromVetoedCascade() {
        isCascadingSlotClose = false
        // Prefer the window the user is looking at (the one whose beforeunload
        // prompt they answered is key), then any on-screen Space window, then
        // any surviving Space at all.
        guard let survivor = windowsBySpaceId.first(where: { $0.value.window?.isKeyWindow == true })
                ?? windowsBySpaceId.first(where: { $0.value.window?.isVisible == true })
                ?? windowsBySpaceId.first else { return }
        AppLogInfo("[SpaceWindowSlot] cascade close vetoed; recovering on surviving Space \(survivor.key)")
        activeSpaceId = survivor.key
        // `visibleController`'s didSet re-pushes the Space→window routing map,
        // undoing the drop-out the stuck flag caused.
        visibleController = survivor.value
        makeKeyAndOrderFrontHidingSlotTabBar(survivor.value.window)
        manager?.persistActiveSpaceId(survivor.key)
        manager?.persistSlotsSnapshot()
        manager?.notifySlotBecameKey(self)
        // A multi-veto (several dirty Spaces kept) can leave more than one
        // window on screen; collapse the rest behind the adopted one over the
        // standard sweep ladder.
        scheduleNonTargetSlotWindowSweep()
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
        if let token = agentOcclusionObservationsByWindowId.removeValue(forKey: controller.windowId) {
            NotificationCenter.default.removeObserver(token)
        }
        tabBarAccessoryObservationsByWindowId.removeValue(forKey: controller.windowId)?.invalidate()
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
    /// slot shut. Agent and Incognito Spaces are never hand-off targets
    /// (both scans): a last-tab close must not dump the user into an agent's
    /// hidden workspace or the Incognito Space.
    private func firstSiblingWithTabs() -> String? {
        if let manager {
            for space in manager.spaces where manager.isAutomaticSwitchTarget(space) {
                if let candidate = windowsBySpaceId[space.spaceId],
                   !candidate.browserState.tabs.isEmpty {
                    return space.spaceId
                }
            }
        }
        return windowsBySpaceId.first(where: { entry in
            !SpaceManager.isIncognitoSpaceId(entry.key)
                && !MainActor.assumeIsolated({ AgentSpaceManager.shared.isAgentSpace(entry.key) })
                && !entry.value.browserState.tabs.isEmpty
        })?.key
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

    /// Whether the slot was in native fullscreen at the last persist, for the
    /// cross-launch restore record. Read by `SpaceManager.persistSlotsSnapshot`.
    fileprivate func snapshotIsFullScreen() -> Bool {
        isFullScreen
    }

    /// Used by `SpaceManager.handleSpacesUpdate` when a slot's active Space
    /// has been deleted and no fallback Space exists.
    fileprivate func clearActiveSpace() {
        activeSpaceId = nil
    }

    /// Records `spaceId` as the slot's last surfaced regular Space (see
    /// `lastRegularSpaceId`). Ephemeral Spaces — agent (by live task or model
    /// signature, matching `persistActiveSpaceId`) and Incognito — are
    /// skipped, so surfacing one to watch leaves the retreat anchor on the
    /// Space the user came from.
    private func recordRegularSpace(_ spaceId: String) {
        guard !SpaceManager.isIncognitoSpaceId(spaceId) else { return }
        guard !MainActor.assumeIsolated({ AgentSpaceManager.shared.isAgentSpace(spaceId) }),
              manager?.spaces.first(where: { $0.spaceId == spaceId })?.isAgentSpace != true
        else { return }
        lastRegularSpaceId = spaceId
    }

    /// Closes a window that has been evicted from this slot, first parking key
    /// (and native-tab-group selection) on the slot's visible window and
    /// arming the fallout guard. Closing a window that still holds key or
    /// group selection makes AppKit promote a successor itself — potentially a
    /// hidden sibling, whose key event would then be adopted as an external
    /// switch and yank the user onto a Space they never chose (observed when
    /// a completed agent task's window closed while the user was watching it).
    func closeRetiredWindow(_ controller: MainBrowserWindowController) {
        agentKeyFalloutArmedAt = Date()
        if controller.window?.isKeyWindow == true,
           let visible = visibleController?.window {
            makeKeyAndOrderFrontHidingSlotTabBar(visible)
        }
        controller.window?.close()
    }

    private func handleWindowDidBecomeKey(spaceId: String) {
        guard let controller = windowsBySpaceId[spaceId] else { return }
        // Ignore key changes that fire as a side effect of our own in-flight
        // `activate`. Spawning the target Space's window — especially on a
        // different profile — adds it to the slot's native tab group, which can
        // briefly make a SIBLING window key. `activate` owns `activeSpaceId` /
        // `visibleController` for its duration and already set them to the target;
        // adopting the spuriously-keyed sibling here clobbers that and lands the
        // user on the wrong Space (the root cause of "create Space doesn't switch
        // to the new Space"). Genuine user / URL-rule key changes run with
        // `isPerformingActivate == false`.
        if isPerformingActivate { return }
        // Same reasoning one layer later: while this slot's own switch
        // animation is in flight, every key change is churn from the swap
        // itself or from whatever UI initiated it — NOT a switch. The concrete
        // offender: the agent-handoff prompt's completion handler runs
        // `activate(agentSpace)` synchronously, and AppKit re-keys the sheet's
        // PARENT window (the origin Space) ~30ms later, mid-animation.
        // Adopting that re-key as an external switch reverted `activeSpaceId`
        // to the origin, made the in-flight agent surface look spurious, and
        // bounced the user straight back — "plays the switch animation but
        // lands on the origin Space". The swap's completion re-keys the real
        // target after the flags clear, so the settled state is adopted
        // normally.
        if isSwitchAnimationInFlight {
            AppLogInfo("[SpaceWindowSlot] ignoring key change for \(spaceId) during in-flight Space switch (activeSpaceId=\(activeSpaceId ?? "nil"))")
            return
        }
        // Ignore key changes that fire while the slot is tearing itself down.
        // A window-driven close cascades every Space's window shut one by one
        // (`cascadeCloseRemainingWindows`); the slot's windows share a native
        // macOS tab group, so closing the visible Space's window promotes a
        // hidden SIBLING to key mid-teardown — a Space the user never switched
        // to. Adopting it would persist that sibling as the last-active Space
        // and rewrite the restore snapshot, so the next reopen surfaces the
        // wrong Space instead of the one that was on screen when the window was
        // closed. The whole slot is going away; there is nothing to adopt.
        if isCascadingSlotClose { return }
        // Ignore key changes on an agent Space's hidden window that isn't the
        // slot's current Space. An agent Space is an ephemeral background
        // workspace: its window is spawned hidden (`spawnHiddenWindow`) and
        // joined to the slot's native tab group. It can be made key WITHOUT the
        // user switching to it — AppKit keys the arriving tab as it lands, and
        // (the real offender) the agent's own navigation focuses its
        // WebContents, which orders its NSWindow front and activates the app.
        // Left alone that both flips the slot's `activeSpaceId` to the agent's
        // AND leaves the agent window physically on top of the user's, yanking
        // them onto the agent Space the instant a task navigates. The user only
        // ever surfaces an agent Space deliberately, through `activate` (pip
        // click) — which sets `activeSpaceId` itself and guards this handler via
        // `isPerformingActivate` — so a key event that reaches here for an agent
        // Space that isn't already active is always spurious. Don't adopt it as
        // the active Space, and push the window back off screen — but ONLY on a
        // later runloop turn (`scheduleEnforceAgentWindowHidden`): this handler
        // runs inside AppKit's makeKeyAndOrderFront, and ordering the window out
        // synchronously here crashes. The deferred enforce also hands key (and
        // native-tab-group selection) back to the visible window first — the
        // agent window HOLDS key right now, and key left parked on it (or an
        // orderOut while it is key) makes AppKit promote an arbitrary hidden
        // sibling, which this handler would then adopt as an external switch,
        // landing the user on a Space they never chose.
        // Matched by live task OR model signature: `deleteSpace` drops the
        // task record before the retreat and the deferred window close, so a
        // key event fired by the dying window during that teardown (the CDP
        // client may still be driving it) would otherwise no longer register
        // as an agent Space and be adopted — yanking the user onto a Space
        // that is mid-deletion.
        let isAgentSpaceKey = MainActor.assumeIsolated { AgentSpaceManager.shared.isAgentSpace(spaceId) }
            || manager?.spaces.first(where: { $0.spaceId == spaceId })?.isAgentSpace == true
        if isAgentSpaceKey, activeSpaceId != spaceId {
            AppLogInfo("[SpaceWindowSlot] suppressing spurious agent-Space key: spaceId=\(spaceId) activeSpaceId=\(activeSpaceId ?? "nil") visible=\(visibleController?.windowId ?? -1)")
            agentKeyFalloutArmedAt = Date()
            scheduleEnforceAgentWindowHidden(controller)
            return
        }
        // Same teardown, later phase: once the deleted Space's row has left
        // `spaces`, the signature check above can't see it either. A key
        // event for a Space the manager doesn't know is never a switch the
        // user made — `activate` refuses unknown spaceIds the same way — so
        // don't adopt it; push the window back off screen like the agent
        // case (it is about to be closed). The slot's first key is exempt
        // (`visibleController == nil`): at cold launch windows register and
        // key before the store's first emission.
        if let manager, visibleController != nil, !manager.spaces.isEmpty,
           !manager.spaces.contains(where: { $0.spaceId == spaceId }),
           activeSpaceId != spaceId {
            AppLogInfo("[SpaceWindowSlot] suppressing key for unknown (mid-deletion) Space: spaceId=\(spaceId) activeSpaceId=\(activeSpaceId ?? "nil") visible=\(visibleController?.windowId ?? -1)")
            agentKeyFalloutArmedAt = Date()
            scheduleEnforceAgentWindowHidden(controller)
            return
        }
        // Fallout guard — see `agentKeyFalloutArmedAt`. Key was just parked on
        // a hidden window the user never surfaced; it moving to anything but
        // the slot's on-screen window is AppKit picking a successor, not a
        // switch. Runs synchronously (the deferred re-hide loses this race on
        // a busy main-thread turn), refuses the adoption below, and routes key
        // back to the visible window on a clean stack. The visible window
        // regaining key lands in the disarm branch, closing the episode.
        if let armedAt = agentKeyFalloutArmedAt {
            if controller === visibleController || spaceId == activeSpaceId {
                agentKeyFalloutArmedAt = nil
            } else if Date().timeIntervalSince(armedAt) < Self.agentKeyFalloutWindow {
                AppLogInfo("[SpaceWindowSlot] refusing agent-key fallout adoption: spaceId=\(spaceId) window=\(controller.windowId) activeSpaceId=\(activeSpaceId ?? "nil")")
                DispatchQueue.main.async { [weak self] in
                    guard let self, let visible = self.visibleController?.window else { return }
                    self.makeKeyAndOrderFrontHidingSlotTabBar(visible)
                }
                return
            } else {
                agentKeyFalloutArmedAt = nil
            }
        }
        hideSlotTabBars()
        // This window is the slot's on-screen window now — drop
        // `.moveToActiveSpace` once the front settles, or the next macOS
        // desktop round-trip skips the app during focus restoration. Covers
        // the Chromium-driven surfaces (URL-rule routing, session restore,
        // extension-created windows) that never pass through
        // `makeKeyAndOrderFrontHidingSlotTabBar`.
        if let keyWindow = controller.window {
            scheduleMoveToActiveSpaceStrip(for: keyWindow)
        }
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
        recordRegularSpace(spaceId)
        if activeSpaceId != spaceId {
            activeSpaceId = spaceId
            manager?.persistSlotsSnapshot()
            // The previous window is still alive in the slot for URL-rule
            // routing (Chromium doesn't close it), so the per-style snapshot
            // paths produce real pixels.
            if isExternalSwitch, let previous, let previousSpaceId {
                // Chromium surfaced the target window itself for the URL-rule
                // route, so the clicked path's swap-time frame pin never ran —
                // yet Chromium still re-applies the target's stale creation
                // bounds a few hundred ms after it surfaces, the same late
                // clobber `activate` defends against. Without the pin that
                // re-apply lands as a visible jump and, worse, the frame
                // observer records the jumped-back bounds as `lastKnownFrame`
                // and propagates them to every sibling. Hold the target at the
                // leaving window's frame (still alive here, so authoritative)
                // and arm the pin so the re-apply is reverted. Mirrors
                // `activate`'s swap path; safe with both animation styles
                // below. See `pinnedFrame`.
                if let inheritedFrame = resolveInheritedFrame(from: previous),
                   let targetWindow = controller.window {
                    targetWindow.setFrame(inheritedFrame, display: false)
                    // Not armed in fullscreen — same reasoning as the matching
                    // guard in `activate`'s swap path.
                    if !slotHasFullScreenWindow {
                        pinnedFrame = inheritedFrame
                    }
                }
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
                    // The band slide draws on the already-front target and
                    // swaps no windows, so unlike every other switch path
                    // nothing here would sweep the leaving window. Mirror the
                    // spawn path: slide, then order out.
                    orderOutIfNotTabbedWithTarget(previous.window, targetWindow: controller.window)
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
            // Post-swap pin: hold the just-surfaced window where the switch put
            // it until Chromium's late re-apply of the window's stale creation
            // bounds has been countered. A reposition with no mouse button held
            // is that programmatic re-apply — revert it and release the pin. A
            // reposition the user is driving (mouse held) moves the pin with
            // them and keeps it armed. See `pinnedFrame`.
            if let pinned = self.pinnedFrame {
                if NSEvent.pressedMouseButtons == 0 {
                    if !frame.equalTo(pinned) {
                        window.setFrame(pinned, display: false)
                        self.pinnedFrame = nil
                    }
                    return
                }
                self.pinnedFrame = frame
            }
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
        for token in agentOcclusionObservationsByWindowId.values {
            NotificationCenter.default.removeObserver(token)
        }
        agentOcclusionObservationsByWindowId.removeAll()
        for token in visibleFrameObservers {
            NotificationCenter.default.removeObserver(token)
        }
        visibleFrameObservers.removeAll()
        for observation in tabBarAccessoryObservationsByWindowId.values {
            observation.invalidate()
        }
        tabBarAccessoryObservationsByWindowId.removeAll()
        stopStripRowPointerWatchdog()
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
