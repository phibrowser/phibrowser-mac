// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation
import PostHog

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

    /// Chooses the profile that owns a newly materialized default Space.
    /// Signed-in access preserves the established `Default` binding. Guest
    /// access has no account profile of its own, so it must wait for Chromium
    /// to report the profile of the window that will use the Space.
    static func profileIdForDefaultSpaceCreation(
        isGuest: Bool,
        isGuestAccountPromotionInProgress: Bool,
        isBoundToDefaultAccount: Bool,
        observedNormalWindowProfileId: String?
    ) -> String? {
        guard isGuest else { return LocalStore.defaultProfileId }
        guard !isGuestAccountPromotionInProgress,
              isBoundToDefaultAccount,
              let observedNormalWindowProfileId,
              !observedNormalWindowProfileId.isEmpty else {
            return nil
        }
        return observedNormalWindowProfileId
    }

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
                format: NSLocalizedString("spaces.builtIn.incognito.numberedName", value: "Incognito %d", comment: "Incognito Space name when several are open; %d is its number"),
                descriptor.ordinal
            )
        } else {
            name = NSLocalizedString("spaces.builtIn.incognito.singleSpaceName", value: "Incognito", comment: "Built-in Incognito Space name when only one is open")
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
            name: NSLocalizedString("spaces.builtIn.incognito.routingTargetName", value: "Incognito", comment: "Built-in Incognito target name used by URL routing"),
            colorHex: "#5F6368",
            iconName: Self.incognitoSpaceDefaultIcon,
            sortOrder: spaces.count
        )
    }

    @Published private(set) var spaces: [SpaceModel] = []

    /// Persisted user Spaces — the ones the Spaces settings pane manages.
    /// Excludes runtime-only Incognito Spaces and ephemeral agent Spaces;
    /// the General pane's Theme section locks when this holds more than
    /// one Space.
    var userSpaces: [SpaceModel] {
        spaces.filter { !Self.isIncognitoSpaceId($0.spaceId) && !$0.isAgentSpace }
    }

    /// One-shot guard for `migrateLegacyFollowGlobalPinsIfNeeded`.
    private var hasMigratedLegacyThemePins = false

    /// Spaces created when "Follow Global" existed have no pinned theme.
    /// Now that every Space owns its theme, pin those to the current
    /// global theme (their exact rendered look) once per launch, so their
    /// color no longer shifts when the default Space's theme changes.
    /// Agent Spaces are skipped — ephemeral and orphan-swept at launch.
    private func migrateLegacyFollowGlobalPinsIfNeeded(storeSpaces: [SpaceModel]) {
        guard !hasMigratedLegacyThemePins, !storeSpaces.isEmpty,
              let account = boundAccount else { return }
        hasMigratedLegacyThemePins = true
        var map = account.userDefaults.spaceThemeIds()
        let globalThemeId = MainActor.assumeIsolated { ThemeManager.shared.currentTheme.id }
        var migratedIds: [String] = []
        for space in storeSpaces where !space.isAgentSpace && map[space.spaceId] == nil {
            map[space.spaceId] = globalThemeId
            migratedIds.append(space.spaceId)
        }
        guard !migratedIds.isEmpty else { return }
        account.userDefaults.setSpaceThemeIds(map)
        // Windows registered before this ran (the cold-launch race) were
        // left mirroring the global theme; pin them to the pin just
        // written so window and stored state can't drift apart later.
        for spaceId in migratedIds {
            reapplyResolvedTheme(forSpaceId: spaceId)
        }
    }

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
    /// First normal Chromium profile observed this app session. Chromium can
    /// report a dangling window before browser access is granted, so retain
    /// the value independently of account binding for a later Guest entry.
    private var observedNormalWindowProfileId: String?
    private var cancellables = Set<AnyCancellable>()
    private var spacesCancellable: AnyCancellable?
    private var rulesCancellable: AnyCancellable?

    /// Most recent snapshot from `urlRulesPublisher`. Acts as a typed cache so
    /// `pushRoutingTableToChromium` doesn't hit the SwiftData main context on
    /// every slot lifecycle event (and lets `rules(forSpaceId:)` answer from
    /// memory). Updated only on the main thread via the publisher sink.
    private var cachedURLRules: [SpaceURLRule] = []

    /// True once the initial URL-rule snapshot from `urlRulesPublisher` has
    /// arrived (even if empty). External URL opens are held on this in
    /// `AppController.scheduleForwardOpenURLsToChromium`: forwarding earlier
    /// on a cold launch would resolve the URL against a routing table pushed
    /// without the persisted rules and silently bypass Space URL routing.
    private(set) var hasLoadedURLRules = false

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
        /// Where the slot's window sat on screen at snapshot time, already
        /// clamped to the screens attached NOW (`loadRestoreSnapshot`) — the
        /// display it was saved on may be gone by the time it is read back.
        ///
        /// Always a WINDOWED rect: a slot in fullscreen records the geometry it
        /// will have once it leaves fullscreen, never the screen-sized one (see
        /// `SpaceWindowSlot.snapshotFrame`).
        ///
        /// Nil for a snapshot written before this field existed, and for one
        /// whose recorded rect no longer parses. That means "this slot has no
        /// remembered geometry", so a consumer either places the slot its own
        /// way or does nothing — never drops the entry. Every other restore
        /// path here works without a frame, and none is gated on one.
        ///
        /// Read by the reopen loading window, which is placed here and then
        /// forces the restored window onto the same rect
        /// (`showReopenLoadingWindows`, `slotForRestoreIndex`). It takes the
        /// second option on nil: no remembered position, no loading window, and
        /// the slot reopens exactly as it does today.
        let frame: NSRect?
        /// How wide the slot's sidebar was, so a reopen can draw a band where
        /// it will come back. `0` means collapsed — which is also how
        /// `.comfortable` records itself, since it keeps the sidebar collapsed
        /// permanently — and nil means a snapshot written before this existed.
        /// The two are NOT the same to the one consumer: a collapsed sidebar
        /// draws nothing because there is nothing there, and an absent value
        /// draws nothing because guessing a width would put the boundary
        /// somewhere the restored window's sidebar does not end
        /// (`ReopenLoadingWindow.sidebarBandWidth`).
        let sidebarWidth: CGFloat?
        /// Where the slot's window had its leading traffic light, as a distance
        /// from the top-left of its frame. Recorded so the loading window can
        /// place its own on the answer this Chromium and this macOS actually
        /// gave, instead of on a constant copied out of the fork. Nil for a
        /// snapshot written before this existed; the copy is then the fallback
        /// (`ReopenLoadingWindow.trafficLightOrigin(remembered:)`).
        let trafficLightOrigin: NSPoint?
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
    /// Previous-session windowId → spaceId for every window the last armed
    /// (lazy) reopen parked as a ghost instead of replaying. Written by
    /// `armLazyRestoreForReopen` in the same tick as the snapshot load (an
    /// unarmed run keeps it empty, and `persistSlotsSnapshot` then writes
    /// exactly what it always wrote). It is what lets the persisted snapshot
    /// keep naming a parked window's Space (`persistedWindowMap`): the
    /// ghost's Space stays on the strip while its window exists only in the
    /// session file, and this map is the one record tying the two together.
    /// Entries retire one at a time through `consumeParkedGhost` — a
    /// materialization claims the window, an invalidation (Space deleted,
    /// slot closed) drops it on both sides — and wholesale twice: when a
    /// snapshot loads (a new reopen's classification supersedes the last
    /// one's) and when the account unbinds (`unbind`, with the rest of the
    /// family this belongs to; the records describe a session this side can
    /// no longer reach).
    private var parkedGhostSpaceIdsByWindowId: [Int: String] = [:]
    /// Index into `restoreEntries` → the loading window standing in for that
    /// slot. `slotForRestoreIndex` lends each one to the slot that claims its
    /// entry, so the slot can drop it behind its restored window and close it
    /// early; the reference stays here as well, because this map is what
    /// guarantees every window of the run is eventually closed — a claimed slot
    /// can leave `restoredSlotsByIndex` (`removeSlot`) before the hand-off is
    /// over, and a window nothing holds but a discarded slot would stay on
    /// screen for good.
    private var reopenLoadingWindowsByRestoreIndex: [Int: ReopenLoadingWindow] = [:]
    /// True from the moment a reopen places its first loading window until the
    /// hand-off is completely over — loading windows closed and forced
    /// placements dropped. Those two do not end together (see
    /// `ReopenLoadingHandoff`), so this covers the whole span rather than
    /// either one. When the feature is off it is never set, which is what
    /// reduces both teardown entry points here to a single flag test.
    private var reopenLoadingRunActive = false
    /// Decides when this reopen's loading windows may be destroyed. Nil outside
    /// a run.
    private var reopenLoadingHandoff: ReopenLoadingHandoff?
    /// The one armed callback asking `reopenLoadingHandoff` to decide again.
    /// Replaced, never accumulated — the tracker always names a single next
    /// deadline.
    private var reopenLoadingHandoffWait: DispatchWorkItem?
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
    /// Reserved `restoredFromWindowId` for the window Chromium's session restore
    /// creates when a profile's saved session held nothing restorable
    /// (`phi::kRestoreFallbackWindowId` — the two must stay in sync). Phi
    /// produces such sessions routinely: a window whose last tab closes stays
    /// alive on a placeholder page, and a window saved with an empty tab list is
    /// dropped when the session is read back, so reopening one macOS window that
    /// hosted two Spaces can mean one profile with an empty session and one with
    /// a real one.
    ///
    /// The window re-creates no saved window, so it is never a snapshot key —
    /// but it is still this restore's stand-in for the slot being reopened, so
    /// it claims a snapshot entry by profile. It is the one shape that may do so
    /// outside the launch grace period, because the id says what the window IS;
    /// no ambient "a restore is running" state is consulted, which would be
    /// unsafe (a Cmd+N during a restore is handled by the window-level path once
    /// the first restored window takes key, so a misclaimed — hence concealed —
    /// window would look like the command did nothing).
    private static let restoreFallbackWindowId = -1

    /// True from the moment a windowless session restore is requested until
    /// Chromium reports every profile's restore has settled — a started replay
    /// settles once its windows and tabs exist, a skipped or refused profile
    /// settles immediately (see `beginWindowlessSessionRestore`). Gates the
    /// plain-window fallback, absorbs repeat Dock reopens, and defers
    /// windowless new-window commands, so none of them can race the restore —
    /// neither its per-profile session commit nor the replay itself. Read by
    /// `AppController`.
    ///
    /// It also freezes cross-launch snapshot persistence for its whole span
    /// (`mayPersistSlotsSnapshot`), which is the largest thing hanging off it:
    /// a replay in progress is a half-restored group, and the reopen writes
    /// once from the completion below instead. So a completion that never
    /// arrived would not merely wedge the three gates above — it would stop
    /// this session persisting its layout at all. The transitions are logged
    /// for exactly that reason.
    private(set) var isSessionRestoreInFlight = false

    /// Whether the most recent reopen armed the eager filter — that is,
    /// whether it parked any of its saved windows as ghosts instead of
    /// replaying them. Written on every reopen from the one place that
    /// decides it (`armLazyRestoreForReopen`, true and false alike) and never
    /// cleared, which is why it is named for the LAST reopen rather than a
    /// current one: what makes it mean "this reopen" is that its only reader
    /// pairs it with `isSessionRestoreInFlight`, and that pairing is a rule
    /// on the table (`reopenDropsActivations`) rather than an assumption.
    /// Clearing it instead would buy a shorter-lived flag at the cost of a
    /// second and third write point — the transaction end and the watchdog —
    /// which is precisely the drift the single write point avoids.
    ///
    /// A latch rather than a live read of the switch: the switch is allowed
    /// to be flipped mid-run, and both directions have to leave the reopen
    /// already under way alone. A reopen that parked ghosts keeps the
    /// behavior it armed for even if the switch goes off underneath it, and a
    /// reopen that armed nothing must not acquire that behavior because the
    /// switch came on halfway through — with the switch off, a reopen is
    /// byte-for-byte what it was before the feature existed.
    private(set) var lastReopenArmedLazyRestore = false

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowserAccessStateDidChange),
            name: .browserAccessStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Bind eagerly only when browser access has a local-data owner. Guest
        // uses the stable default account; signed-in access uses the published
        // identity. The login-required state must not expose either store.
        refreshAccountBindingForBrowserAccess()
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
        // Resolved before the reattach binding below is dropped — it is the
        // binding that scopes the park set to this slot's entries.
        let parkedGhosts = parkedGhostEntries(for: slot)
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
        // Shrink the restore snapshot now that the slot is gone. Nothing on the
        // close path rewrites it from the settled layout — `unregisterWindow`
        // only flushes a debounced frame write, before it drains anything, and
        // the cascade and the deferred fullscreen reconcile both skip
        // themselves mid-cascade — so without this the snapshot kept describing
        // a window group the user closed, and it came back (as loose windows)
        // at the next cold launch.
        // When this was the LAST slot the write is a no-op: `persistSlotsSnapshot`
        // never overwrites a saved snapshot with an empty one, which is exactly
        // what freezes the final layout for a reopen.
        //
        // A removed slot also takes its parked ghost entries out of the record —
        // the decided Space-close semantics for a slot that goes away, its
        // ghosts going with it rather than resurfacing somewhere the user never
        // put them. They are named here and withheld from the write rather than
        // falling out of it: with ghosts belonging to the SAVED entry, the entry
        // this slot reattached to outlives the slot, and would otherwise be
        // written on its own (which is exactly what has to happen for every
        // other way a binding ends — see `plannedSnapshotEntries`).
        //
        // The chromium half is then ASKED for only if that write LANDED: the
        // parked windows leave the store and the session file together with the
        // record naming them, or they stay on both sides. Every reason a write
        // is refused (quit, a reopen still replaying, another slot draining,
        // nothing live left to write) is therefore a reason the ghosts stay
        // parked, with no second copy of that list on this side to fall out of
        // step — the copy that used to be here held one and a half of the four.
        //
        // Asked for, not guaranteed: `dropParkedGhosts` retires the Mac records
        // and then reports the chromium side best-effort, and its three refusals
        // (no bridge or too old, the profile failing to load, chromium holding no
        // such record) are logged and accepted. That residue predates this pairing
        // and is unchanged by it — what this gate closes is the Mac-side half,
        // where a refused write used to leave the record naming windows the store
        // had already dropped.
        if persistSlotsSnapshot(retiringGhostWindowIds: Set(parkedGhosts.keys)) {
            dropParkedGhosts(parkedGhosts, reason: "removeSlot")
        }
    }

    /// Reports a settled window-group close to Chromium, which holds every
    /// window close pending until it hears one — see `windowGroupCloseDidSettle`
    /// in `PhiChromiumBridgeHeader.h` for the contract.
    ///
    /// Silent while any slot is still draining its Space windows: reporting
    /// mid-cascade is exactly the per-window decision the deferral exists to
    /// avoid, and it would leave only the group's last Space restorable. Nothing
    /// is lost by staying silent — the draining slot's last window reports for
    /// everyone as it goes.
    func reportWindowGroupCloseSettled() {
        guard !slots.contains(where: { $0.isTearingDown }) else { return }
        ChromiumLauncher.sharedInstance().bridge?.windowGroupCloseDidSettle()
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
        guard isWindowlessWithHostedSlots else { return false }
        // Switch on: replay the whole closed window group (each Space with its
        // tabs, the active one visible, fullscreen preserved), mirroring a cold
        // start. Switch off keeps the plain single-window spawn.
        if SessionRestorePreference.isEnabled {
            // A restore from a rapid earlier Dock click is already running; its
            // windows will arrive, so don't start a second one.
            if isSessionRestoreInFlight {
                return true
            }
            return beginWindowlessSessionRestore()
        }
        return spawnPersistedSpaceWindow()
    }

    /// True when the app has no browser window but has hosted a slot window this
    /// session — the state a Dock reopen or an external-link open handles.
    /// Non-slot windows don't count as "windowless": a standalone Incognito
    /// window is focused by Chromium's own reopen, and shadow windows are
    /// invisible background hosts either way.
    private var isWindowlessWithHostedSlots: Bool {
        hasEverHostedSlotWindow && slots.isEmpty
            && !MainBrowserWindowControllersManager.shared.getAllWindows()
                .contains(where: { $0.browserType != .shadow })
    }

    /// Opens a single plain window on the persisted last-active Space — the
    /// windowless-reopen behavior when session restore is off, and the fallback
    /// when a restore turns up nothing. Returns false (declining the reopen)
    /// when no Space resolves, so Chromium's own handler runs.
    @discardableResult
    private func spawnPersistedSpaceWindow() -> Bool {
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

    /// Re-arms the persisted slot snapshot and asks Chromium to restore every
    /// last-active profile's session, mirroring a cold start. Marks a restore
    /// in flight until Chromium reports every profile's restore has settled
    /// (windows and tabs created, or skipped/refused); if nothing was
    /// restorable it falls back to a plain window. Returns true (handled).
    @discardableResult
    private func beginWindowlessSessionRestore() -> Bool {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            // No bridge to drive the restore; still open something.
            return spawnPersistedSpaceWindow()
        }
        // Re-arm the snapshot with the `restoredFromWindowId == 0` reattach
        // fallback disarmed — see `loadRestoreSnapshot(armReattachDeadline:)` for
        // why a mid-session re-arm must not arm it.
        loadRestoreSnapshot(armReattachDeadline: false)
        // Immediately — before Chromium is asked for anything, and before the
        // main thread disappears into the replay for the next second and a
        // half. It is not free: building and ordering in the windows measured
        // 40-50ms on a six-Space reopen, which pushes the first restored window
        // out by the same amount (the replay itself was unchanged). That is one
        // of the two prices of the feature, and part of the reason it is a
        // switch — the other is what the loading window costs while it is up,
        // see `ReopenLoadingWindow.featureEnabledKey`.
        showReopenLoadingWindows()
        isSessionRestoreInFlight = true
        // Both transitions are logged because snapshot persistence is frozen
        // between them: a completion that never arrives leaves an app that
        // looks entirely normal and silently never records its layout again,
        // and this pair is the only way to see that from a log bundle.
        AppLogInfo("[SpaceManager] windowless reopen — session restore in flight (snapshot writes deferred)")
        armSessionRestoreWatchdog()
        // Name the last-active Space's profile so Chromium replays it first:
        // its window is the one revealed the moment its own snapshot lands
        // (`frontRestoredWindowOnSnapshotApplied`), so it must not queue
        // behind sibling profiles' synchronous replays. Order only — every
        // profile still restores immediately; nil (unknown Space/profile)
        // keeps the stored order.
        let preferredProfileId = persistedActiveSpaceId
            .flatMap { boundProfileId(forSpaceId: $0) }
        // The lazy switch decides how much of the group comes back NOW:
        // armed, only the classifier's eager set replays and the rest park
        // as ghosts — recorded this tick, after `loadRestoreSnapshot` above
        // cleared the previous reopen's records. nil keeps the legacy full
        // replay: switch off, an older framework, or a classification that
        // would park nothing anyway.
        requestChromiumSessionRestore(
            bridge,
            preferredProfileId: preferredProfileId,
            eagerWindowIds: armLazyRestoreForReopen(bridge)
        ) { [weak self] restoredAnyWindow in
            DispatchQueue.main.async {
                guard let self else { return }
                // Every profile's restore has settled: started replays have
                // finished creating their windows and tabs, skipped or refused
                // profiles settled immediately. Both races the flag guards
                // against are over — the session-commit race, and the old
                // attempted-to-settled gap in which a second Dock click
                // re-began a restore that could only be refused (every profile
                // still mid-replay), reported restoredAny=false, and spawned a
                // stray plain window, while a windowless Cmd+N slipped past
                // `AppController`'s drop gate into the same replay.
                // Still clear here rather than on window arrival: a restore can
                // produce a window that claims no snapshot entry at all (an
                // emptied session's stand-in window claims by profile, and no
                // entry need match its profile), so clearing on arrival could
                // wedge the flag on. This completion is guaranteed to run
                // (every per-profile terminal — settled, skipped, refused, or
                // failed — signals the Chromium barrier), so the flag can
                // never get stuck.
                // Ahead of the two branches below, so an ordinary reopen has
                // persisted before either can run. The branches only fire when
                // the reopen did not produce a usable layout, and each writes
                // again on its own — a second write in a case that is already
                // the unusual one, which is the cheaper trade than holding the
                // transaction open across a spawn.
                self.endSessionRestoreTransaction(restoredAnyWindow: restoredAnyWindow)
                if !restoredAnyWindow {
                    // Nothing restorable: open a plain window.
                    self.spawnPersistedSpaceWindow()
                } else {
                    self.repairSlotsWithAbsentActiveSpace()
                }
                // Every window this reopen was going to produce now exists, so
                // the forced placement has nothing left to place and must stop
                // applying before a later spawn wants to position its own
                // window. The loading windows are a separate question, and a
                // slower one: they sit under the restored windows, so they are
                // torn down on whatever conservative deadline
                // `ReopenLoadingHandoff` names rather than here. Guaranteed to
                // run (every per-profile terminal signals the Chromium barrier,
                // see above).
                self.endReopenLoadingPlacements()
                self.recordReopenLoadingHandoff(.restoreSettled)
            }
        }
        return true
    }

    /// Sends the reopen's restore request over the bridge. A non-nil
    /// `eagerWindowIds` asks for the lazy-restore eager filter — only those
    /// previous-session windows rebuild now, the rest park as ghosts — and is
    /// honored only when the loaded Phi Framework knows the eager-filter
    /// selector. An older framework falls back to the legacy full-restore
    /// selector, every window rebuilding and nothing parking, which is the
    /// safe side of a framework/client version skew (the caller-side mirror
    /// of the coordinator's legacy mainBrowserWindowCreated entry points).
    /// nil always takes the legacy selector.
    private func requestChromiumSessionRestore(
        _ bridge: PhiChromiumBridgeProtocol,
        preferredProfileId: String?,
        eagerWindowIds: [NSNumber]?,
        completion: @escaping (Bool) -> Void
    ) {
        let eagerSelector = #selector(PhiChromiumBridgeProtocol
            .restorePreviousSession(withPreferredProfile:eagerWindowIds:completion:))
        if let eagerWindowIds {
            if bridge.responds(to: eagerSelector) {
                bridge.restorePreviousSession(
                    withPreferredProfile: preferredProfileId,
                    eagerWindowIds: eagerWindowIds,
                    completion: completion
                )
                return
            }
            // Not silent: an eager set was asked for and cannot be honored.
            AppLogWarn("[SpaceManager] eager-filter selector unavailable (older framework) — restoring everything")
        }
        bridge.restorePreviousSession(
            withPreferredProfile: preferredProfileId,
            completion: completion
        )
    }

    /// Ends the reopen's restore transaction: the live layout is trustworthy
    /// again, and the one snapshot write the whole transaction was deferring
    /// lands now.
    ///
    /// The two halves are one method rather than two adjacent statements
    /// because splitting them is silent and total: clear the flag without
    /// writing and the reopen never persists at all — for the life of the
    /// process, since nothing else rewrites the record until the next layout
    /// change — while writing before the clear is a write that refuses itself
    /// (`mayPersistSlotsSnapshot`). Neither shows up in a test; no test in this
    /// repo constructs a `SpaceManager`. Keeping them inseparable is the guard.
    ///
    /// Called once, from the completion that reports every profile settled.
    /// A reopen that never settles never calls it, and the last complete
    /// snapshot stands — which is the point of deferring in the first place.
    private func endSessionRestoreTransaction(restoredAnyWindow: Bool) {
        sessionRestoreWatchdog?.cancel()
        sessionRestoreWatchdog = nil
        isSessionRestoreInFlight = false
        AppLogInfo("[SpaceManager] windowless reopen — restore settled (restoredAnyWindow=\(restoredAnyWindow)); writing the slot snapshot")
        persistSlotsSnapshot()
    }

    /// Arms the deadline that bounds the freeze. Re-arming replaces any
    /// previous one, so a reopen that somehow begins twice ends up with a
    /// single pending deadline rather than two.
    private func armSessionRestoreWatchdog() {
        sessionRestoreWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionRestoreWatchdog = nil
            let outcome = Self.sessionRestoreWatchdogOutcome(
                isSessionRestoreInFlight: self.isSessionRestoreInFlight)
            guard outcome.releasesFreeze else { return }
            // Loud on purpose: reaching this means the restore never reported
            // every profile settled, which is a Chromium-side fault this side
            // cannot see any other way.
            AppLogError("[SpaceManager] windowless reopen never settled within \(Self.sessionRestoreWatchdogDeadline)s — releasing the snapshot freeze without writing")
            self.isSessionRestoreInFlight = false
        }
        sessionRestoreWatchdog = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionRestoreWatchdogDeadline, execute: work)
    }

    /// Puts a loading window on screen for every saved slot that qualifies,
    /// each on its own remembered frame. Called at the top of a windowless
    /// reopen's restore, before any Chromium work is requested.
    ///
    /// The frames come from the snapshot already clamped to the screens
    /// attached now (`loadRestoreSnapshot`), and the slot each entry reopens
    /// into is forced onto the same rect in `slotForRestoreIndex` — that
    /// pairing, not a prediction, is what makes the hand-off jump-free.
    private func showReopenLoadingWindows() {
        // The switch decides before anything is read or built — in particular
        // before the restore-preference read, which is a round trip into
        // Chromium — so a run with it off does no work here at all. It is also
        // passed into `shouldShow`, so the whole rule stays in the one place
        // that is testable rather than living half here and half there.
        let featureEnabled = ReopenLoadingWindow.isFeatureEnabled
        guard featureEnabled else { return }
        // A rapid second reopen re-enters with fresh entries and fresh indices;
        // nothing from the previous pass may outlive them.
        finishReopenLoadingRun()
        let sessionRestoreEnabled = SessionRestorePreference.isEnabled
        let isWindowlessReopen = isWindowlessWithHostedSlots
        for index in restoreEntries.indices {
            let entry = restoreEntries[index]
            guard ReopenLoadingWindow.shouldShow(
                featureEnabled: featureEnabled,
                sessionRestoreEnabled: sessionRestoreEnabled,
                isWindowlessReopen: isWindowlessReopen,
                snapshotFrame: entry.frame,
                slotWasFullScreen: entry.wasFullScreen
            ), let frame = entry.frame else { continue }
            // Everything the window is drawn from comes from the entry, which
            // read it off the window this one stands in for. The tint is the
            // exception and cannot be stored: it has to be resolved now, or a
            // theme changed while the app had no windows would be a stale
            // colour on the rect. Resolved only when there will be a band —
            // for a Space with a pinned theme it is a defaults read and a whole
            // `Theme` copy, on the one path this feature is measured on.
            let bandWidth = ReopenLoadingWindow.sidebarBandWidth(
                remembered: entry.sidebarWidth, inWindowOfWidth: frame.width)
            let window = ReopenLoadingWindow(
                frame: frame,
                sidebarWidth: entry.sidebarWidth,
                sidebarTint: bandWidth == nil
                    ? nil : sidebarTint(forSpaceId: entry.activeSpaceId),
                trafficLightOrigin: entry.trafficLightOrigin)
            // Regardless: the reopen runs during app activation, and waiting to
            // be frontmost the ordinary way would give up the head start this
            // window exists for.
            window.orderFrontRegardless()
            reopenLoadingWindowsByRestoreIndex[index] = window
            // What the snapshot supplied, not what the window did with it:
            // "the field was never recorded" and "it was recorded as zero" are
            // different states and a log bundle has to tell them apart. The
            // lights say `none` where this OS draws none at all, which is not
            // the same as falling back to the copied constant.
            let bandNote = entry.sidebarWidth
                .map { "\($0)->\(bandWidth.map(String.init(describing:)) ?? "none")" }
                ?? "unrecorded"
            let lightsNote = ReopenLoadingWindow
                .trafficLightOrigin(remembered: entry.trafficLightOrigin)
                .map { _ in entry.trafficLightOrigin == nil ? "copied" : "remembered" } ?? "none"
            // The one of the three that reports what the WINDOW did rather than
            // what the snapshot supplied, because unlike the band and the
            // lights the indicator has no snapshot input to report. The rate is
            // in the line because it is the only number here that costs
            // anything, so it is what a log bundle would need to show.
            let dotsNote = window.activityDots == nil
                ? "none" : "\(ReopenLoadingWindow.activityStepsPerSecond)/s"
            AppLogInfo("[SpaceManager] reopen: loading window shown at \(NSStringFromRect(frame)) band=\(bandNote) lights=\(lightsNote) dots=\(dotsNote)")
        }
        guard !reopenLoadingWindowsByRestoreIndex.isEmpty else { return }
        reopenLoadingRunActive = true
        let now = Date()
        let handoff = ReopenLoadingHandoff(startedAt: now)
        reopenLoadingHandoff = handoff
        applyReopenLoadingHandoff(handoff.reconsider(at: now))
    }

    /// Feeds the hand-off tracker a fact and acts on its answer.
    private func recordReopenLoadingHandoff(_ fact: ReopenLoadingHandoff.Fact) {
        guard let handoff = reopenLoadingHandoff else { return }
        applyReopenLoadingHandoff(handoff.record(fact, at: Date()))
    }

    private func applyReopenLoadingHandoff(_ outcome: ReopenLoadingHandoff.Outcome) {
        switch outcome {
        case .alreadyTornDown:
            break
        case .tearDown:
            finishReopenLoadingRun()
        case .wait(let seconds):
            let work = DispatchWorkItem { [weak self] in
                guard let self, let handoff = self.reopenLoadingHandoff else { return }
                self.applyReopenLoadingHandoff(handoff.reconsider(at: Date()))
            }
            reopenLoadingHandoffWait?.cancel()
            reopenLoadingHandoffWait = work
            // Late is harmless by construction: the loading window is under the
            // restored window by now, so the restore saturating the main thread
            // and pushing this out only delays something already invisible.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /// A restored window the user will actually see has registered into one of
    /// this reopen's slots. Reported by the slot rather than looked up, because
    /// only the slot knows whether the window it just took is the visible one
    /// or a concealed sibling.
    fileprivate func noteReopenLoadingHandoffWindowRegistered() {
        guard let handoff = reopenLoadingHandoff else { return }
        let outcome = handoff.record(.restoredWindowRegistered, at: Date())
        // This runs inside Chromium's synchronous window-created callback,
        // where the convention in this file is to defer anything that closes
        // windows or rewrites slot state by a turn (see
        // `pendingCloseOnReplacementBySpaceId`). Only the backstop can answer
        // `.tearDown` to a registration — a window arriving more than
        // `ReopenLoadingHandoff.backstop` after the loading windows went up —
        // and that is precisely the answer that must not run re-entrantly: it
        // would drop every slot's forced placement while the burst is still
        // delivering windows onto it.
        if case .tearDown = outcome {
            DispatchQueue.main.async { [weak self] in self?.finishReopenLoadingRun() }
            return
        }
        applyReopenLoadingHandoff(outcome)
    }

    /// Stops the slots forcing this reopen's remembered frame on windows that
    /// register from here on. Runs when the restore settles — every window this
    /// reopen promised anything about now exists — and deliberately NOT with
    /// the loading window teardown, which outlives it (see
    /// `ReopenLoadingHandoff`). Holding the override past the restore would
    /// drag a later, unrelated spawn onto the reopen rect.
    private func endReopenLoadingPlacements() {
        guard reopenLoadingRunActive else { return }
        for slot in slots {
            slot.endReopenPlacementOverride()
        }
    }

    /// Ends this reopen's loading-window hand-off: closes every loading window
    /// still up, here and on the slots, and drops any forced placement still in
    /// force. Idempotent, and a single flag test when the feature is off.
    private func finishReopenLoadingRun() {
        guard reopenLoadingRunActive else { return }
        reopenLoadingRunActive = false
        reopenLoadingHandoffWait?.cancel()
        reopenLoadingHandoffWait = nil
        reopenLoadingHandoff = nil
        for window in reopenLoadingWindowsByRestoreIndex.values {
            window.close()
        }
        reopenLoadingWindowsByRestoreIndex.removeAll()
        for slot in slots {
            slot.endReopenLoadingHandover()
        }
        AppLogInfo("[SpaceManager] reopen: loading window hand-off finished")
    }

    /// Makes every still-registered slot show the Space it says it is showing,
    /// once a reopen restore has settled.
    ///
    /// A slot is seeded with the Space its snapshot entry had visible, but that
    /// Space's window does not always come back: a window saved with an empty
    /// tab list is dropped when the session is read back, so a slot whose
    /// visible Space was left on a placeholder page restores its OTHER Spaces
    /// only. The slot then reports a Space that owns no window — its indicator,
    /// name and tint name one Space while the tabs on screen belong to another
    /// — and `reconcileRestoreVisibility` bails on every pass (it has no active
    /// window to front), so the restored windows stay concealed until the reveal
    /// ladder's blind catch-all surfaces all of them at once, seconds later.
    ///
    /// Per slot that owns windows but none for its active Space:
    ///   * the active Space can still be surfaced here → spawn its window
    ///     through the slot's own `activate`, so it registers back into THIS
    ///     slot (never a second one) and the windows already there stay hidden
    ///     siblings. This is what Chromium's own fallback window does for a
    ///     profile whose session held nothing restorable (see
    ///     `restoreFallbackWindowId`); doing it here too means the same user
    ///     gesture no longer gives two different results depending on whether
    ///     that profile happened to hold another restorable window.
    ///   * otherwise (the Space was deleted, or is an Incognito / agent Space
    ///     and never an automatic destination) → switch the slot to a Space
    ///     that did come back, taking the first present one in snapshot order.
    ///
    /// Driven by the restore-settled signal rather than the visibility
    /// reconcile's timed ladder: that ladder arms on every Dock reopen whether
    /// or not a restore runs, keeps ticking on slots already dropped from the
    /// registry, and its early ticks fire while a sibling profile's window is
    /// still legitimately in flight — repairing on one of those would freeze a
    /// transient into a permanent misplacement. Idempotent: a slot whose active
    /// Space owns a window is left alone, so this is a no-op whenever the
    /// fallback window above already brought that Space back.
    private func repairSlotsWithAbsentActiveSpace() {
        // The Spaces an automatic switch may land on: still in the store, and
        // neither Incognito nor agent-owned (both are deliberate destinations
        // only — see `isAutomaticSwitchTarget`). Screens the Space being brought
        // back AND the stand-in: the snapshot filters Incognito Spaces out of
        // its window map but not agent ones, so an agent Space can come back
        // with the rest of the slot.
        let switchTargetIds = Set(
            spaces.filter { isAutomaticSwitchTarget($0) }.map(\.spaceId)
        )
        for slot in slots {
            let presentSpaceIds = slot.spaceIdsWithWindow
            guard !slot.isTearingDown,
                  let activeId = slot.activeSpaceId,
                  !presentSpaceIds.isEmpty,
                  !presentSpaceIds.contains(activeId) else { continue }
            // Spawning the absent Space also needs its window to be owned by no
            // OTHER slot — a Space maps 1:1 to a Chromium window, so a second
            // window for it would put the same Space on screen twice.
            let ownedElsewhere = slots.contains {
                $0 !== slot && $0.windowController(for: activeId) != nil
            }
            let target: String
            if switchTargetIds.contains(activeId), !ownedElsewhere {
                AppLogInfo("[SpaceManager] restore settled: no window for slot's active Space \(activeId) — spawning it")
                target = activeId
            } else if let present = Self.firstPresentSpaceInSnapshotOrder(
                windowMaps: restoreEntries.map(\.windowMap),
                presentSpaceIds: presentSpaceIds.intersection(switchTargetIds)
            ) {
                // Snapshot order rather than the store-wide fallback the other
                // "the active Space went away" paths resolve to
                // (`handleSpacesUpdate`, `spawnPersistedSpaceWindow`): the
                // stand-in has to be a Space whose window is in THIS slot, and
                // the same one every time this state arises.
                AppLogInfo("[SpaceManager] restore settled: slot's active Space \(activeId) cannot be surfaced — showing restored Space \(present) instead")
                target = present
            } else {
                AppLogWarn("[SpaceManager] restore settled: slot's active Space \(activeId) cannot be surfaced and the snapshot names none of its restored Spaces — left as is")
                continue
            }
            // Re-assert the slot's one-visible-window invariant once the target
            // window is up: the passes that bailed never ran the sibling sweep,
            // and never re-entered fullscreen either — `reconcileRestoreVisibility`
            // is the only caller of `applyPendingRestoreFullScreen`, and a slot
            // left with that marker set also stops re-arming `.moveToActiveSpace`
            // on its hidden siblings. Armed from the swap's settle callback (the
            // spawn path fires it once the new window is revealed, which an async
            // profile load can push past this turn) and, for a repoint onto a
            // window that is already the visible one, right after `activate`
            // returns. Whichever runs first arms the coalesced ladder; the other
            // is a no-op. Never armed while the window is still missing: such a
            // pass can only bail.
            slot.activate(spaceId: target, animated: false, onSwapSettled: { [weak slot] in
                slot?.scheduleRestoreVisibilityReconcile()
            })
            if let active = slot.activeSpaceId, slot.windowController(for: active) != nil {
                slot.scheduleRestoreVisibilityReconcile()
            }
        }
    }

    /// If the app is windowless with a restorable history and the switch is on,
    /// begins a session restore so a subsequently-forwarded external link lands
    /// in the restored active window instead of a bare new one. A no-op when
    /// not eligible or a restore is already in flight; the caller queues its
    /// URLs to forward once a window exists either way.
    func beginSessionRestoreForExternalOpenIfEligible() {
        guard isWindowlessWithHostedSlots, SessionRestorePreference.isEnabled,
              !isSessionRestoreInFlight else { return }
        beginWindowlessSessionRestore()
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
    /// `restoreFallbackWindowId` is the third shape: restore's own stand-in
    /// window for a profile whose session held nothing restorable. It also
    /// claims by profile, but needs no grace period — the id itself says the
    /// window is a restore product, which a user-opened window can never claim
    /// to be. Without it a reopened slot whose visible Space was emptied comes
    /// back split: this window mints its own slot, and the sibling profile's
    /// window seeds a second slot on a Space that never arrives.
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
        // Primary: exact previous-session windowId match. Positive ids only —
        // a SessionID is always positive, so both `0` and the reserved
        // `restoreFallbackWindowId` name a window that re-created no saved
        // window and must never be looked up as one.
        if restoredFromWindowId > 0,
           let index = restoreIndexByWindowId[restoredFromWindowId],
           index < restoreEntries.count,
           let spaceId = restoreEntries[index].windowMap[restoredFromWindowId] {
            restoreIndexByWindowId.removeValue(forKey: restoredFromWindowId)
            return (slotForRestoreIndex(index, fallbackSpaceId: spaceId), spaceId)
        }
        // Fallback: reattach by PROFILE instead of by id. Open to the two window
        // shapes that carry no usable previous-session id:
        //
        //   * `restoreFallbackWindowId` — restore's own stand-in window for a
        //     profile whose session held nothing restorable. Self-identifying,
        //     so no grace period is consulted: a mid-session reopen leaves the
        //     deadline deliberately disarmed, and this window still has to find
        //     its slot.
        //   * `0` within the launch grace period — Chromium's multi-profile
        //     startup opens one fresh window per last-open profile.
        //
        // A NON-zero id that misses the primary lookup is a window genuinely not
        // in the snapshot (e.g. opened while the live count was below the
        // session peak, so the monotonic persist guard never recorded it). It
        // must NOT be reattached by profile to some stale closed slot — that
        // would surface it as a closed Space (and force fullscreen). Returning
        // nil lets the coordinator mint a fresh slot on the resolved Space.
        // With the restore switch off there are no restored windows to
        // reattach: the only zero-id window a cold launch produces is its
        // plain NTP window, and profile-matching it against a stale snapshot
        // entry would land it on the previous session's Space and inherit
        // that entry's fullscreen marker. Checked here rather than when the
        // snapshot loads: `bind(to:)` runs before Chromium is up, where the
        // preference read falls back to its enabled default.
        let claimsByProfile: Bool = {
            if restoredFromWindowId == Self.restoreFallbackWindowId { return true }
            guard restoredFromWindowId == 0,
                  let deadline = restoreReattachDeadline else { return false }
            return Date() < deadline
        }()
        guard claimsByProfile,
              SessionRestorePreference.isEnabled,
              !profileId.isEmpty else { return nil }
        // Which of the profile's unclaimed snapshot windows this one takes over
        // decides both the Space the user gets back and whose fullscreen marker
        // the slot inherits — and a profile can own several (two of its Spaces
        // surfaced from one slot, or Spaces sitting in different slots). Rank:
        // the window whose Space was the visible one in its own entry, then an
        // entry that holds the persisted last-active Space, then **snapshot
        // order** — saved slot order, then previous-session window id. A total
        // order, so the pick never depends on dictionary iteration order.
        //
        // Snapshot order is the project's single deterministic ordering over
        // snapshot windows: anything else that has to pick among a saved slot's
        // windows uses this one rather than inventing a near-synonym.
        let persistedActive = persistedActiveSpaceId
        var candidates: [(key: (Int, Int, Int, Int),
                          index: Int, windowId: Int, spaceId: String)] = []
        for index in restoreEntries.indices {
            let entry = restoreEntries[index]
            let holdsPersistedActive = persistedActive.map {
                entry.windowMap.values.contains($0)
            } ?? false
            for (windowId, spaceId) in entry.windowMap {
                guard restoreIndexByWindowId[windowId] == index,
                      boundProfileId(forSpaceId: spaceId) == profileId else { continue }
                candidates.append((key: (spaceId == entry.activeSpaceId ? 0 : 1,
                                         holdsPersistedActive ? 0 : 1,
                                         index,
                                         windowId),
                                   index: index,
                                   windowId: windowId,
                                   spaceId: spaceId))
            }
        }
        guard let pick = candidates.min(by: { $0.key < $1.key }) else { return nil }
        restoreIndexByWindowId.removeValue(forKey: pick.windowId)
        return (slotForRestoreIndex(pick.index, fallbackSpaceId: pick.spaceId), pick.spaceId)
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
        // Lend the slot the loading window standing in for it, and the frame it
        // sits on: the slot has to come back ON that frame, and it is the slot
        // that gets to see the restored window this loading window has to drop
        // behind. Driven by the window's existence rather than by re-deciding
        // eligibility, so the loading window and the forced placement are one
        // decision — no loading window, no override, and the slot takes
        // Chromium's replayed bounds exactly as it does today.
        if let window = reopenLoadingWindowsByRestoreIndex[index],
           let frame = restoreEntries[index].frame {
            slot.adoptReopenLoadingWindow(window, placedAt: frame)
        }
        restoredSlotsByIndex[index] = slot
        return slot
    }

    /// The first of `presentSpaceIds` in **snapshot order** — saved slot order,
    /// then previous-session window id — or nil when the snapshot names none of
    /// them. `windowMaps` holds each snapshot entry's previous-session windowId
    /// → spaceId map, in saved order.
    ///
    /// Snapshot order is the one ordering the project defines over snapshot
    /// windows: `claimRestoredWindow` sorts by it too, below its own two
    /// priority levels, so its ranking key spells the same rule out rather than
    /// calling this — the two answer different questions (rank all of a
    /// profile's candidates vs. take the first Space present in one slot).
    /// Independent of dictionary iteration order either way, so the pick is
    /// reproducible instead of whatever a hash walk happens to yield first.
    static func firstPresentSpaceInSnapshotOrder(
        windowMaps: [[Int: String]],
        presentSpaceIds: Set<String>
    ) -> String? {
        for windowMap in windowMaps {
            for windowId in windowMap.keys.sorted() {
                if let spaceId = windowMap[windowId],
                   presentSpaceIds.contains(spaceId) {
                    return spaceId
                }
            }
        }
        return nil
    }

    /// What a lazy reopen does with each window of the restore snapshot.
    struct RestoreWindowClassification: Equatable {
        /// Previous-session window ids the reopen replays immediately.
        ///
        /// Exhaustive only over windows the snapshot names. Chromium's replay
        /// filter parks exactly the NORMAL saved windows missing from this
        /// set and restores every other kind eagerly on its own — so a
        /// popup or app window (never in a snapshot) is safe, while a normal
        /// saved window absent from the snapshot would have no protection
        /// here. Keeping ghost entries in the persisted snapshot
        /// (`persistedWindowMap`) is what keeps that absence from arising.
        let eagerWindowIds: Set<Int>
        /// Previous-session windowId → spaceId for every window the reopen
        /// parks in the session file instead. The value is the Space a later
        /// activation materializes the window from — and what
        /// `persistSlotsSnapshot` writes back into the slot's windowMap so
        /// that mapping survives the persist cycle that follows the reopen.
        let ghostSpaceIdsByWindowId: [Int: String]
    }

    /// Splits the restore snapshot's windows into the set a lazy reopen
    /// replays now (eager) and the set it parks behind their Spaces (ghosts).
    ///
    /// The costs are asymmetric — an extra eager window costs its replay
    /// time, while a wrong ghost strands a window nothing can navigate to —
    /// so every rule fails toward eager, and only a window whose Space is
    /// provably on the strip may park:
    ///
    ///   * The slot's landing Space (`activeSpaceId`) replays: it is what the
    ///     reopened slot shows first.
    ///   * A window whose Space is alive but not the landing point parks.
    ///   * A window whose Space is not in the store replays — deleted and
    ///     not-yet-delivered look the same here, which is exactly why absence
    ///     must widen the eager set rather than park anything. Callers owe
    ///     this the CONVERGED store; a partial first delivery only costs
    ///     replay time.
    ///   * A slot whose landing Space owns no window promotes its first
    ///     surviving Space's window — snapshot order within one slot is
    ///     ascending previous-session window id, the same rule
    ///     `firstPresentSpaceInSnapshotOrder` spells out — so a Dock reopen
    ///     always brings back at least one window per slot.
    ///   * Windows on Incognito Spaces (by id shape) and agent Spaces (by
    ///     `agentSpaceIds`) join neither set: neither kind exists in the
    ///     saved session, so eager would name a window the replay cannot
    ///     find, and ghost would mint an entry no materialization can ever
    ///     satisfy. An agent Space already orphan-swept from the store is
    ///     indistinguishable from a deleted one and falls back to eager,
    ///     which is the harmless direction — no saved window matches it.
    ///
    /// Pure and static so the rules can be pinned down by table
    /// (`RestoreWindowClassificationTests`); the reopen wiring feeds it the
    /// decoded snapshot and the live store.
    static func classifyRestoreWindows(
        slots: [(activeSpaceId: String?, windowMap: [Int: String])],
        liveSpaceIds: Set<String>,
        agentSpaceIds: Set<String>
    ) -> RestoreWindowClassification {
        var eagerWindowIds: Set<Int> = []
        var ghostSpaceIdsByWindowId: [Int: String] = [:]
        for slot in slots {
            let eligible = slot.windowMap.filter { entry in
                !isIncognitoSpaceId(entry.value) && !agentSpaceIds.contains(entry.value)
            }
            var slotGhosts: [Int: String] = [:]
            for (windowId, spaceId) in eligible {
                if spaceId == slot.activeSpaceId {
                    eagerWindowIds.insert(windowId)
                } else if liveSpaceIds.contains(spaceId) {
                    slotGhosts[windowId] = spaceId
                } else {
                    eagerWindowIds.insert(windowId)
                }
            }
            // The per-slot floor: no landing window (the entry predates
            // `activeSpaceId`, its Space's window was closed separately, or
            // the landing Space was excluded above) means the would-be ghosts
            // give up their first window in snapshot order. Nothing to
            // promote means everything eligible was already eager.
            let hasLandingWindow = slot.activeSpaceId.map { landing in
                eligible.values.contains(landing)
            } ?? false
            if !hasLandingWindow, let promoted = slotGhosts.keys.min() {
                eagerWindowIds.insert(promoted)
                slotGhosts.removeValue(forKey: promoted)
            }
            // Window ids are unique across slots; keeping the first on a
            // (corrupt) duplicate makes the answer independent of slot order
            // rather than last-writer-wins.
            ghostSpaceIdsByWindowId.merge(slotGhosts) { first, _ in first }
        }
        // Same corrupt shape, other axis: an id one slot replays and another
        // would park. The sets are a partition to every consumer, and eager
        // is the safe side of it, so eager wins.
        return RestoreWindowClassification(
            eagerWindowIds: eagerWindowIds,
            ghostSpaceIdsByWindowId: ghostSpaceIdsByWindowId.filter {
                !eagerWindowIds.contains($0.key)
            }
        )
    }

    /// Mac-side switch for the lazy Space reopen (standard defaults, off by
    /// default). Gates whether the next windowless reopen computes and sends
    /// an eager set — and, through the latch that reopen leaves behind
    /// (`lastReopenArmedLazyRestore`), whether that reopen's replay also drops
    /// activations while it runs (`reopenDropsActivations`). Those are the
    /// two things it decides, and both are decided per reopen at its start.
    ///
    /// What it does NOT gate: a ghost already parked stays materializable,
    /// droppable, persisted and pinned for its whole life regardless, so
    /// flipping the switch off mid-run cannot strand records that already
    /// exist.
    static let lazySpaceRestoreEnabledKey = "PhiLazySpaceRestoreEnabled"
    static var isLazySpaceRestoreEnabled: Bool {
        UserDefaults.standard.bool(forKey: lazySpaceRestoreEnabledKey)
    }

    /// Whether the loaded framework knows the whole lazy-restore selector
    /// family. Probed as a family, not per call: arming with a framework
    /// that cannot materialize would strand every parked window, and one
    /// that cannot drop would leak session records on every invalidation —
    /// so an older framework simply keeps full restores (the caller-side
    /// mirror of the coordinator's legacy-entry-point tolerance).
    private static func bridgeSupportsLazyRestore(
        _ bridge: PhiChromiumBridgeProtocol
    ) -> Bool {
        bridge.responds(to: #selector(PhiChromiumBridgeProtocol
            .restorePreviousSession(withPreferredProfile:eagerWindowIds:completion:)))
            && bridge.responds(to: #selector(PhiChromiumBridgeProtocol
                .materializeGhostWindow(_:profileId:completion:)))
            && bridge.responds(to: #selector(PhiChromiumBridgeProtocol
                .dropGhostWindow(_:profileId:completion:)))
    }

    /// The eager set a reopen sends over the bridge, or nil to keep the
    /// legacy full restore. nil when the switch is off or the framework
    /// predates the selector family — and also when the classification
    /// parked nothing: the eager set is a whitelist to the replay (a saved
    /// window outside it parks), so arming then buys nothing over a full
    /// replay and only widens what a snapshot gap could fall through.
    /// Sorted ascending so the wire order is deterministic. Pure and static
    /// so the gate is pinned by table (`LazySpaceRestoreWiringTests`).
    static func armedEagerWindowIds(
        featureEnabled: Bool,
        bridgeSupportsLazyRestore: Bool,
        classification: RestoreWindowClassification
    ) -> [NSNumber]? {
        guard featureEnabled, bridgeSupportsLazyRestore,
              !classification.ghostSpaceIdsByWindowId.isEmpty else { return nil }
        return classification.eagerWindowIds.sorted().map { NSNumber(value: $0) }
    }

    /// Whether an activation arriving right now must be dropped instead of
    /// switching, spawning or materializing: only while an ARMED reopen is
    /// still replaying. Such a replay is rebuilding part of the group while
    /// the rest sits parked in the session file, and every activation shape
    /// collides with that — a switch and a spawn race the replay and its
    /// per-profile session commit, and a materialization asks Chromium to
    /// rebuild from a session file the replay is still reading. The restore's
    /// own follow-ups run after the flag clears, and a dropped store
    /// reconcile re-runs on the next store emission, so nothing is lost.
    ///
    /// `AppController`'s windowless-command drop gate closes the first of
    /// those races for New Window / New Tab, and it does so for EVERY reopen,
    /// not just an armed one. That asymmetry is deliberate, not an oversight
    /// to harmonize away: that gate shipped before this feature, so leaving
    /// it alone is what "the switch off means today's behavior" requires,
    /// while this one is new and therefore has to be earned by arming.
    ///
    /// An unarmed reopen parks nothing, so its replay is the one this app has
    /// always run and activations keep meeting it exactly as they always did.
    /// That is what makes the switch a real rollback: off (or an older
    /// framework, or a classification that parked nothing) is today's
    /// behavior, here as everywhere else. Pure and static so the gate is
    /// pinned by table.
    static func reopenDropsActivations(isSessionRestoreInFlight: Bool,
                                       isLazyReopenArmed: Bool) -> Bool {
        isSessionRestoreInFlight && isLazyReopenArmed
    }

    /// Classifies this reopen's snapshot and, when the reopen should be
    /// lazy, records the park set and returns the eager set for the bridge;
    /// nil keeps the legacy full restore. Must run AFTER `loadRestoreSnapshot`
    /// in the same tick: loading clears `parkedGhostSpaceIdsByWindowId`, and
    /// the write below is what arms this reopen's ghosts.
    private func armLazyRestoreForReopen(
        _ bridge: PhiChromiumBridgeProtocol
    ) -> [NSNumber]? {
        // R2's liveness check and R5's agent exclusion read the live store —
        // converged by now on a mid-session reopen; a gap only widens the
        // eager set (fail-eager). Agent Spaces are known two ways: the
        // persisted model signature, and the live task registry (a
        // PERSISTENT agent Space mid-task looks regular by signature).
        let agentSpaceIds = Set(spaces.filter { space in
            space.isAgentSpace == true || MainActor.assumeIsolated {
                AgentSpaceManager.shared.isAgentSpace(space.spaceId)
            }
        }.map(\.spaceId))
        let classification = Self.classifyRestoreWindows(
            slots: restoreEntries.map {
                (activeSpaceId: $0.activeSpaceId, windowMap: $0.windowMap)
            },
            liveSpaceIds: Set(spaces.map(\.spaceId)),
            agentSpaceIds: agentSpaceIds
        )
        let armed = Self.armedEagerWindowIds(
            featureEnabled: Self.isLazySpaceRestoreEnabled,
            bridgeSupportsLazyRestore: Self.bridgeSupportsLazyRestore(bridge),
            classification: classification
        )
        // The single write point for the latch, on both answers: what the
        // reopen sends over the bridge and what it tells `activate` for the
        // rest of its replay are decided here, together, and cannot drift.
        lastReopenArmedLazyRestore = armed != nil
        guard let eagerWindowIds = armed else { return nil }
        parkedGhostSpaceIdsByWindowId = classification.ghostSpaceIdsByWindowId
        // Logged like the restore transitions: the park set decides what the
        // reopen deliberately does NOT bring back, which a log bundle must
        // be able to answer.
        AppLogInfo("[SpaceManager] lazy reopen armed: \(eagerWindowIds.count) eager, \(parkedGhostSpaceIdsByWindowId.count) parked")
        return eagerWindowIds
    }

    /// The parked ghost window an activation of `spaceId` materializes, or
    /// nil when none is parked. Lowest id on a corrupt duplicate (two parked
    /// ids naming one Space) so the pick is deterministic rather than a hash
    /// walk — the same ordering rule every other snapshot pick uses. Pure
    /// and static so the rule is pinned by table.
    static func parkedGhostWindowId(in parkedGhosts: [Int: String],
                                    forSpaceId spaceId: String) -> Int? {
        parkedGhosts.filter { $0.value == spaceId }.keys.min()
    }

    /// The parked ghost a live activation of `spaceId` should materialize,
    /// or nil. Read by `SpaceWindowSlot.activate` (the F4 ghost row) and by
    /// `changeProfile` (which materializes before it re-binds).
    func parkedGhostWindowId(forSpaceId spaceId: String) -> Int? {
        Self.parkedGhostWindowId(in: parkedGhostSpaceIdsByWindowId,
                                 forSpaceId: spaceId)
    }

    /// Retires the ghost bookkeeping for one parked window. Both records go
    /// together: the park entry is what routes an activation to
    /// materialization, and the unclaimed restore index is what folds the
    /// entry into the persisted snapshot — whether the window just
    /// materialized (it is live now; the live map speaks for it) or its
    /// record turned out stale (nothing can ever satisfy it), keeping either
    /// half would hand the next persist or reopen a window that no longer
    /// exists to park.
    fileprivate func consumeParkedGhost(windowId: Int) {
        parkedGhostSpaceIdsByWindowId.removeValue(forKey: windowId)
        restoreIndexByWindowId.removeValue(forKey: windowId)
    }

    /// Retires parked ghosts (windowId → spaceId) everywhere they are
    /// recorded: the Mac bookkeeping now, and the chromium store + session
    /// file once each ghost's profile is loaded. This is the wiring half of
    /// Space-close semantics for a window that exists only in the session
    /// file — its Space was deleted, or the window group it was saved with
    /// went away — and without the chromium half the next unfiltered
    /// restore would replay the window as a loose one.
    ///
    /// Profiles are resolved synchronously, before the caller mutates the
    /// store (a deleted Space's row is gone by the time the async load
    /// completes). A drop the chromium side refuses (record already gone,
    /// profile never loaded this run) is logged and accepted: the Mac
    /// records are gone either way, and the residue self-heals at the next
    /// cold start's unfiltered replay.
    fileprivate func dropParkedGhosts(_ ghosts: [Int: String], reason: String) {
        guard !ghosts.isEmpty else { return }
        // Absence from this map IS the "no profile resolves" case below.
        let profileIdsByWindowId: [Int: String] = ghosts.compactMapValues {
            boundProfileId(forSpaceId: $0)
        }
        for windowId in ghosts.keys {
            consumeParkedGhost(windowId: windowId)
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol
                  .dropGhostWindow(_:profileId:completion:))) else {
            AppLogWarn("[SpaceManager] \(reason): bridge unavailable or too old — \(ghosts.count) ghost record(s) dropped Mac-side only")
            return
        }
        for (windowId, spaceId) in ghosts.sorted(by: { $0.key < $1.key }) {
            guard let profileId = profileIdsByWindowId[windowId],
                  !profileId.isEmpty else {
                AppLogWarn("[SpaceManager] \(reason): no profile resolves for ghost \(windowId) (Space \(spaceId)) — dropped Mac-side only")
                continue
            }
            bridge.ensureProfileLoaded(profileId) { success in
                guard success else {
                    AppLogWarn("[SpaceManager] \(reason): profile \(profileId) failed to load — ghost \(windowId) dropped Mac-side only")
                    return
                }
                bridge.dropGhostWindow(Int32(windowId), profileId: profileId) { ok in
                    if ok {
                        AppLogInfo("[SpaceManager] \(reason): dropped ghost window \(windowId) (Space \(spaceId))")
                    } else {
                        AppLogWarn("[SpaceManager] \(reason): chromium held no ghost \(windowId) (Space \(spaceId)) — record was stale")
                    }
                }
            }
        }
    }

    /// Where the coordinator's fallback mint may land, as a pure rule:
    /// `resolved` stands unless it names a Space whose window is parked —
    /// minting a fresh window there would stand beside the parked one as a
    /// doubled Space, and the live window would then shadow the ghost for
    /// good — in which case the first clear automatic-switch target of the
    /// window's profile (strip order; any profile when unconstrained) takes
    /// its place. With no clear alternative the resolution stands: the
    /// doubled record is the lesser evil next to presenting the window as
    /// another profile's Space. Pure and static so the steering is pinned by
    /// table (`LazySpaceRestoreWiringTests`).
    static func steeredFallbackMintSpaceId(
        resolved: String,
        ghostSpaceIds: Set<String>,
        candidates: [(spaceId: String, profileId: String, isSwitchTarget: Bool)],
        profileId: String
    ) -> String {
        guard ghostSpaceIds.contains(resolved) else { return resolved }
        let alternative = candidates.first { candidate in
            candidate.isSwitchTarget
                && !ghostSpaceIds.contains(candidate.spaceId)
                && (profileId.isEmpty || candidate.profileId == profileId)
        }
        return alternative?.spaceId ?? resolved
    }

    /// `spaceId(boundTo:preferring:)` for the coordinator's fallback mint —
    /// the one resolution that CREATES a window for the Space it answers,
    /// which must therefore steer off ghost Spaces (see
    /// `steeredFallbackMintSpaceId`). Every other resolution path is free to
    /// answer one: an activation materializes it, and the tab-restore mint
    /// is protected at the source (parked ids never enter the undo stack).
    func fallbackMintSpaceId(boundTo profileId: String,
                             preferring preferred: String) -> String {
        let resolved = spaceId(boundTo: profileId, preferring: preferred)
        let steered = Self.steeredFallbackMintSpaceId(
            resolved: resolved,
            ghostSpaceIds: Set(parkedGhostSpaceIdsByWindowId.values),
            candidates: spaces.map {
                (spaceId: $0.spaceId, profileId: $0.profileId,
                 isSwitchTarget: isAutomaticSwitchTarget($0))
            },
            profileId: profileId
        )
        if steered != resolved {
            AppLogInfo("[SpaceManager] fallback mint steered off ghost Space \(resolved) to \(steered)")
        }
        return steered
    }

    /// How a failed materialization left the parked record — the only thing
    /// the user has to be told apart, because it decides what switching to
    /// the Space again will do.
    enum GhostMaterializeFailure: CaseIterable {
        /// The attempt never got as far as Chromium's store: the Space's
        /// profile did not resolve, or it failed to load. Both are transient,
        /// the record is still parked, and the next switch retries it.
        case recordKept
        /// Chromium held no such ghost, so the record was stale and has been
        /// dropped. Nothing can materialize now; the next switch opens the
        /// Space as a fresh window.
        case recordDropped
    }

    /// The three strings one failure alert shows. They are chosen together,
    /// as one answer, because they are one surface: each outcome is its own
    /// alert with its own localization keys, which is how the two sibling
    /// Space refusals in this file (`deleteSpace`, `changeProfile`) are keyed
    /// as well.
    struct GhostMaterializeFailureAlertCopy {
        let title: String
        let message: String
        let dismissButton: String
    }

    /// D7: a failed materialization is the one lazy-restore state with UI.
    /// The two outcomes get different copy because they promise opposite
    /// things — telling a user to "try switching again" after the record was
    /// dropped describes an action that will silently open an empty Space
    /// instead of their tabs. Pure and static so the choice is pinned by
    /// table, the way the repo's other error copy is.
    enum GhostMaterializeFailureCopy {
        static func alert(
            for outcome: GhostMaterializeFailure
        ) -> GhostMaterializeFailureAlertCopy {
            switch outcome {
            case .recordKept:
                return GhostMaterializeFailureAlertCopy(
                    title: retryableTitle,
                    message: retryableMessage,
                    dismissButton: retryableDismissButton)
            case .recordDropped:
                return GhostMaterializeFailureAlertCopy(
                    title: recordGoneTitle,
                    message: recordGoneMessage,
                    dismissButton: recordGoneDismissButton)
            }
        }

        private static let retryableTitle = NSLocalizedString("spaces.spaceSwitch.reopenWindowFailed.title", value: "Can’t reopen this Space’s window",
            comment: "Spaces - Title of the alert shown when a Space's saved window could not be brought back this time"
        )

        private static let retryableMessage = NSLocalizedString("spaces.spaceSwitch.reopenWindowFailed.message", value: "The window saved for this Space couldn’t be reopened. Try switching to it again.",
            comment: "Spaces - Body of the alert shown when a Space's saved window could not be brought back this time and switching again may still work"
        )

        private static let retryableDismissButton = NSLocalizedString("spaces.spaceSwitch.reopenWindowFailed.dismissButton", value: "OK",
            comment: "Spaces - Dismiss button of the alert shown when a Space's saved window could not be brought back this time"
        )

        private static let recordGoneTitle = NSLocalizedString("spaces.spaceSwitch.savedWindowGone.title", value: "This Space’s saved window is gone",
            comment: "Spaces - Title of the alert shown when a Space's saved window turned out to be no longer available at all"
        )

        private static let recordGoneMessage = NSLocalizedString("spaces.spaceSwitch.savedWindowGone.message", value: "The tabs saved for this Space are no longer available. Switching to it will open a new, empty window.",
            comment: "Spaces - Body of the alert shown when a Space's saved window turned out to be no longer available at all, so switching again opens an empty window instead"
        )

        private static let recordGoneDismissButton = NSLocalizedString("spaces.spaceSwitch.savedWindowGone.dismissButton", value: "OK",
            comment: "Spaces - Dismiss button of the alert shown when a Space's saved window turned out to be no longer available at all"
        )
    }

    /// Presents the failure. Same presentation shape as the other
    /// Space-operation refusals here (`deleteSpace`, `changeProfile`).
    ///
    /// Its one caller, `SpaceWindowSlot.failMaterialize`, reaches it from a
    /// fresh turn of the runloop rather than straight out of a bridge
    /// completion — a profile that was already loaded completes synchronously
    /// inside Chromium's own call stack, where `runModal` would spin a nested
    /// runloop in the middle of it. The hop lives there rather than here
    /// because that caller also has to release the repeat gate AFTER the
    /// modal returns, which it can only do around a synchronous call.
    fileprivate static func presentGhostMaterializeFailureAlert(
        _ outcome: GhostMaterializeFailure
    ) {
        let copy = GhostMaterializeFailureCopy.alert(for: outcome)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.addButton(withTitle: copy.dismissButton)
        alert.runModal()
    }

    /// The profileId a Space is bound to, or nil if unknown. Reads the live
    /// `spaces` cache, falling back to a direct main-context fetch on the
    /// cold-launch path where the async publisher hasn't delivered yet (same
    /// assumption as `spaceId(boundTo:preferring:)`).
    ///
    /// The one resolution both halves of the ghost lifecycle use — the drop
    /// and the materialization. They used to each have their own, and the
    /// materialization's read the cache only: before the store converged it
    /// refused a perfectly good record with "no bound profile" while the drop
    /// path resolved the same Space fine.
    fileprivate func boundProfileId(forSpaceId spaceId: String) -> String? {
        if let cached = spaces.first(where: { $0.spaceId == spaceId })?.profileId {
            return cached
        }
        guard let account = boundAccount else { return nil }
        return MainActor.assumeIsolated {
            account.localStorage.getAllSpaces().first(where: { $0.spaceId == spaceId })?.profileId
        }
    }

    /// Captures the concrete Chromium profile that a fresh Guest default
    /// Space must belong to. The coordinator calls this only for normal
    /// windows; Incognito and Agent profiles must never become its owner.
    func observeNormalWindowProfileForDefaultSpace(_ profileId: String) {
        guard !profileId.isEmpty,
              observedNormalWindowProfileId == nil else { return }
        observedNormalWindowProfileId = profileId
        guard ApplicationState.shared.isGuest,
              spacesCancellable != nil else { return }
        ensureDefaultSpaceForCurrentAccountIfReady()
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
        // callback), the same assumption `applyResolvedTheme` makes.
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

    private func ensureDefaultSpaceForCurrentAccountIfReady() {
        guard let account = boundAccount,
              AccountController.shared.localDataAccount === account,
              let profileId = Self.profileIdForDefaultSpaceCreation(
                  isGuest: ApplicationState.shared.isGuest,
                  isGuestAccountPromotionInProgress: ApplicationState
                      .shared.isGuestAccountPromotionInProgress,
                  isBoundToDefaultAccount:
                      account === AccountController.defaultAccount,
                  observedNormalWindowProfileId:
                      observedNormalWindowProfileId
              ) else { return }
        MainActor.assumeIsolated {
            account.localStorage.ensureDefaultSpace(profileId: profileId)
        }
    }

    /// The Space a tab-restored window ("Reopen Closed Window") should come
    /// back on, or nil when the Space Chromium reported is unusable and the
    /// caller should fall back to its normal placement.
    ///
    /// `restoredSpaceId` is stamped into the restore entry when the window
    /// closes and travels with it, so unlike the session-restore snapshot it
    /// stays valid across a relaunch. It can still go stale: the Space may have
    /// been deleted since, or — for an Incognito Space — reaped along with its
    /// last window. Agent Spaces are excluded for the same reason automatic
    /// switches skip them.
    ///
    /// The result is re-bound to `profileId` so the window is never presented
    /// as a Space belonging to another profile (which would surface that
    /// profile's pinned tabs), matching every other resolution path.
    func restoredSpaceTarget(_ restoredSpaceId: String?, profileId: String) -> String? {
        guard let restoredSpaceId, !restoredSpaceId.isEmpty else { return nil }
        // Same cold-launch caveat as `spaceId(boundTo:preferring:)`: the first
        // windows of a launch arrive before the `spaces` publisher delivers.
        var known = spaces
        if known.isEmpty, let account = boundAccount {
            known = MainActor.assumeIsolated {
                account.localStorage.getAllSpaces()
            }
        }
        guard let model = known.first(where: { $0.spaceId == restoredSpaceId }),
              isAutomaticSwitchTarget(model) else { return nil }
        // Validate what we are about to RETURN, not just what was asked for:
        // `spaceId(boundTo:)` re-resolves to another Space of `profileId` when
        // the stamped one no longer belongs to it (the user changed the Space's
        // profile after the window closed), and that replacement is picked in
        // strip order — it could land on an Agent Space, which no automatic
        // placement may use. Decline instead, and let the caller fall back.
        let resolved = spaceId(boundTo: profileId, preferring: model.spaceId)
        guard let resolvedModel = known.first(where: { $0.spaceId == resolved }),
              isAutomaticSwitchTarget(resolvedModel) else { return nil }
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
        // Land a debounced frame write before the freeze, or quitting within a
        // second of the last drag persists the position the window had BEFORE
        // that drag — the freeze below makes every later write a no-op.
        // A quit landing inside a reopen's replay refuses this flush like any
        // other write (`mayPersistSlotsSnapshot`), losing that one pending
        // frame change rather than stamping a half-restored group as the
        // layout to come back to. That trade is deliberate.
        flushPendingSlotsSnapshotPersist()
        isTerminating = true
    }

    /// Whether the live slot layout may be written over the saved snapshot at
    /// all right now. Each answer of `false` names a state in which the layout
    /// this side can see is a transient, not the group the next launch should
    /// reattach into — so the last complete one has to stand.
    ///
    /// * `isTerminating` — quit dismantles the slots window by window; see the
    ///   property for what a write during that costs.
    /// * `isSessionRestoreInFlight` — a windowless reopen replays its windows
    ///   one at a time, so every write before the replay settles describes a
    ///   half-restored group. The reopen writes once itself, from the
    ///   completion that reports every profile settled. Covers that reopen
    ///   ONLY: a cold launch replays the same way but has no settle signal on
    ///   this side, so it still writes once per restored window. Gating that
    ///   on a wall clock instead would fire the batch write whether or not the
    ///   restore aborted — buying the write count by giving up the guarantee
    ///   that matters more.
    /// * `isAnySlotTearingDown` — a slot mid-cascade has a half-drained window
    ///   map, so a write from ANY trigger (AppKit's fullscreen teardown
    ///   notifications, tab-bar churn, a sibling's key change) persists a
    ///   partial group — dropping already-closed windows and the fullscreen
    ///   marker from the very snapshot the next reopen restores, which splits
    ///   the group into separate slots. The teardown's own endpoints persist
    ///   the settled state after clearing the cascade flag: `removeSlot`
    ///   shrinks the snapshot once the cascade drains, and
    ///   `recoverFromVetoedCascade` rewrites it after a veto.
    ///
    /// Pure and static so the three can be pinned down by table: they are what
    /// stands between a transient layout and the snapshot a reopen trusts, and
    /// inline they were untestable. The fourth refusal — never replacing a
    /// saved snapshot with an empty one — deliberately stays at the call site:
    /// it can only be answered from the built array, and answering here is
    /// precisely what avoids building it. `amendPersistedSnapshotActiveSpaceId`
    /// does not come through here either; it patches one field of an existing
    /// entry rather than rewriting the record, and says why.
    static func mayPersistSlotsSnapshot(
        isTerminating: Bool,
        isSessionRestoreInFlight: Bool,
        isAnySlotTearingDown: Bool
    ) -> Bool {
        !isTerminating && !isSessionRestoreInFlight && !isAnySlotTearingDown
    }

    /// Whether a write actually reaches the record: the three gates above,
    /// plus the fourth refusal — a record with nothing live in it — which only
    /// the built record can answer and therefore arrives as a parameter.
    ///
    /// `persistSlotsSnapshot` returns this, and `removeSlot` pairs its
    /// chromium-side ghost drop to it: a parked window leaves the store and
    /// the session file exactly when it left the snapshot, so the two halves
    /// of "snapshot entry ⇔ chromium record" cannot drift. The drop guard used
    /// to be its own hand-written copy of this list and held one and a half of
    /// the four — a slot closing while a sibling drained its windows emptied
    /// the store while the write meant to shrink the record was refused, and a
    /// beforeunload prompt nobody answers keeps a cascade running for as long
    /// as the user ignores it.
    ///
    /// The gate above is consulted twice on purpose, but not asked twice: the
    /// three values are computed ONCE and handed to both, so the cheap
    /// pre-build bail (which saves the whole rebuild) and this — the answer
    /// the drop side pairs to — cannot disagree about the same write.
    ///
    /// What is deliberately NOT in here: the write also returns false with no
    /// account bound to write to. Naming that alongside these would suggest it
    /// is a decision about the layout, which it is not; it is the absence of a
    /// destination. It refuses in the safe direction all the same — no
    /// account, no write, no drop — and it is the ONE refusal not on this
    /// table, so a reader looking for the complete list has to read the
    /// function.
    static func slotsSnapshotWriteLands(
        isTerminating: Bool,
        isSessionRestoreInFlight: Bool,
        isAnySlotTearingDown: Bool,
        hasLiveSlotEntry: Bool
    ) -> Bool {
        mayPersistSlotsSnapshot(
            isTerminating: isTerminating,
            isSessionRestoreInFlight: isSessionRestoreInFlight,
            isAnySlotTearingDown: isAnySlotTearingDown
        ) && hasLiveSlotEntry
    }

    /// What the watchdog below does when its deadline finds the reopen's
    /// restore transaction still open.
    struct SessionRestoreWatchdogOutcome: Equatable {
        /// Stop refusing snapshot writes.
        let releasesFreeze: Bool
        /// Whether the watchdog itself writes the snapshot. Always false, and
        /// separated out so it is pinned by a test rather than by a comment.
        let writesSnapshot: Bool
    }

    /// The watchdog releases the freeze and **writes nothing**.
    ///
    /// Writing here is the tempting mistake: the transaction is over, so why
    /// not persist? Because at this point the layout is whatever a hung
    /// restore left behind — writing it stamps exactly the half-restored group
    /// the freeze exists to keep out, reintroducing the defect this whole
    /// mechanism fixed, just later and rarer. Releasing is enough: the next
    /// ordinary layout change writes what the user actually has by then, and
    /// until it comes the last complete snapshot stands, which is correct.
    static func sessionRestoreWatchdogOutcome(
        isSessionRestoreInFlight: Bool
    ) -> SessionRestoreWatchdogOutcome {
        SessionRestoreWatchdogOutcome(
            releasesFreeze: isSessionRestoreInFlight, writesSnapshot: false)
    }

    /// Bounds how long `isSessionRestoreInFlight` may hold snapshot writes.
    ///
    /// The flag is cleared from one place: the completion that reports every
    /// profile settled. That completion is argued to be unmissable — every
    /// per-profile terminal, including failure, signals the Chromium barrier.
    /// A profile that **hangs** rather than terminating signals nothing, and
    /// then the flag is set for the life of the process: the app looks
    /// entirely normal while silently never recording its layout again, so
    /// every window the user moves afterwards is lost at the next launch.
    ///
    /// This is deliberately not a second completion path competing with the
    /// barrier — it never writes and never spawns anything. It is a timeout on
    /// a flag that gates all persistence, which is the kind of single point
    /// worth a bound even when the argument for its terminality is good.
    ///
    /// 30s against a measured restore of roughly two seconds: long enough that
    /// a merely slow machine never reaches it, short enough that the user has
    /// not yet done much rearranging to lose.
    private static let sessionRestoreWatchdogDeadline: TimeInterval = 30

    /// Cancelled by `endSessionRestoreTransaction`, so the ordinary path never
    /// reaches the deadline.
    private var sessionRestoreWatchdog: DispatchWorkItem?

    /// The windowMap `persistSlotsSnapshot` writes for one snapshot entry: the
    /// live controller map, plus every parked ghost of that entry still
    /// waiting — not yet claimed by a materialized window, its Space still in
    /// the store. A ghost's Space stays on the strip while its window exists
    /// only in the session file, and this entry is the one record mapping the
    /// two to each other; writing the live map alone (what the writer always
    /// did) would strand the window one persist cycle after the reopen that
    /// parked it.
    ///
    /// Called for both entry kinds `plannedSnapshotEntries` produces: a live
    /// slot passes its controller map, and an entry nothing live speaks for
    /// passes an EMPTY live map, which reduces this to "the ghosts of that
    /// entry that are still parked" — the same retirement rules, no second
    /// copy of them.
    ///
    /// Each ghost entry also leaves on its own the moment it stops describing
    /// a parked window, with nobody erasing it: materializing consumes the
    /// unclaimed id, deleting the Space removes it from the store, and either
    /// way the entry fails this filter at the next write. A live window wins
    /// an id collision outright — current-run ids and parked previous-session
    /// ids never legitimately collide (the id generator is monotonic across
    /// runs), so the parked value is the stale one.
    ///
    /// With nothing parked the answer is the live map unchanged, which is
    /// what keeps today's snapshot byte-identical while nothing arms the
    /// lazy reopen. Pure and static so the rule is pinned by table
    /// (`SlotSnapshotGhostPreservationTests`).
    static func persistedWindowMap(
        liveWindowMap: [Int: String],
        parkedGhosts: [Int: String],
        unclaimedWindowIds: Set<Int>,
        liveSpaceIds: Set<String>
    ) -> [Int: String] {
        let stillParked = parkedGhosts.filter { ghost in
            unclaimedWindowIds.contains(ghost.key) && liveSpaceIds.contains(ghost.value)
        }
        return liveWindowMap.merging(stillParked) { live, _ in live }
    }

    /// Which saved entry a parked ghost rides with: the recorded park set, cut
    /// down to the windows of that entry's own map. This is the whole of "a
    /// ghost never migrates" — an entry folds in the ghosts it was classified
    /// from and no others, so a Space cannot surface in a window group the
    /// user never put it in.
    ///
    /// Keyed by the SAVED entry rather than by the live slot that reattached
    /// to it, because the slot dies first and the record has to outlive it:
    /// closing the window group drops the binding while the freeze deliberately
    /// keeps the entries, and an eager window whose id went stale never
    /// establishes one at all. Ownership by slot made both of those erase
    /// ghosts Chromium still held. `restoreEntries` is also what Chromium's own
    /// ghost store is keyed by (previous-session window ids), so the two sides
    /// now retire on the same terms instead of on two hand-kept lists.
    static func entryParkedGhosts(
        recorded: [Int: String],
        entryWindowMap: [Int: String]
    ) -> [Int: String] {
        recorded.filter { entryWindowMap[$0.key] != nil }
    }

    /// One entry of the record `persistSlotsSnapshot` writes, at the layer
    /// that decides which windows belong to which entry.
    struct PlannedSnapshotEntry: Equatable {
        /// Where the entry's remaining fields come from.
        enum Source: Equatable {
            /// Position in the live slot array the planner was given — the
            /// slot supplies the landing Space, fullscreen marker, frame,
            /// sidebar width and traffic-light origin.
            case liveSlot(Int)
            /// Index into the saved entries: a window group with parked
            /// windows and no live slot speaking for it. The saved entry
            /// supplies the same fields, minus the landing Space — nothing is
            /// on screen to land on.
            case parkedOnly(Int)
        }
        let source: Source
        let windowMap: [Int: String]
    }

    /// The window maps one snapshot write records, in write order — or an
    /// empty plan when the write must be refused.
    ///
    /// Live slots come first, in registry order, each folding in the parked
    /// ghosts of its OWN saved entry (`entryParkedGhosts`, then
    /// `persistedWindowMap` to retire the ones that stopped describing a
    /// parked window). Saved entries no live slot speaks for follow, in saved
    /// order, carrying whatever they still have parked: that is what keeps a
    /// closed group's parked Spaces in the record until something actually
    /// retires them, instead of the next unrelated write erasing them while
    /// Chromium still holds their windows.
    ///
    /// A plan with no live entry is empty, refusing the write outright. That is
    /// the existing "never overwrite a saved snapshot with an empty one"
    /// backstop, and it is why parked-only entries may never stand a write up
    /// on their own: closing the last window group has to FREEZE the record
    /// written while that group was whole, not replace it with one naming only
    /// the leftovers — the group would come back missing every window that was
    /// on screen.
    ///
    /// Pure and static so the whole layer is pinned by table
    /// (`SlotSnapshotEntryPlanTests`); the merge rule underneath it keeps its
    /// own (`SlotSnapshotGhostPreservationTests`).
    static func plannedSnapshotEntries(
        liveSlots: [(restoreIndex: Int?, windowMap: [Int: String])],
        restoreEntryWindowMaps: [[Int: String]],
        parkedGhosts: [Int: String],
        unclaimedWindowIds: Set<Int>,
        liveSpaceIds: Set<String>
    ) -> [PlannedSnapshotEntry] {
        var planned: [PlannedSnapshotEntry] = []
        var spokenForEntries: Set<Int> = []
        for (position, slot) in liveSlots.enumerated() {
            // A slot with nothing writable (every window on an Incognito
            // Space) is not an entry — and it does not speak for its saved
            // entry either, so what that entry has parked falls through to the
            // pass below rather than leaving the record with it.
            guard !slot.windowMap.isEmpty else { continue }
            var windowMap = slot.windowMap
            if let index = slot.restoreIndex,
               restoreEntryWindowMaps.indices.contains(index) {
                spokenForEntries.insert(index)
                let ghosts = entryParkedGhosts(
                    recorded: parkedGhosts,
                    entryWindowMap: restoreEntryWindowMaps[index])
                // Guarded on the fast path: nothing is parked on an unarmed run
                // (switch off, older framework, cold start), and skipping the
                // merge keeps that write byte-identical to the pre-lazy one by
                // construction.
                if !ghosts.isEmpty {
                    windowMap = persistedWindowMap(
                        liveWindowMap: slot.windowMap,
                        parkedGhosts: ghosts,
                        unclaimedWindowIds: unclaimedWindowIds,
                        liveSpaceIds: liveSpaceIds)
                }
            }
            planned.append(PlannedSnapshotEntry(
                source: .liveSlot(position), windowMap: windowMap))
        }
        guard !planned.isEmpty else { return [] }
        for index in restoreEntryWindowMaps.indices
        where !spokenForEntries.contains(index) {
            let ghosts = entryParkedGhosts(
                recorded: parkedGhosts,
                entryWindowMap: restoreEntryWindowMaps[index])
            guard !ghosts.isEmpty else { continue }
            let windowMap = persistedWindowMap(
                liveWindowMap: [:],
                parkedGhosts: ghosts,
                unclaimedWindowIds: unclaimedWindowIds,
                liveSpaceIds: liveSpaceIds)
            // An entry whose every ghost has been claimed or had its Space
            // deleted describes nothing; writing it would keep resurrecting an
            // empty group.
            guard !windowMap.isEmpty else { continue }
            planned.append(PlannedSnapshotEntry(
                source: .parkedOnly(index), windowMap: windowMap))
        }
        return planned
    }

    /// Writes the geometry half of one snapshot entry: the fullscreen marker
    /// and the three fields the reopen loading window is drawn from. One
    /// encoder for both entry kinds — a live slot measures these off its
    /// window, an entry nothing live speaks for passes through what it was
    /// saved with — because the reader cannot tell the two apart and would
    /// break on the first key one of them stopped writing.
    ///
    /// Each is written only when known, so a slot that has never had a window
    /// adds nothing and a normal entry stays small.
    ///
    /// * `frame` — where the slot sits on screen, so a reopen has a position
    ///   on hand before Chromium reports the restored window's bounds. Stored
    ///   as the AppKit rect string (plist-native, and `NSRectFromString` is
    ///   the matching reader).
    /// * `trafficLightOrigin` and `sidebarWidth` — read off the live window
    ///   rather than derived on the other side: the traffic-light origin
    ///   belongs to the Chromium fork's own frame view, so measuring it at
    ///   persist time is what keeps this side from having to track that file,
    ///   and the sidebar width has to be PER SLOT. The app already keeps one
    ///   of those (`AccountUserDefaults.lastKnownSidebarWidth`, written by
    ///   `MainSplitViewController.updateSidebarWidth`), and it is not a
    ///   substitute for two reasons: it is one number for the whole account
    ///   rather than one per slot, and it deliberately refuses to record `0`,
    ///   which is exactly the value that means "collapsed" and therefore
    ///   "draw no band". It stays where it is, for the floating sidebar panel
    ///   that reads it.
    ///
    /// Finiteness is checked HERE as well as on read: this dictionary goes
    /// into one plist with everything else the account stores, and
    /// `PropertyListSerialization` refuses a non-finite double for the whole
    /// file — which `AccountUserDefaults.persistLocked` logs and swallows,
    /// leaving the bad value in memory to fail every later write of every
    /// other key too.
    private static func encodeSnapshotGeometry(
        isFullScreen: Bool,
        frame: NSRect?,
        sidebarWidth: CGFloat?,
        trafficLightOrigin: NSPoint?,
        into dict: inout [String: Any]
    ) {
        if isFullScreen {
            dict["isFullScreen"] = true
        }
        if let frame {
            dict["frame"] = NSStringFromRect(frame)
        }
        if let sidebarWidth, sidebarWidth.isFinite {
            dict["sidebarWidth"] = Double(sidebarWidth)
        }
        if let trafficLightOrigin {
            dict["trafficLightOrigin"] = NSStringFromPoint(trafficLightOrigin)
        }
    }

    /// Index of the saved snapshot entry `slot` reattached to, or nil for a
    /// slot that claimed none (Cmd+N, a spawn, a materialization).
    private func restoreIndex(of slot: SpaceWindowSlot) -> Int? {
        restoredSlotsByIndex.first(where: { $0.value === slot })?.key
    }

    /// The parked ghosts recorded against the saved entry `slot` reattached
    /// to. Read by `removeSlot`, which retires them from both sides when the
    /// write that takes them out of the record lands. Empty whenever nothing
    /// is recorded, which is every run whose reopen did not arm the lazy
    /// filter (switch off, older framework, nothing to park) — and every cold
    /// start, which never arms.
    private func parkedGhostEntries(for slot: SpaceWindowSlot) -> [Int: String] {
        guard !parkedGhostSpaceIdsByWindowId.isEmpty else { return [:] }
        guard let index = restoreIndex(of: slot),
              restoreEntries.indices.contains(index) else { return [:] }
        return Self.entryParkedGhosts(
            recorded: parkedGhostSpaceIdsByWindowId,
            entryWindowMap: restoreEntries[index].windowMap)
    }

    /// Writes the current slot/window/Space layout to
    /// `AccountUserDefaults.slotsRestoreSnapshot`. Called from
    /// `SpaceWindowSlot.registerWindow` (and a few live-state mutations) so the
    /// persisted snapshot reflects the most recent healthy layout — sufficient
    /// to reattach Chromium-restored windows next launch. Refused while the
    /// layout is a transient (`mayPersistSlotsSnapshot`) and never overwrites a
    /// non-empty snapshot with an empty one, so neither quit teardown nor a
    /// half-finished reopen can drain it before the next launch reads it.
    ///
    /// Returns whether the write actually reached the record
    /// (`slotsSnapshotWriteLands`). `removeSlot` is the one caller that needs
    /// the answer: it retires the removed slot's parked ghosts from the
    /// chromium store only when the write that took them out of the record
    /// landed.
    ///
    /// - Parameter retiringGhostWindowIds: parked windows the caller is about
    ///   to retire, conditional on this write landing. Left out of the record
    ///   here so the two halves move together — out of both sides, or neither.
    @discardableResult
    fileprivate func persistSlotsSnapshot(
        retiringGhostWindowIds: Set<Int> = []
    ) -> Bool {
        // Asked before anything is built: a refusal here saves the whole array
        // rebuild over every slot's window map, and the states it refuses in
        // are exactly the ones whose triggers fire once per window.
        let isAnySlotTearingDown = slots.contains(where: { $0.isTearingDown })
        guard Self.mayPersistSlotsSnapshot(
            isTerminating: isTerminating,
            isSessionRestoreInFlight: isSessionRestoreInFlight,
            isAnySlotTearingDown: isAnySlotTearingDown
        ) else { return false }
        guard let userDefaults = boundAccount?.userDefaults else { return false }
        // Incognito Spaces are excluded from the snapshot wholesale: their
        // sessions intentionally die with their windows, so restoring one
        // would surface an empty Space (and its runtime-only spaceId would
        // point restore at a Space that no longer exists by then).
        let liveSlots: [(restoreIndex: Int?, windowMap: [Int: String])] =
            slots.map { slot in
                (restoreIndex: restoreIndex(of: slot),
                 windowMap: slot.snapshotWindowMap()
                     .filter { !SpaceManager.isIncognitoSpaceId($0.value) })
            }
        // Which windows each entry records, and which entries there are at
        // all. Still-parked ghosts ride along with the entry they were saved
        // with, so the record mapping each parked window back to its Space
        // survives this write even when nothing live speaks for that entry
        // any more.
        let planned = Self.plannedSnapshotEntries(
            liveSlots: liveSlots,
            restoreEntryWindowMaps: restoreEntries.map(\.windowMap),
            parkedGhosts: parkedGhostSpaceIdsByWindowId.filter {
                !retiringGhostWindowIds.contains($0.key)
            },
            unclaimedWindowIds: Set(restoreIndexByWindowId.keys),
            liveSpaceIds: Set(spaces.map(\.spaceId))
        )
        // Backstop: never overwrite a saved snapshot with an empty one. A
        // transient "no live slots" moment (teardown, or all windows closed
        // while the app stays alive) must not erase the layout the next launch
        // restores into — which is also why parked-only entries cannot stand
        // this write up on their own (`plannedSnapshotEntries`).
        guard Self.slotsSnapshotWriteLands(
            isTerminating: isTerminating,
            isSessionRestoreInFlight: isSessionRestoreInFlight,
            isAnySlotTearingDown: isAnySlotTearingDown,
            hasLiveSlotEntry: !planned.isEmpty
        ) else { return false }
        var dicts: [[String: Any]] = []
        var parkedOnlyCount = 0
        for entry in planned {
            var dict: [String: Any] = [:]
            // Plist keys must be strings; convert the windowId map.
            dict["windowMap"] = Self.encodedWindowMap(entry.windowMap)
            switch entry.source {
            case .liveSlot(let position):
                // Positions index `liveSlots`, which is `slots` mapped one for
                // one — the plan names live entries by where they sit in the
                // registry.
                let slot = slots[position]
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
                Self.encodeSnapshotGeometry(
                    isFullScreen: slot.snapshotIsFullScreen(),
                    frame: slot.snapshotFrame(),
                    sidebarWidth: slot.snapshotSidebarWidth(),
                    trafficLightOrigin: slot.snapshotTrafficLightOrigin(),
                    into: &dict)
            case .parkedOnly(let index):
                // A saved entry nothing live speaks for carries everything but
                // the landing Space, passed through from the entry these
                // windows were saved with, so the group comes back where and
                // how it was. No landing Space on purpose — nothing is on
                // screen to land on, and the classifier's existing "no landing
                // window ⇒ promote the first surviving Space in snapshot order"
                // rule is what picks one at the next reopen.
                //
                // The frame is the one the snapshot LOAD clamped to the screens
                // attached then (`loadRestoreSnapshot`), not the raw saved rect.
                // That is the same value a live slot would persist — a restored
                // window comes back on the clamped rect and records it — so the
                // two entry kinds agree; the cost is that a group parked while
                // its display was unplugged forgets the geometry it had on it.
                let saved = restoreEntries[index]
                parkedOnlyCount += 1
                Self.encodeSnapshotGeometry(
                    isFullScreen: saved.wasFullScreen,
                    frame: saved.frame,
                    sidebarWidth: saved.sidebarWidth,
                    trafficLightOrigin: saved.trafficLightOrigin,
                    into: &dict)
            }
            dicts.append(dict)
        }
        // This write supersedes any debounced one. Dropped only here, past
        // every guard above: a refused write must leave the timer armed so the
        // frame change that armed it still reaches disk once the slot settles.
        pendingSlotsSnapshotPersistWorkItem?.cancel()
        pendingSlotsSnapshotPersistWorkItem = nil
        // The one place the cross-launch record is rewritten, and a synchronous
        // whole-file write. Logged so how often it happens — a reopen must
        // reach it once, not once per restored window — is answerable from a
        // log bundle rather than only from a plist diff. Entries nothing live
        // speaks for are counted apart: they are the record's memory of a
        // window group with no window on screen, and a log bundle has to be
        // able to tell one from a live slot. Nothing is parked on an unarmed
        // run, so that run's line reads exactly as it always did.
        AppLogInfo(
            "[SpaceManager] slot snapshot persisted: \(dicts.count - parkedOnlyCount) slot(s)"
                + (parkedOnlyCount > 0 ? ", \(parkedOnlyCount) parked-only entry(ies)" : ""))
        userDefaults.set(dicts, forKey: AccountUserDefaults.DefaultsKey.slotsRestoreSnapshot.rawValue)
        return true
    }

    /// Trailing-edge debounce for `persistSlotsSnapshot`, used by the ONE
    /// trigger that fires continuously: the visible window moving or resizing
    /// (`SpaceWindowSlot.observeFrameChanges`). Every other trigger is a
    /// discrete layout event and still writes synchronously.
    ///
    /// A drag emits `didMove` at screen refresh rate, and each write rewrites
    /// the whole slot array, so the write has to wait for the gesture to stop:
    /// one write per drag instead of one per pixel. Long enough that no
    /// realistic drag or resize splits into two writes; short enough that the
    /// user cannot both finish a drag and be gone before it lands — and the two
    /// ways out (closing the window, quitting) flush it explicitly anyway.
    private static let slotsSnapshotPersistDebounce: TimeInterval = 1.0

    /// Non-nil while a frame change is still unwritten — not merely while a
    /// timer is armed. `persistSlotsSnapshot` drops it only for a write that
    /// actually lands, so a timer that fires into a refusal (any reason
    /// `mayPersistSlotsSnapshot` gives) leaves it set and the next flush picks
    /// the change up instead of losing it.
    private var pendingSlotsSnapshotPersistWorkItem: DispatchWorkItem?

    /// Requests a snapshot write once the current burst of frame changes stops.
    /// Re-arming cancels the previous timer, so a continuous drag writes once,
    /// `slotsSnapshotPersistDebounce` after the user lets go.
    fileprivate func scheduleSlotsSnapshotPersist() {
        pendingSlotsSnapshotPersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Deliberately does not clear the handle first: see its doc above.
            self?.persistSlotsSnapshot()
        }
        pendingSlotsSnapshotPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.slotsSnapshotPersistDebounce, execute: workItem)
    }

    /// Writes a debounced snapshot immediately, if one is pending. Called from
    /// the two points past which the debounce can no longer fire usefully: a
    /// window leaving its slot (`SpaceWindowSlot.unregisterWindow`, while the
    /// map is still whole) and the start of quit (`markTerminating`). A no-op
    /// when nothing is pending, so neither point changes the write frequency of
    /// a session where the user never moved a window.
    ///
    /// Deliberately does not drop the pending item itself — `persistSlotsSnapshot`
    /// does that only for a write that actually lands. A flush arriving while
    /// the write is refused (see `mayPersistSlotsSnapshot`) therefore leaves
    /// the change on record for the next write of any kind to pick up, instead
    /// of swallowing it. The fired timer itself is spent either way; what
    /// survives a refusal is the handle saying something is still unwritten.
    fileprivate func flushPendingSlotsSnapshotPersist() {
        guard pendingSlotsSnapshotPersistWorkItem != nil else { return }
        persistSlotsSnapshot()
    }

    /// Rewrites the persisted snapshot entry containing `windowId` to carry
    /// `spaceId` as its active Space, touching nothing else. Used by the
    /// window-driven cascade to undo a close-driven key promotion that
    /// persisted a sibling as the entry's active Space (a fullscreen tab
    /// group promotes synchronously with the closing window's teardown,
    /// before any close signal reaches this side, so no key guard can
    /// suppress it). A full `persistSlotsSnapshot()` cannot repair this: the
    /// closing window has already left the slot's window map, so a full
    /// rewrite would drop its entry from the very snapshot a reopen
    /// restores from.
    fileprivate func amendPersistedSnapshotActiveSpaceId(windowId: Int, to spaceId: String) {
        guard !isTerminating, let userDefaults = boundAccount?.userDefaults else { return }
        let key = AccountUserDefaults.DefaultsKey.slotsRestoreSnapshot.rawValue
        guard var dicts = userDefaults.object(forKey: key) as? [[String: Any]] else { return }
        for index in dicts.indices {
            guard let map = dicts[index]["windowMap"] as? [String: String],
                  map[String(windowId)] != nil else { continue }
            dicts[index]["activeSpaceId"] = spaceId
            userDefaults.set(dicts, forKey: key)
            return
        }
    }

    private func loadRestoreSnapshot(armReattachDeadline: Bool = true) {
        restoreEntries.removeAll()
        restoreIndexByWindowId.removeAll()
        restoredSlotsByIndex.removeAll()
        parkedGhostSpaceIdsByWindowId.removeAll()
        restoreReattachDeadline = nil
        guard let raw = boundAccount?.userDefaults.object(
            forKey: AccountUserDefaults.DefaultsKey.slotsRestoreSnapshot.rawValue
        ) as? [[String: Any]] else { return }
        // Clamp against the layout in front of the user NOW, not the one the
        // frames were recorded against — the display a slot was saved on may be
        // gone. Read once for the whole snapshot.
        let screens = Self.currentScreenGeometries()
        for dict in raw {
            let windowMap = Self.decodedWindowMap(dict["windowMap"])
            guard !windowMap.isEmpty else { continue }
            let entry = SlotRestoreEntry(
                activeSpaceId: dict["activeSpaceId"] as? String,
                windowMap: windowMap,
                wasFullScreen: (dict["isFullScreen"] as? Bool) ?? false,
                frame: Self.decodedSlotFrame(dict["frame"]).map {
                    Self.clampedSlotFrame($0, toScreens: screens)
                },
                sidebarWidth: Self.decodedSidebarWidth(dict["sidebarWidth"]),
                trafficLightOrigin:
                    Self.decodedTrafficLightOrigin(dict["trafficLightOrigin"])
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
        // absorbed (see `claimRestoredWindow`). A mid-session re-arm passes
        // `armReattachDeadline: false`: those restored windows carry their real
        // ids, and arming the fallback would let a concurrent Cmd+N misclaim a
        // stale slot. The one exception needs no deadline — restore's own
        // stand-in window announces itself with `restoreFallbackWindowId` and
        // claims by profile regardless.
        if armReattachDeadline && !restoreEntries.isEmpty {
            restoreReattachDeadline = Date().addingTimeInterval(Self.restoreReattachGracePeriod)
        }
    }

    /// One attached display, reduced to the two rects a frame clamp needs.
    /// Exists so the clamp itself can be a pure function over plain values —
    /// `NSScreen` cannot be constructed in a test, and the clamp is the piece
    /// worth pinning down by table.
    struct ScreenGeometry {
        /// Full display bounds, in AppKit's bottom-left-origin global space.
        let frame: NSRect
        /// The part of `frame` a window may occupy — menu bar and Dock removed.
        let visibleFrame: NSRect
    }

    /// The displays attached right now, in `NSScreen.screens` order, so index 0
    /// is the one the clamp falls back to when a frame belongs to none of them.
    fileprivate static func currentScreenGeometries() -> [ScreenGeometry] {
        NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// The plist form of a snapshot entry's windowMap — plist keys must be
    /// strings. `decodedWindowMap` is the matching reader; the pair is what
    /// a ghost entry's survival across launches rides on, so the round trip
    /// is pinned by test rather than by two inline expressions agreeing.
    static func encodedWindowMap(_ windowMap: [Int: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: windowMap.map { (String($0.key), $0.value) })
    }

    /// The windowMap stored in a snapshot entry. Tolerant the way the other
    /// decoders here are: a missing or differently-typed value decodes to
    /// empty, and a key that no longer parses as a window id drops that pair
    /// while the readable rest survives.
    static func decodedWindowMap(_ raw: Any?) -> [Int: String] {
        guard let rawMap = raw as? [String: String] else { return [:] }
        return rawMap.reduce(into: [:]) { partial, pair in
            if let id = Int(pair.key) { partial[id] = pair.value }
        }
    }

    /// The slot frame stored in a snapshot entry, or nil when the entry has
    /// none. Nil covers both graceful-degradation cases together: an entry
    /// written before the field existed (no value) and one whose value no
    /// longer parses — `NSRectFromString` answers an unreadable string with a
    /// zero rect, which is not a frame any window ever had.
    static func decodedSlotFrame(_ raw: Any?) -> NSRect? {
        guard let string = raw as? String else { return nil }
        let rect = NSRectFromString(string)
        return rect.isEmpty ? nil : rect
    }

    /// The sidebar width stored in a snapshot entry, or nil when the entry has
    /// none.
    ///
    /// Unlike the frame, zero is a value and not an absence: it is how a
    /// collapsed sidebar is recorded. Only the states no window ever had are
    /// refused — a negative width, and the non-finite values a corrupt plist
    /// can hand back.
    ///
    /// Through `NSNumber` because that is what a plist hands back whatever the
    /// value was written as. `as? Double` would in fact also work on that —
    /// measured — but not on an integer boxed straight into an `Any`, which is
    /// what the tests hand it, and the difference is not worth a reader having
    /// to know.
    static func decodedSidebarWidth(_ raw: Any?) -> CGFloat? {
        guard let width = (raw as? NSNumber)?.doubleValue,
              width.isFinite, width >= 0 else { return nil }
        return CGFloat(width)
    }

    /// The traffic-light origin stored in a snapshot entry, or nil when the
    /// entry has none.
    ///
    /// Filtered harder than "did it parse", because `NSPointFromString` does
    /// not fail: it answers a partly-read string with a partly-filled point
    /// (`"{13, junk}"` becomes `{13, 0}`) and an out-of-range one with an
    /// infinity, and both would be used verbatim to move the lights — measured,
    /// `{inf, 0}` puts the close button at x = 1.7e13, and `{13, 0}` puts the
    /// three of them 13.5pt above where the restored window's are, which is the
    /// hand-off jump this all exists to remove. So: finite, non-negative, and
    /// inside the corner of a titlebar. The zero point is refused by the same
    /// bound, and it is also what a wholly unreadable string decodes to.
    static func decodedTrafficLightOrigin(_ raw: Any?) -> NSPoint? {
        guard let string = raw as? String else { return nil }
        let point = NSPointFromString(string)
        guard point.x.isFinite, point.y.isFinite,
              point.x > 0, point.y > 0,
              point.x <= Self.maxPlausibleTrafficLightInset,
              point.y <= Self.maxPlausibleTrafficLightInset else { return nil }
        return point
    }

    /// How far from a window's top-left corner its leading traffic light can
    /// credibly be. Generous — the measured value is 13 — because this is a
    /// nonsense filter, not a specification: it only has to reject the values
    /// `NSPointFromString` invents, and a real titlebar is nowhere near this
    /// tall.
    private static let maxPlausibleTrafficLightInset: CGFloat = 200

    /// `frame` corrected for the screens listed in `screens`, or `frame`
    /// unchanged when it is still usable as-is.
    ///
    /// Deliberately far weaker than AppKit's own constraint, which pulls a
    /// frame fully inside `visibleFrame`: a window the user dragged halfway off
    /// an edge is exactly where they put it and must stay there. Only the
    /// states the user cannot get out of are corrected — a frame too large for
    /// its display, or one with nothing left on any work area to grab, which is
    /// what a saved frame becomes when its display is unplugged or shrinks.
    ///
    /// Total by construction: every input yields a frame, so a caller placing a
    /// window never has to handle "the clamp declined".
    static func clampedSlotFrame(_ frame: NSRect, toScreens screens: [ScreenGeometry]) -> NSRect {
        guard !screens.isEmpty else { return frame }
        // A frame that exactly covers a display is a fullscreen frame; macOS
        // resizes those itself across a layout change. Checked on the frame
        // rather than a styleMask because this runs where no window exists yet.
        guard !screens.contains(where: { $0.frame.equalTo(frame) }) else { return frame }
        // The display this frame belongs to: whichever it covers most. Ties —
        // including the all-zero tie a frame off every display produces — keep
        // the first, so a homeless frame deterministically lands on the primary.
        let host = screens.max {
            let lhs = NSIntersectionRect(frame, $0.frame)
            let rhs = NSIntersectionRect(frame, $1.frame)
            return lhs.width * lhs.height < rhs.width * rhs.height
        } ?? screens[0]
        let workArea = host.visibleFrame
        var clamped = frame
        clamped.size.width = min(clamped.width, workArea.width)
        clamped.size.height = min(clamped.height, workArea.height)
        if clamped.maxY > workArea.maxY {
            clamped.origin.y = workArea.maxY - clamped.height
        }
        if !NSIntersectsRect(clamped, workArea) {
            clamped.origin.x = workArea.minX
            clamped.origin.y = workArea.maxY - clamped.height
        }
        return clamped
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
    /// decides the sidebar's overlay background color, so it opens looking like
    /// the Space it was created from rather than snapping to the global default
    /// theme. A nil pin means "follow the global theme" —
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
        // `LocalStore.createSpace`'s GLOBAL max+1 sortOrder (the strip is one
        // combined list, so appending past the global max is what lands the
        // new pill last) and reuse `getAllSpaces`'s (sortOrder, profileId,
        // createdDate) ordering so the pill's position is identical before
        // and after that reconciliation — no visible reposition.
        let nextOrder = (spaces.map(\.sortOrder).max() ?? -1) + 1
        spaces.append(SpaceModel(spaceId: newSpaceId,
                                 profileId: profileId,
                                 name: name,
                                 colorHex: colorHex,
                                 iconName: iconName,
                                 sortOrder: nextOrder))
        spaces.sort { lhs, rhs in
            // Mirror `handleSpacesUpdate`'s agent-Space grouping first, so a
            // user Space created while an agent Space lives appears before the
            // agent group immediately — the same slot the reconciled emission
            // puts it in.
            if lhs.isAnyAgentSpace != rhs.isAnyAgentSpace { return !lhs.isAnyAgentSpace }
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
    func activateInFocusedWindow(
        spaceId: String,
        onActivationFailed: (() -> Void)? = nil,
        onSwapSettled: (() -> Void)? = nil
    ) {
        // `keySlot` is weak and can be nil in edge states (e.g. right after a
        // sheet held key, or mid slot-teardown); falling back to the first
        // live slot beats silently dropping the switch — the agent-handoff
        // prompt's "Switch to Agent Space" button lands here.
        guard let slot = keySlot ?? slots.first else {
            AppLogWarn("[SpaceManager] activateInFocusedWindow(\(spaceId)): no live slot")
            onActivationFailed?()
            return
        }
        slot.activate(
            spaceId: spaceId,
            onActivationFailed: onActivationFailed,
            onSwapSettled: onSwapSettled
        )
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
            alert.messageText = NSLocalizedString("spaces.importProgress.deleteSpaceBlocked.title", value: "Can’t delete this Space yet",
                comment: "Title shown when deleting a Space is blocked by an in-progress import"
            )
            alert.informativeText = NSLocalizedString("spaces.importProgress.deleteSpaceBlocked.message", value: "An import is still adding bookmarks to this Space. Wait for it to finish, then try again.",
                comment: "Body shown when deleting a Space is blocked by an in-progress import"
            )
            alert.addButton(withTitle: NSLocalizedString("spaces.importProgress.deleteSpaceBlocked.dismissButton", value: "OK", comment: "Dismiss button"))
            alert.runModal()
            return
        }
        // A parked ghost of this Space dies with it: deleting the Space is
        // the window close its parked window never got, so the record leaves
        // both sides — the Mac bookkeeping and the chromium store + session
        // file — before the row goes (the profile resolution below needs the
        // live row). Without this the next unfiltered restore would replay
        // the deleted Space's window as a loose one.
        dropParkedGhosts(
            parkedGhostSpaceIdsByWindowId.filter { $0.value == spaceId },
            reason: "deleteSpace(\(spaceId))"
        )
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
        // The per-Space theme records live in userDefaults, outside the
        // cascade; prune them here or they linger forever.
        clearThemeRecords(forSpaceId: spaceId)
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
            alert.messageText = NSLocalizedString("spaces.importProgress.changeProfileBlocked.title", value: "Can’t change this Space’s profile yet",
                comment: "Title shown when changing a Space's profile is blocked by an in-progress import"
            )
            alert.informativeText = NSLocalizedString("spaces.importProgress.changeProfileBlocked.message", value: "An import is still adding bookmarks to this Space. Wait for it to finish, then try again.",
                comment: "Body shown when a Space action is blocked by an in-progress import"
            )
            alert.addButton(withTitle: NSLocalizedString("spaces.importProgress.changeProfileBlocked.dismissButton", value: "OK", comment: "Dismiss button"))
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
        // A parked ghost re-binds by materializing FIRST: its tabs exist only
        // in the OLD profile's session file, and the capture below can read
        // live windows only. The re-entry finds no ghost and runs the
        // unchanged flow — which closes the just-materialized window like any
        // background window and replays its tabs on the new profile. A failed
        // materialization aborts the change with everything as it was (alert
        // shown by the materialize): re-binding anyway would strand the
        // parked window under a profile its Space no longer names.
        if let ghostWindowId = parkedGhostWindowId(forSpaceId: spaceId) {
            let slot = keySlot ?? slots.first ?? createSlot(initialSpaceId: spaceId)
            AppLogInfo("[SpaceManager] changeProfile: materializing ghost window \(ghostWindowId) of \(spaceId) first")
            slot.materializeParkedGhost(windowId: ghostWindowId, spaceId: spaceId) { [weak self] ok in
                guard ok else { return }
                self?.changeProfile(spaceId: spaceId, toProfileId: newProfileId)
            }
            return
        }
        AppLogInfo("[SpaceManager] changeProfile: \(spaceId) \(space.profileId) → \(newProfileId)")
        PostHogSDK.shared.capture("space_profile_changed", properties: [
            "total_profiles": ProfileManager.shared.userAssignableProfiles.count,
        ])
        // Capture before closing anything. Pinned tabs are excluded because
        // they are restored from their configured Space/Profile/App scope;
        // new-tab pages are excluded as well. keySlot first so the focused
        // window's tabs lead the reopened order.
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

    /// Returns the pinned theme id stored for `spaceId`, or nil when the
    /// Space has no entry yet (legacy "Follow Global" Spaces awaiting the
    /// one-shot migration, and runtime-only Spaces that were never themed).
    func themeId(forSpaceId spaceId: String) -> String? {
        boundAccount?.userDefaults.spaceThemeIds()[spaceId]
    }

    /// The theme id a Space's UI shows and edits. Every Space owns a theme;
    /// ids missing from the pin map resolve to the current global theme,
    /// which is what those Spaces render as today.
    func resolvedThemeId(forSpaceId spaceId: String) -> String {
        if let pinned = themeId(forSpaceId: spaceId) {
            return pinned
        }
        return MainActor.assumeIsolated { ThemeManager.shared.currentTheme.id }
    }

    /// Pins `themeId` to `spaceId` (nil only clears the stored entry — a
    /// cleanup affordance for ids that are going away, not a user-facing
    /// "follow global" anymore). The change is persisted, the Space's
    /// stored `colorHex` (sidebar tint) is re-derived to match, and the
    /// resolved theme is applied to every live controller bound to that
    /// Space — a Space can have a live controller in multiple slots
    /// simultaneously, so we iterate.
    func setTheme(forSpaceId spaceId: String, themeId: String?) {
        guard let account = boundAccount else { return }
        var map = account.userDefaults.spaceThemeIds()
        if let themeId {
            map[spaceId] = themeId
        } else {
            map.removeValue(forKey: spaceId)
        }
        account.userDefaults.setSpaceThemeIds(map)
        if themeId != nil {
            syncColorHexWithTheme(forSpaceId: spaceId)
        }
        publishResolvedDefaultSpaceThemeIfNeeded(spaceId: spaceId)
        reapplyResolvedTheme(forSpaceId: spaceId)
        postSpaceThemeDidChange(spaceId: spaceId)
    }

    /// The Space's custom overlay saturation for `appearance`, or nil when
    /// it uses its theme's own saturation.
    func overlaySaturation(forSpaceId spaceId: String, appearance: Appearance) -> CGFloat? {
        guard let value = boundAccount?.userDefaults
            .spaceThemeSaturations()[spaceId]?[Self.overlaySaturationKey(for: appearance)] else {
            return nil
        }
        return CGFloat(value)
    }

    /// The overlay saturation the Space's slider should display: the custom
    /// value when one is stored, else the resolved registry theme's value.
    func effectiveOverlaySaturation(forSpaceId spaceId: String, appearance: Appearance) -> CGFloat {
        if let custom = overlaySaturation(forSpaceId: spaceId, appearance: appearance) {
            return custom
        }
        return MainActor.assumeIsolated {
            let manager = ThemeManager.shared
            let base = manager.registeredThemes[resolvedThemeId(forSpaceId: spaceId)]
                ?? manager.currentTheme
            return base
                .color(for: .windowOverlayBackground, appearance: appearance)
                .hsbSaturationComponent
        }
    }

    /// Persists the current appearance's overlay saturation and, in dark mode,
    /// the matching dark window-background saturation, then applies the
    /// resolved theme to live windows.
    func setOverlaySaturation(_ saturation: CGFloat, forSpaceId spaceId: String, appearance: Appearance) {
        guard let account = boundAccount else { return }
        let clampedSaturation = min(max(saturation, 0.1), 0.9)
        var map = account.userDefaults.spaceThemeSaturations()
        var entry = map[spaceId] ?? [:]
        entry[Self.overlaySaturationKey(for: appearance)] = Double(clampedSaturation)
        if appearance.isDark {
            entry[Self.windowBackgroundDarkSaturationKey] = Double(clampedSaturation)
        }
        map[spaceId] = entry
        account.userDefaults.setSpaceThemeSaturations(map)
        publishResolvedDefaultSpaceThemeIfNeeded(spaceId: spaceId)
        reapplyResolvedTheme(forSpaceId: spaceId)
        postSpaceThemeDidChange(spaceId: spaceId)

        let appliedTheme = resolvedTheme(forSpaceId: spaceId)
        Self.logAppliedThemeComponent(
            appliedTheme.color(for: .windowOverlayBackground, appearance: appearance),
            category: "OverlaySaturation",
            role: "windowOverlayBackground",
            spaceId: spaceId,
            appearance: appearance
        )
        Self.logAppliedThemeComponent(
            appliedTheme.color(for: .windowBackground, appearance: .dark),
            category: "WindowBackgroundSaturation",
            role: "windowBackground",
            spaceId: spaceId,
            appearance: .dark
        )
    }

    private static func overlaySaturationKey(for appearance: Appearance) -> String {
        appearance.isDark ? "overlayDark" : "overlayLight"
    }

    private static let windowBackgroundDarkSaturationKey = "windowBackgroundDark"

    /// The Pure theme's custom slider position for the Space, or nil when
    /// the built-in theme value should be used.
    func pureThemeSliderValue(forSpaceId spaceId: String) -> Double? {
        boundAccount?.userDefaults.spacePureThemeSliderValues()[spaceId]
    }

    /// The position the Pure-theme slider should display.
    func effectivePureThemeSliderValue(forSpaceId spaceId: String, appearance: Appearance) -> Double {
        if let custom = pureThemeSliderValue(forSpaceId: spaceId) {
            return custom
        }
        return MainActor.assumeIsolated {
            let manager = ThemeManager.shared
            let base = manager.registeredThemes[resolvedThemeId(forSpaceId: spaceId)]
                ?? manager.currentTheme
            let brightness = base
                .color(for: .windowOverlayBackground, appearance: appearance)
                .hsbBrightnessComponent
            return PureThemeBrightnessScale.sliderValue(
                forBrightness: Double(brightness),
                appearance: appearance
            )
        }
    }

    /// Persists one Pure-theme slider position and maps it to the separate
    /// light and dark brightness ranges.
    func setPureThemeSliderValue(_ sliderValue: Double, forSpaceId spaceId: String) {
        guard let account = boundAccount else { return }
        let clampedSliderValue = min(max(sliderValue, 0), 100)
        var map = account.userDefaults.spacePureThemeSliderValues()
        map[spaceId] = clampedSliderValue
        account.userDefaults.setSpacePureThemeSliderValues(map)
        publishResolvedDefaultSpaceThemeIfNeeded(spaceId: spaceId)
        reapplyResolvedTheme(forSpaceId: spaceId)
        postSpaceThemeDidChange(spaceId: spaceId)

        let appliedTheme = resolvedTheme(forSpaceId: spaceId)
        Self.logAppliedThemeComponent(
            appliedTheme.color(for: .windowOverlayBackground, appearance: .light),
            category: "PureThemeBrightness",
            role: "windowOverlayBackground",
            spaceId: spaceId,
            appearance: .light
        )
        Self.logAppliedThemeComponent(
            appliedTheme.color(for: .windowOverlayBackground, appearance: .dark),
            category: "PureThemeBrightness",
            role: "windowOverlayBackground",
            spaceId: spaceId,
            appearance: .dark
        )
        Self.logAppliedThemeComponent(
            appliedTheme.color(for: .windowBackground, appearance: .dark),
            category: "PureThemeBrightness",
            role: "windowBackground",
            spaceId: spaceId,
            appearance: .dark
        )
    }

    private static func logAppliedThemeComponent(
        _ color: NSColor,
        category: String,
        role: String,
        spaceId: String,
        appearance: Appearance
    ) {
        let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        resolvedColor.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        AppLogDebug("[\(category)] applied \(role) space=\(spaceId) appearance=\(appearance) alpha=\(alpha) hsb=(h:\(hue), s:\(saturation), b:\(brightness))")
    }

    private func postSpaceThemeDidChange(spaceId: String) {
        NotificationCenter.default.post(
            name: .spaceThemeDidChange,
            object: self,
            userInfo: ["spaceId": spaceId]
        )
    }

    /// The default Space also supplies application-scoped chrome. Publish its
    /// resolved copy without writing the per-Space adjustment into the shared
    /// registry or the canonical built-in themes.
    private func publishResolvedDefaultSpaceThemeIfNeeded(spaceId: String) {
        guard spaceId == LocalStore.defaultSpaceId else { return }
        MainActor.assumeIsolated {
            ThemeManager.shared.currentTheme = resolvedTheme(forSpaceId: spaceId)
        }
    }

    /// Whether the Space has a theme id, saturation, or Pure brightness that
    /// its windows must pin. Legacy opacity records are deliberately ignored
    /// because ThemeSnapshot V2 fixes overlay alpha at 0.8.
    fileprivate func hasThemeCustomization(forSpaceId spaceId: String) -> Bool {
        if themeId(forSpaceId: spaceId) != nil {
            return true
        }
        if !(boundAccount?.userDefaults.spaceThemeSaturations()[spaceId] ?? [:]).isEmpty {
            return true
        }
        return boundAccount?.userDefaults.spacePureThemeSliderValues()[spaceId] != nil
    }

    /// Removes all per-Space theme maps' entries for a Space id that is
    /// going away for good; nothing else prunes them and the id never
    /// comes back.
    fileprivate func clearThemeRecords(forSpaceId spaceId: String) {
        guard let account = boundAccount else { return }
        var pins = account.userDefaults.spaceThemeIds()
        if pins.removeValue(forKey: spaceId) != nil {
            account.userDefaults.setSpaceThemeIds(pins)
        }
        var opacities = account.userDefaults.spaceOverlayOpacities()
        if opacities.removeValue(forKey: spaceId) != nil {
            account.userDefaults.setSpaceOverlayOpacities(opacities)
        }
        var saturations = account.userDefaults.spaceThemeSaturations()
        if saturations.removeValue(forKey: spaceId) != nil {
            account.userDefaults.setSpaceThemeSaturations(saturations)
        }
        var pureSliderValues = account.userDefaults.spacePureThemeSliderValues()
        if pureSliderValues.removeValue(forKey: spaceId) != nil {
            account.userDefaults.setSpacePureThemeSliderValues(pureSliderValues)
        }
    }

    /// Re-derives the Space's persisted `colorHex` (the sidebar tint
    /// source) from its resolved theme — the same derivation the create
    /// panel uses — so the tint follows theme changes instead of keeping
    /// the creation-time color. Incognito Spaces have no store row.
    private func syncColorHexWithTheme(forSpaceId spaceId: String) {
        guard !Self.isIncognitoSpaceId(spaceId) else { return }
        let hex = MainActor.assumeIsolated {
            resolvedTheme(forSpaceId: spaceId)
                .color(for: .windowOverlayBackground, appearance: ThemeManager.shared.currentAppearance)
                .hexRGBString
        }
        recolorSpace(spaceId: spaceId, colorHex: hex)
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
    /// controller adopts its Space's theme before first paint.
    func applyPersistedTheme(to controller: MainBrowserWindowController, spaceId: String) {
        // Only touch the context when the Space has something persisted —
        // leaving the default `mirrorsSharedTheme = true` (and an Incognito
        // window's fixed incognito theme) alone otherwise.
        guard hasThemeCustomization(forSpaceId: spaceId) else { return }
        applyResolvedTheme(forSpaceId: spaceId, to: controller)
    }

    /// Pre-view variant of `applyPersistedTheme`: seeds a freshly-created
    /// `BrowserState`'s theme context with the Space's persisted theme
    /// BEFORE any view is built from it. The registerWindow-time apply runs
    /// inside the same controller init but AFTER the view hierarchy is
    /// assembled (`MainSplitViewController(state:)` precedes
    /// `slot.registerWindow`), so views capture the context's default
    /// shared-theme initial value; the corrective `setTheme` then reaches
    /// them through `receive(on: .main)` sinks, which a session replay
    /// holding the main thread defers past first paint — the restored
    /// window visibly repaints from the default theme to the Space's one.
    /// Untouched when nothing is persisted (shared mirroring stays as
    /// configured). Incognito windows are skipped outright: a standalone
    /// incognito window is created with the persisted *normal* Space id, so
    /// the customization guard alone would let that Space's theme override
    /// the fixed incognito theme — and, being excluded from registerWindow,
    /// the window would never be corrected afterwards. (Incognito-Space
    /// windows are skipped too; their synthetic Space never carries
    /// customization, so nothing changes for them.) For normal windows
    /// the register-time apply still runs afterwards and is an idempotent
    /// re-assert.
    func seedPersistedTheme(into browserState: BrowserState, spaceId: String) {
        guard !browserState.isIncognito else { return }
        guard hasThemeCustomization(forSpaceId: spaceId) else { return }
        MainActor.assumeIsolated {
            let context = browserState.themeContext
            context.mirrorsSharedTheme = false
            context.spaceThemeResolver = { [weak self] in
                self?.resolvedTheme(forSpaceId: spaceId)
            }
            context.setTheme(resolvedTheme(forSpaceId: spaceId))
        }
    }

    /// The Theme instance `spaceId`'s windows display: its resolved registry
    /// theme with fixed V2 alpha, then the Space's saturation or Pure
    /// brightness when stored. The copy keeps the registry id so a pinned
    /// `BrowserThemeContext` can re-resolve it after registry-wide edits.
    func resolvedTheme(forSpaceId spaceId: String) -> Theme {
        MainActor.assumeIsolated {
            let manager = ThemeManager.shared
            let registeredBase = manager.registeredThemes[resolvedThemeId(forSpaceId: spaceId)]
                ?? manager.currentTheme
            let base = ThemeColorAdjustment.applyingStandardAlpha(to: registeredBase)
            if base.id == Theme.pure.id {
                return applyingPureThemeBrightness(forSpaceId: spaceId, to: base)
            }
            return applyingSaturation(forSpaceId: spaceId, to: base)
        }
    }

    /// `base` copied with the Space's stored overlay and dark-window
    /// saturation applied under the fixed V2 alpha contract.
    fileprivate func applyingSaturation(forSpaceId spaceId: String, to base: Theme) -> Theme {
        let entry = boundAccount?.userDefaults.spaceThemeSaturations()[spaceId] ?? [:]
        let overlayLight = entry[Self.overlaySaturationKey(for: .light)].map { CGFloat($0) }
        let overlayDark = entry[Self.overlaySaturationKey(for: .dark)].map { CGFloat($0) }
        let windowBackgroundDark = entry[Self.windowBackgroundDarkSaturationKey].map { CGFloat($0) }
        return ThemeColorAdjustment.applyingSaturation(
            light: overlayLight,
            dark: overlayDark,
            darkWindowBackground: windowBackgroundDark,
            to: base
        )
    }

    /// `base` copied with the Space's Pure-theme brightness applied to both
    /// overlay appearances and the dark window background.
    fileprivate func applyingPureThemeBrightness(forSpaceId spaceId: String, to base: Theme) -> Theme {
        guard let sliderValue = pureThemeSliderValue(forSpaceId: spaceId) else {
            return base
        }
        return ThemeColorAdjustment.applyingPureBrightness(
            sliderValue: sliderValue,
            to: base
        )
    }

    /// Applies `spaceId`'s resolved theme to `controller`'s theme context.
    /// Spaces with no persisted customization mirror the global theme —
    /// visually identical to what they resolve to. Touches
    /// `ThemeManager.shared`, which is `@MainActor`-isolated; every caller
    /// is on main already (UI menu actions, slot.registerWindow from
    /// `NSWindowController` init), so we assume main isolation rather than
    /// propagating the annotation through the whole call chain.
    fileprivate func applyResolvedTheme(forSpaceId spaceId: String, to controller: MainBrowserWindowController) {
        MainActor.assumeIsolated {
            let context = controller.browserState.themeContext
            if hasThemeCustomization(forSpaceId: spaceId) {
                context.mirrorsSharedTheme = false
                // Registry-wide edits reach pinned windows by recomputing
                // from this Space's persisted color-component adjustments.
                context.spaceThemeResolver = { [weak self] in
                    self?.resolvedTheme(forSpaceId: spaceId)
                }
            } else {
                // Nothing persisted — restore mirroring so the change is
                // visible without waiting for the next global theme switch.
                context.mirrorsSharedTheme = true
                context.spaceThemeResolver = nil
            }
            context.setTheme(themeAsAppliedToWindows(forSpaceId: spaceId))
        }
    }

    /// The Theme a window bound to `spaceId` actually displays.
    ///
    /// Not the same as `resolvedTheme(forSpaceId:)`: a Space with nothing
    /// persisted gets the global theme, while a customized one gets the
    /// resolved copy carrying its own saturation or brightness. Extracted
    /// because a second caller needs the same answer without a window to ask —
    /// the reopen loading window, which paints its sidebar band before the
    /// window that will replace it exists (`sidebarTint(forSpaceId:)`). Nil
    /// spaceId means the slot has no active Space, which leaves the global
    /// theme as the only thing there is to say.
    ///
    /// No alpha normalisation here, and an earlier version of this function
    /// added one on the theory that a registry theme with a different overlay
    /// alpha would read differently through this path than through a window's.
    /// It cannot: `Theme.colorPair(for:)` forces the overlay role to
    /// `defaultOverlayAlpha` on every read, whoever is asking.
    fileprivate func themeAsAppliedToWindows(forSpaceId spaceId: String?) -> Theme {
        MainActor.assumeIsolated {
            guard let spaceId, hasThemeCustomization(forSpaceId: spaceId) else {
                return ThemeManager.shared.currentTheme
            }
            return resolvedTheme(forSpaceId: spaceId)
        }
    }

    /// The colour the sidebar of a window bound to `spaceId` fills itself with.
    ///
    /// `SidebarViewController`'s own role — `windowOverlayBackground`, the one
    /// it gives its root view — resolved against the very theme that window
    /// will be handed. Deliberately the role and not a colour picked to look
    /// close: a Space with a pinned theme or a moved saturation slider has its
    /// own sidebar colour, and only reading the role follows it.
    ///
    /// What it is NOT is the sidebar's pixels. The real one is an
    /// `NSVisualEffectView` with this colour layered over a `.fullScreenUI`
    /// material, so what the material picks up from behind the window is
    /// missing from a flat fill. The boundary between band and content is the
    /// thing that has to be exact, and that comes from the width, not from here.
    func sidebarTint(forSpaceId spaceId: String?) -> NSColor {
        MainActor.assumeIsolated {
            themeAsAppliedToWindows(forSpaceId: spaceId)
                .color(for: .windowOverlayBackground,
                       appearance: ThemeManager.shared.currentAppearance)
        }
    }

    /// Re-applies the Space's resolved theme to every live controller
    /// bound to it, across all slots.
    fileprivate func reapplyResolvedTheme(forSpaceId spaceId: String) {
        for slot in slots {
            if let controller = slot.windowController(for: spaceId) {
                applyResolvedTheme(forSpaceId: spaceId, to: controller)
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
        refreshAccountBindingForBrowserAccess()
        // Re-run the reconcile skipped before browser access. Async so it lands after
        // the window manager registers the dangling windows on this same
        // `.loginCompleted` post, so `activate` swaps instead of spawning.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Read fresh from the bound account; `self.spaces` may still hold the
            // pre-login default-account emission (bind refreshes it async).
            let spaces = self.boundAccount?.localStorage.getAllSpaces() ?? self.spaces
            // A promotion can bind its target while default-Space creation is
            // fenced. Once login commits, retry the idempotent initialization;
            // its publisher emission will reconcile the populated store.
            guard !spaces.isEmpty else {
                self.ensureDefaultSpaceForCurrentAccountIfReady()
                return
            }
            self.handleSpacesUpdate(spaces)
        }
    }

    @objc private func handleAccountChanged(_ notification: Notification) {
        refreshAccountBindingForBrowserAccess()
    }

    @objc private func handleBrowserAccessStateDidChange() {
        refreshAccountBindingForBrowserAccess()
    }

    private func refreshAccountBindingForBrowserAccess() {
        guard let account = AccountController.shared.localDataAccount else {
            unbind()
            return
        }
        bind(to: account)
    }

    /// Rebinds Space persistence after a pre-import Guest migration failure
    /// replaces the terminal source Account object with a fresh default
    /// account over the same intact directory. Browser access does not change
    /// in this rollback, so its normal observers have no event to react to.
    @MainActor
    func refreshGuestAccountBindingAfterMigrationRollback() {
        guard ApplicationState.shared.isGuest,
              !ApplicationState.shared
                .isGuestAccountPromotionInProgress else {
            return
        }
        refreshAccountBindingForBrowserAccess()
    }

    /// Displays were added, removed, or re-configured. A slot parks its windows
    /// wherever the user dragged the group, and nothing else re-checks that
    /// placement against the screens: AppKit's own repair runs through
    /// `constrainFrameRect:toScreen:`, which Phi's `BrowserNativeWidgetWindow`
    /// overrides so the client's deliberate off-screen placement survives being
    /// ordered in. That trade is only safe if the client notices when a layout
    /// change turns its placement into one the user cannot undo.
    ///
    /// Fires for far more than resolution changes (Dock and menu-bar geometry,
    /// display sleep/wake), which is fine — every slot whose placement is still
    /// usable is a no-op.
    @objc private func handleScreenParametersChanged() {
        for slot in slots {
            slot.revalidatePlacementForScreenChange()
        }
    }

    private func bind(to account: Account) {
        guard boundAccount !== account else { return }
        boundAccount = account
        // Load before the first Chromium window arrives so
        // `claimRestoredWindow` can answer for session-restore callbacks
        // that race the SwiftData publishers below.
        loadRestoreSnapshot()

        // Seed `spaces` from a direct fetch SYNCHRONOUSLY, for the same
        // reason `loadRestoreSnapshot` runs here and not in the task below:
        // this bind runs on the main thread before Chromium is up, while the
        // task is queued on the MainActor and a cold-launch session replay
        // holds the main thread for seconds — measured ~1.4s from bind to
        // task entry, well past the restored windows' first paint, which
        // therefore rendered every `spaces` reader (Space pips, tints,
        // profile lookups) with defaults until the late delivery re-colored
        // them.
        //
        // DATA ONLY — deliberately NOT `handleSpacesUpdate`: bind can run
        // inside `SpaceManager.init` (the singleton's first touch), and the
        // full update path's side effects are unsafe that early — its login
        // gate (`checkLoginStatusOnChromiumLaunch`) reaches
        // `AccountController.account`'s didSet, whose shortcut reload asks
        // the bridge to rebuild the main menu before AppKit is ready
        // (startup crash in `NSMenu _setMenuName:`). Assigning the
        // @Published array is effect-free here (no subscribers exist yet);
        // slot reconciliation, migrations, and the default-space theme
        // publish all run on the publisher's first emission, which replaces
        // this seed wholesale through `handleSpacesUpdate` as before. The
        // store fetch itself is the established synchronous main-context
        // pattern (`handleLoginCompleted` / `boundProfileId`); bind runs on
        // the main thread (account notifications post there), matching this
        // file's other `assumeIsolated` entries.
        let seededSpaces = MainActor.assumeIsolated {
            account.localStorage.getAllSpaces()
        }
        if !seededSpaces.isEmpty {
            lastStoreSpaces = seededSpaces
            spaces = seededSpaces
        }

        Task { @MainActor [weak self] in
            guard let self, self.boundAccount === account else { return }
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
            self.ensureDefaultSpaceForCurrentAccountIfReady()
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
            alert.messageText = NSLocalizedString("spaces.closeIncognitoConfirmation.title", value: "This will also close this Incognito Space, are you sure?",
                comment: "Title of the confirmation shown when a close would tear down an Incognito Space")
            alert.alertStyle = .warning
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = NSLocalizedString("spaces.closeIncognitoConfirmation.doNotAskAgainCheckbox", value: "Do not ask again",
                comment: "Suppression checkbox of the close-Incognito-Space confirmation")
            alert.addButton(withTitle: NSLocalizedString("spaces.closeIncognitoConfirmation.closeButton", value: "Close", comment: "Confirm closing an Incognito Space"))
            alert.addButton(withTitle: NSLocalizedString("spaces.closeIncognitoConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
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
    /// strip. Its per-Space theme records are cleared too — the id is
    /// runtime-only, so a leftover entry could never be read again.
    private func removeIncognitoSpaceDescriptor(_ spaceId: String) {
        guard incognitoSpaces.contains(where: { $0.spaceId == spaceId }) else { return }
        incognitoSpaces.removeAll { $0.spaceId == spaceId }
        clearThemeRecords(forSpaceId: spaceId)
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
        let hadBoundAccount = boundAccount != nil
        boundAccount = nil
        if hadBoundAccount {
            observedNormalWindowProfileId = nil
        }
        spacesCancellable?.cancel()
        spacesCancellable = nil
        rulesCancellable?.cancel()
        rulesCancellable = nil
        cachedURLRules = []
        hasLoadedURLRules = false
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
        // The same family `loadRestoreSnapshot` resets, park set included: all
        // of it describes the previous session of the account being unbound.
        // The park set was the one field left behind, which kept an activation
        // of a signed-out account's Space routed at a window in a session file
        // this side can no longer reach. Nothing writes the snapshot while
        // unbound (there is no account to write to) and a rebind reloads it, so
        // this is hygiene rather than a record that could be lost — but leaving
        // one member of a family behind is how the next reader learns the wrong
        // rule.
        restoreEntries.removeAll()
        restoreIndexByWindowId.removeAll()
        restoredSlotsByIndex.removeAll()
        parkedGhostSpaceIdsByWindowId.removeAll()
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
        hasLoadedURLRules = true
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
        // Agent Spaces always trail user Spaces, whatever their stored
        // sortOrder: agent Spaces are appended at the global max on creation,
        // but a user Space created while one lives would otherwise land after
        // it. Grouping here — the single point every surface's order flows
        // through — keeps the strip, the switcher menus, and the ⌃-number
        // bindings agreeing, and lets the strip draw one divider between the
        // groups. Stable partition: each group keeps its stored order, and a
        // reorder commit (which persists the displayed order) renumbers the
        // store toward this arrangement rather than fighting it.
        updated = updated.filter { !$0.isAnyAgentSpace } + updated.filter(\.isAnyAgentSpace)
        lastStoreSpaces = updated
        migrateLegacyFollowGlobalPinsIfNeeded(storeSpaces: updated)
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
            // A new Incognito Space (no recorded position) joins after the
            // user Spaces but before the agent group, so it never lands past
            // the strip's agent divider. Recomputed per insert — an earlier
            // default-positioned Incognito Space shifts the boundary.
            let defaultIndex = updated.firstIndex(where: \.isAnyAgentSpace) ?? updated.count
            let index = min(max(descriptor.sortIndex ?? defaultIndex, 0), updated.count)
            updated.insert(makeIncognitoSpace(descriptor: descriptor, sortOrder: index), at: index)
        }
        spaces = updated
        if updated.contains(where: { $0.spaceId == LocalStore.defaultSpaceId }) {
            publishResolvedDefaultSpaceThemeIfNeeded(spaceId: LocalStore.defaultSpaceId)
        }
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

        // Gate on browser access: before Guest entry or login, windows are
        // dangling and not yet in any slot's `windowsBySpaceId`, so `activate`'s
        // spawn guard cannot see them and would spawn a duplicate empty window.
        // Access-state changes re-run this once windows are registered.
        if ApplicationState.shared.canUseBrowser {
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
                // A slot whose restore reconcile is still running may sit on a
                // Space the store simply hasn't delivered yet: on cold launch
                // the SwiftData publisher's first emission races the restored
                // windows, and a partial list would misread the snapshot's
                // active Space as deleted — kicking the slot to a fallback and
                // overwriting the persisted active Space mid-restore. Skip it;
                // a genuinely deleted Space is re-reconciled by the next store
                // emission once the restore settles.
                if slot.restoreVisibilityReconcileScheduled {
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
            // Followers of "which window is the slot showing" (the docked
            // agent console re-homes on this) need a signal that also covers
            // PROGRAMMATIC switches: while Phi is inactive (the user is in
            // their terminal and the code agent switches Spaces),
            // makeKeyAndOrderFront cannot make the window key, so
            // didBecomeKey-based following never fires.
            NotificationCenter.default.post(
                name: .spaceSlotVisibleWindowDidChange, object: self)
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

    /// The loading window standing in for this slot while its windows are
    /// replayed, lent to it by `SpaceManager.slotForRestoreIndex`. Nil whenever
    /// the feature is off. The manager keeps its own reference and owns the
    /// hand-off's end; this one exists so the slot can drop the loading window
    /// behind the restored window that arrives (`pinUnder`) and close it
    /// early if that window goes away again.
    private var reopenLoadingWindow: ReopenLoadingWindow?

    /// Where this slot reopened, when a reopen put a loading window there
    /// first. Every window that registers into the slot without a more specific
    /// pending frame is forced onto it, so the restored window and the loading
    /// window it replaces occupy the same rect — the alternative is trusting
    /// Chromium's replayed bounds to agree, which is exactly the assumption the
    /// no-jump promise cannot rest on. Measured: Chromium replays a slot the
    /// user parked overhanging a screen edge fully back on screen, 763pt away.
    ///
    /// In force until the restore settles (`endReopenPlacementOverride`) —
    /// this reopen's remaining windows are still arriving, and every one of
    /// them belongs on the same rect. Holding it past that would force the
    /// frame on windows this reopen never promised anything about: a later
    /// spawn that queues no frame of its own (a hidden agent-Space window)
    /// would be dragged onto the reopen rect. The loading window outlives the
    /// override rather than the other way round (`ReopenLoadingHandoff`), and
    /// nothing needs the two to end together: by then the restored window is
    /// on the rect and the loading window is behind it.
    private var reopenPlacementFrame: NSRect?

    /// Takes over the loading window standing in for this slot, and the frame
    /// it occupies. See `reopenLoadingWindow` and `reopenPlacementFrame`.
    fileprivate func adoptReopenLoadingWindow(_ window: ReopenLoadingWindow,
                                              placedAt frame: NSRect) {
        reopenLoadingWindow = window
        reopenPlacementFrame = frame
    }

    /// Closes this slot's loading window, if it still has one. The forced
    /// placement deliberately survives — see `reopenPlacementFrame`.
    private func closeReopenLoadingWindow() {
        reopenLoadingWindow?.close()
        reopenLoadingWindow = nil
    }

    /// Stops forcing this reopen's remembered frame on newly registered
    /// windows. Called from `SpaceManager` once the restore settles — before
    /// the loading window goes, which outlives it.
    fileprivate func endReopenPlacementOverride() {
        reopenPlacementFrame = nil
    }

    /// Ends the reopen hand-off for this slot: closes anything still up and
    /// stops forcing the reopen frame. Called from `SpaceManager` when the
    /// hand-off's deadline arrives.
    fileprivate func endReopenLoadingHandover() {
        closeReopenLoadingWindow()
        endReopenPlacementOverride()
    }

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
    /// closing the last tab in the active Space, not by closing the
    /// window itself. Populated by `markTabDrivenClose` from
    /// `Tab.close()` just before dispatching
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
    /// Cancelled by `cancelTabDrivenClose` when the window enters
    /// placeholder mode. A last-tab close in a normal non-Incognito
    /// window always does, so the auto-close this marker predicts never
    /// happens and no user gesture carries a live marker into
    /// `unregisterWindow` — the tab-driven hand-off there is currently
    /// unreachable through this path.
    ///
    /// Stored as spaceId → expiration deadline rather than a plain
    /// set: when the dispatched `IDC_CLOSE_TAB` is vetoed (typically
    /// an `onbeforeunload` prompt the user cancels), the window enters
    /// no placeholder and no `unregisterWindow` ever fires, so nothing
    /// cancels or drains the marker and a later window-driven close
    /// would otherwise misclassify itself as tab-driven. The TTL caps
    /// that stale window at `Self.tabDrivenCloseTTL` seconds. This
    /// residual is the only remaining way a live marker reaches
    /// `unregisterWindow`, and it is a known defect rather than an
    /// intended behavior.
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
    /// `pendingTabDrivenCloseDeadlines` — drained and cancelled
    /// alongside it, and reachable only through the same residual.
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

    /// Swapped onto the visible window alongside the two observers above, and
    /// for the same job: the sidebar's width lives on that window's
    /// `BrowserState`, so it has to follow the window the slot is showing. See
    /// `observeSidebarWidth`.
    private var visibleSidebarWidthObserver: AnyCancellable?

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

    /// `lastKnownFrame` minus the fullscreen rects — the geometry this slot
    /// would occupy as an ordinary window. Kept apart because the two answer
    /// different questions: `lastKnownFrame` is "align the siblings to this",
    /// which must follow the window into fullscreen, while this is "reopen
    /// here", which must not (a restored window always comes back windowed, so
    /// a screen-sized rect would be a lie every time it were used).
    ///
    /// Refreshed from the visible window's live frame whenever one is available
    /// — by the frame observer on every move/resize, and by `snapshotFrame` at
    /// each persist — so a slot that enters fullscreen keeps the position it
    /// had on the way in. Nil only before the slot has ever had a positioned
    /// window outside fullscreen.
    private var lastKnownWindowedFrame: NSRect?

    /// The other two things the cross-launch record carries about how this slot
    /// LOOKS, as opposed to where it sits: the sidebar's width and the leading
    /// traffic light's origin. Cached for the same reason as the frame above —
    /// a persist can run while the window is being torn down, and the last
    /// value the slot actually had beats none. Nil only before the slot has had
    /// a window to read them off. Written by `snapshotSidebarWidth` /
    /// `snapshotTrafficLightOrigin`, read by nothing else.
    private var lastKnownSidebarWidth: CGFloat?
    private var lastKnownTrafficLightOrigin: NSPoint?

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
    /// it as a fallback after their own snapshot attempt fails. Only the
    /// tab-driven hand-off passes it, so it is currently unreachable
    /// outside the residual documented on `unregisterWindow`.
    func activate(
        spaceId: String,
        leavingSnapshotOverride: NSImage? = nil,
        animated: Bool = true,
        userInitiated: Bool = false,
        onActivationFailed: (() -> Void)? = nil,
        onSwapSettled: (() -> Void)? = nil
    ) {
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
            onActivationFailed?()
            return
        }
        guard let manager,
              manager.spaces.contains(where: { $0.spaceId == spaceId }) else {
            AppLogWarn("[SpaceWindowSlot] activate ignored: unknown spaceId \(spaceId)")
            onActivationFailed?()
            return
        }
        // The reopen row of the switch decision — behind the validity guard
        // above, so a Space this side does not know is still answered as
        // unknown rather than as "dropped", and ahead of every side effect
        // below, so a dropped activation leaves nothing half-done. While an ARMED
        // windowless reopen's replay is in flight, every activation is
        // dropped; see `reopenDropsActivations` for why, for why an unarmed
        // reopen (the switch off, an older framework, a run that parked
        // nothing) keeps meeting activations exactly as it always did, and
        // for why `AppController`'s neighbouring gate is deliberately not
        // conditioned the same way. The log line makes the drop diagnosable.
        if SpaceManager.reopenDropsActivations(
            isSessionRestoreInFlight: manager.isSessionRestoreInFlight,
            isLazyReopenArmed: manager.lastReopenArmedLazyRestore) {
            AppLogInfo("[SpaceWindowSlot] activate(\(spaceId)) dropped: lazy session restore in flight")
            onActivationFailed?()
            return
        }
        // An explicit activation supersedes any earlier key-event adoption:
        // from here on the active Space reflects a deliberate switch, so the
        // window-driven cascade must not "undo" it (see
        // `activeSpaceAdoptedFromKeyEvent`). Below the guard above because an
        // activation that names a Space this side does not know changes no
        // active Space, and so supersedes nothing.
        activeSpaceAdoptedFromKeyEvent = false
        isPerformingActivate = true
        defer { isPerformingActivate = false }

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
            if userInitiated {
                PostHogSDK.shared.capture("space_switched", properties: [
                    "total_spaces": manager.spaces.count,
                ])
            }
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
                // A minimized target can only come back via `deminiaturize` —
                // `makeKeyAndOrderFront` leaves it in the Dock — and the
                // slide/push-in machinery assumes an orderly hidden window.
                // Restore it here, after the frame/sidebar sync above so the
                // Dock fly-out lands on the slot's frame, and let that
                // fly-out stand in for the switch animation.
                let restoredFromDock = target.window?.isMiniaturized == true
                if restoredFromDock {
                    target.window?.deminiaturize(nil)
                }
                if animated && !restoredFromDock {
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
            } else {
                // Re-activating the already-active Space is an explicit ask
                // to surface it — the agent-handoff prompt's "Switch to
                // Agent Space" lands here. The window can be minimized in
                // the Dock, ordered out, or parked off the user's current
                // desktop while `isVisible` still reads true, so don't
                // gate on state probes: deminiaturize when needed, then
                // always re-front — `.moveToActiveSpace` lands it on the
                // desktop the user is actually looking at, and fronting an
                // already-frontmost window is harmless.
                if let targetWindow = target.window {
                    AppLogInfo("[SpaceWindowSlot] activate same-space \(spaceId): miniaturized=\(targetWindow.isMiniaturized) visible=\(targetWindow.isVisible) key=\(targetWindow.isKeyWindow) onActiveSpace=\(targetWindow.isOnActiveSpace) occlusionVisible=\(targetWindow.occlusionState.contains(.visible)) windowNumber=\(targetWindow.windowNumber)")
                    if targetWindow.isMiniaturized {
                        targetWindow.deminiaturize(nil)
                    }
                    makeKeyAndOrderFrontHidingSlotTabBar(targetWindow)
                }
                onSwapSettled?()
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
            onActivationFailed?()
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("[SpaceWindowSlot] activate cannot spawn: bridge unavailable")
            onActivationFailed?()
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
        // Ghost row of the switch decision: a Space whose window is parked in
        // the session file materializes it instead of spawning fresh — the
        // parked tabs ARE the Space's content, and a fresh window would stand
        // beside the parked record as a doubled Space. The window arrives
        // through the same pending-spawn claim as a spawned one and Chromium
        // shows it itself (the foreign restore path), so this leg only
        // finishes the switch the way an instant present does; the slide
        // animation is deliberately not run (the accepted product semantics
        // of materialization: the window appears at once). Failure keeps the
        // slot as it is — alert shown by the materialize, no fallback spawn
        // (the session file may still describe the parked window).
        if let ghostWindowId = manager.parkedGhostWindowId(forSpaceId: spaceId) {
            materializeParkedGhost(windowId: ghostWindowId, spaceId: spaceId) {
                [weak self, weak previous] ok in
                guard let self, ok else {
                    onActivationFailed?()
                    return
                }
                guard let registered = self.windowsBySpaceId[spaceId] else {
                    // The bridge reported success but no window claimed into
                    // this slot — nothing to present; leave the previous
                    // window in place.
                    AppLogWarn("[SpaceWindowSlot] activate(\(spaceId)): materialized window did not register")
                    onActivationFailed?()
                    return
                }
                self.makeKeyAndOrderFrontHidingSlotTabBar(registered.window)
                self.orderOutIfNotTabbedWithTarget(previous?.window,
                                                   targetWindow: registered.window)
                onSwapSettled?()
            }
            return
        }
        // Bind the new Chromium Browser to the Space's profile, re-read from
        // `spaces` on every spawn. When a Space is re-bound to another
        // profile (`changeProfile`), its windows are closed and the next
        // activation lands here to respawn on the new profile.
        let targetProfileId = manager.spaces.first(where: { $0.spaceId == spaceId })?.profileId
        // An Incognito Space spawns its own window type instead: Chromium
        // ignores the profileId and binds the Browser to the shared
        // off-the-record profile all Incognito Spaces live on.
        let isIncognitoSpace = SpaceManager.isIncognitoSpaceId(spaceId)
        // Fullscreen slots keep the legacy VISIBLE spawn. The hidden-spawn
        // reveal has to surface the new window through the fullscreen tab
        // group, and selecting a window that has never been ordered in swaps
        // it "into" fullscreen without its fullscreen state ever becoming
        // real — NSWindowStackController then asserts ("windowToTakeFrom
        // should be in FS") on the next tab swap that uses it as the frame
        // source (e.g. Chromium re-activating a sibling) and crashes the
        // app. In fullscreen, Chromium's own Show() surfaces the window
        // exactly as before the animate-first change.
        let spawnHidden = !slotHasFullScreenWindow
        // Animate-first: start the push-in NOW, on the leaving window, against
        // a transparent entering band — the target window doesn't exist yet,
        // so there is nothing to snapshot. The spawn below runs behind the
        // slide (the overlay's Core Animation plays in the render server even
        // while `createBrowser` blocks the main thread) and the reveal fires
        // once BOTH the slide and the spawn have finished. nil when the
        // animated push-in can't run (horizontal layout, `animated: false`,
        // fullscreen slot, no visible previous window) — the spawn then
        // presents the target instantly once it's ready.
        let spawnSwitch: SpawnSwitchAnimation? = (animated && spawnHidden)
            ? beginSpawnVerticalPushIn(
                targetSpaceId: spaceId,
                previous: previous,
                leavingBand: verticalLeavingBand,
                direction: direction,
                sourceColorHex: sourceColorHex,
                targetColorHex: targetColorHex,
                onActivationFailed: onActivationFailed,
                onSwapSettled: onSwapSettled
            )
            : nil
        let spawn: () -> Void = { [weak self, weak previous, weak manager] in
            guard let self = self else {
                if let spawnSwitch {
                    spawnSwitch.settle()
                } else {
                    onActivationFailed?()
                }
                return
            }
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
            // `hidden` — Chromium skips its post-create Show() and the window
            // stays ordered out until the reveal below fronts it, so an
            // empty, unpainted NSWindow can never flash on screen (the root
            // of the old first-switch glitch). False only for fullscreen
            // slots, which keep the legacy Chromium-Show()n spawn (see
            // `spawnHidden` above).
            let dict = bridge.createBrowser(withWindowType: isIncognitoSpace ? .incognitoSpace : .normal,
                                            profileId: isIncognitoSpace ? nil : targetProfileId,
                                            hidden: spawnHidden)
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
                if let spawnSwitch {
                    spawnSwitch.spawnFailed()
                } else {
                    onActivationFailed?()
                }
                return
            }
            guard let windowIdNumber = dict["windowId"] as? NSNumber else {
                AppLogWarn("[SpaceWindowSlot] createBrowserWithWindowType returned no windowId")
                self.pendingSpawnSpaceIds.remove(spaceId)
                if let spawnSwitch {
                    spawnSwitch.spawnFailed()
                } else {
                    onActivationFailed?()
                }
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
            // window-controller ctor, but Chromium's WindowSizer can still
            // snap the freshly-spawned window back to its default creation
            // bounds after the ctor returns, and an async remote_cocoa bounds
            // update can land a turn later. The window spawns hidden
            // (`hidden: true` above), so none of this is user-visible — the
            // re-asserts just guarantee the frame has settled by the time the
            // reveal fronts the window. Both are idempotent no-ops once the
            // frame has stuck.
            if let inheritedFrame {
                self.windowsBySpaceId[spaceId]?.window?.setFrame(inheritedFrame, display: false)
                DispatchQueue.main.async { [weak self] in
                    self?.windowsBySpaceId[spaceId]?.window?.setFrame(inheritedFrame, display: false)
                }
            }
            // A spawned Browser starts with zero tabs, and nothing else
            // repopulates it: Chromium session restore is suppressed for this
            // exact call (`createBrowserWithWindowType:` wraps Browser::Create
            // in ScopedOpeningNewWindow — a reopened Space deliberately starts
            // fresh), so the old "defer the new-tab page past the restore
            // burst" 0.6s wait guarded against a burst that can no longer
            // happen and just left the Space tab-less for a second. Seed the
            // first tab immediately instead; a profile-change reopen replays
            // its captured URLs in its place. Neither call activates the
            // still-hidden window (TabsProxy gates Activate on visibility).
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
                    // Off-the-record windows render the NATIVE new-tab page:
                    // mark the arriving tab before creating it, exactly like
                    // `newBrowserTab` does. Without this the Incognito Space's
                    // first tab shows the raw web chrome://newtab, which is
                    // blank for its OTR profile.
                    if let state = self.windowsBySpaceId[spaceId]?.browserState,
                       state.isIncognito {
                        state.enqueueNativeNTP()
                    }
                    bridge.createQuickLookupTab(withWindowId: windowIdNumber.int64Value,
                                                customGuid: nil)
                }
            }
            // Reveal. The window spawned hidden — Chromium never Show()s it —
            // so surfacing is entirely the slot's job:
            //  - animated vertical switch: hand the registered controller to
            //    the in-flight push-in, which hot-swaps the real band into the
            //    slide and fronts the window once the slide lands (or right
            //    away if it already has).
            //  - otherwise: present instantly now that the window is ready.
            // Either way the previous window stays on screen until the target
            // actually fronts, so the screen never shows an empty, unpainted
            // window — the root of the old "NSWindow not ready" glitch.
            guard let registered = self.windowsBySpaceId[spaceId] else {
                // Registration didn't happen synchronously inside
                // createBrowser — the windowId-keyed maps above cover the late
                // callback, but there is no controller to reveal yet. Settle
                // the animation back onto the leaving window instead of
                // leaving it armed forever.
                AppLogWarn("[SpaceWindowSlot] spawn(\(spaceId)): window \(id) not registered synchronously, skipping reveal")
                if let spawnSwitch {
                    spawnSwitch.settle()
                } else {
                    onActivationFailed?()
                }
                return
            }
            if let spawnSwitch, spawnSwitch.spawnCompleted(registered) {
                return
            }
            // Instant present — no animation is running (bandless layout,
            // `animated: false`, or a superseded push-in). Skip the front
            // entirely if the user switched elsewhere mid-spawn: the window
            // stays registered and hidden, and a later switch back surfaces
            // it through the normal swap path.
            guard self.activeSpaceId == spaceId else {
                onActivationFailed?()
                return
            }
            self.makeKeyAndOrderFrontHidingSlotTabBar(registered.window)
            self.orderOutIfNotTabbedWithTarget(previous?.window, targetWindow: registered.window)
            // The spawned target is up and the leaving window is hidden — let
            // a post-swap close (e.g. `deleteSpace`) run now that it lands
            // off-screen. No-op for ordinary switches, which pass no handler.
            onSwapSettled?()
        }
        // Mark the spawn in flight across the (possibly async) profile load and
        // window creation, so a repeat activation of this Space is gated above.
        // Drained by `registerWindow` on success and by every bail below.
        pendingSpawnSpaceIds.insert(spaceId)
        // Lazy-load the Space's profile before spawning. Completion fires
        // synchronously when the profile is already in memory (the common
        // case). First cross-profile activation of the session pays the load
        // cost (~100–300ms) — the push-in (or, unanimated, the previous
        // window simply staying front) covers that gap: the reveal fires only
        // once the spawned window is actually ready.
        let kickSpawn: () -> Void = {
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
                        if let spawnSwitch {
                            spawnSwitch.spawnFailed()
                        } else {
                            onActivationFailed?()
                        }
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
                        if let spawnSwitch {
                            spawnSwitch.spawnFailed()
                        } else {
                            onActivationFailed?()
                        }
                        return
                    }
                    spawn()
                }
            } else {
                spawn()
            }
        }
        if spawnSwitch != nil {
            // One-turn hop before the (possibly synchronous) profile load +
            // createBrowser: the push-in's Core Animation transaction commits
            // at the end of THIS turn, and only an already-committed slide
            // keeps playing in the render server through createBrowser's
            // ~100–200ms main-thread block.
            DispatchQueue.main.async(execute: kickSpawn)
        } else {
            kickSpawn()
        }
    }

    /// Materializes the parked ghost window `windowId` for `spaceId` into
    /// this slot: the window rebuilds from the session file — tabs, pins,
    /// groups and split layout intact — arrives through the same
    /// pending-spawn claim as a spawned window (`currentSpawn`; the
    /// window-created callback fires inside the bridge call, before any
    /// windowId-keyed intent could exist), and registers here. It must never
    /// travel the restore claim instead: that track concealment-marks
    /// non-active siblings and routes by the SAVED slot, where this window
    /// belongs to the slot that asked for it. Chromium shows the window
    /// itself (the foreign restore path), so the caller only decides what to
    /// do with the previously visible one.
    ///
    /// The ghost bookkeeping is consumed just before the bridge call — the
    /// registration inside it persists a snapshot, and that write must not
    /// fold the park entry in next to the live window — and deliberately not
    /// restored on failure past a successful profile load: NO then means the
    /// store holds no such ghost, and keeping the record would pin the Space
    /// on a materialization that can never succeed, where dropping it lets
    /// the next activation open the Space fresh. A profile that fails to
    /// LOAD keeps every record — that failure is transient and the ghost is
    /// still real. Which of the two happened is what the failure alert says
    /// (`GhostMaterializeFailure`).
    ///
    /// `completion` runs with the outcome once the attempt settles (the
    /// profile load may be asynchronous); on failure nothing is on screen,
    /// an alert is on its way, and — load failures aside — the stale records
    /// are gone.
    func materializeParkedGhost(windowId: Int, spaceId: String,
                                completion: @escaping (Bool) -> Void) {
        guard let manager else {
            completion(false)
            return
        }
        // Same repeat gate as a spawn, spanning the async profile load: a
        // second activation of the Space while this attempt is in flight
        // must not queue a second window.
        if pendingSpawnSpaceIds.contains(spaceId) {
            AppLogInfo("[SpaceWindowSlot] materialize(\(spaceId)): attempt already in flight, ignoring repeat")
            completion(false)
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol
                  .materializeGhostWindow(_:profileId:completion:))) else {
            // Unreachable in practice — records only exist when arming
            // probed the selector family — but a stale build combination
            // must fail loudly rather than trap. No alert: this one is a
            // build accident, not a state the user can act on.
            AppLogWarn("[SpaceWindowSlot] materialize(\(spaceId)): bridge unavailable or too old")
            completion(false)
            return
        }
        // Claimed here rather than after the profile resolves, so that EVERY
        // path from this point on — including the failing ones — holds the
        // repeat gate until its alert has been dismissed (`failMaterialize`).
        pendingSpawnSpaceIds.insert(spaceId)
        // The ghost was parked under the profile its Space is bound to —
        // an unresolvable binding means the record cannot be honored.
        guard let profileId = manager.boundProfileId(forSpaceId: spaceId),
              !profileId.isEmpty else {
            AppLogWarn("[SpaceWindowSlot] materialize(\(spaceId)): no bound profile")
            failMaterialize(.recordKept, spaceId: spaceId, completion: completion)
            return
        }
        // Captured before the (possibly asynchronous) profile load, exactly
        // like the spawn path: the source window can close during the gap,
        // and the slot's shared frame resolution is only valid while it is
        // alive.
        let previous = visibleController
        let inheritedFrame = resolveInheritedFrame(from: previous)
        let inheritedSidebarWidth = previous?.browserState.sidebarWidth ?? 0
        let inheritedSidebarCollapsed = previous?.browserState.sidebarCollapsed
        bridge.ensureProfileLoaded(profileId) { [weak self, weak manager] success in
            guard let self, let manager else {
                completion(false)
                return
            }
            guard success else {
                // Transient: the records stay, a later attempt may succeed.
                AppLogWarn("[SpaceWindowSlot] materialize(\(spaceId)): ensureProfileLoaded failed for \(profileId)")
                self.failMaterialize(.recordKept, spaceId: spaceId, completion: completion)
                return
            }
            manager.consumeParkedGhost(windowId: windowId)
            // The intent claim: the coordinator's first-priority pending-spawn
            // lookup resolves the arriving window to THIS slot and Space via
            // `currentSpawn`, and `registerWindow` applies the inherited
            // frame and sidebar shape — the reopened Space surfaces where the
            // slot sits, keeping the one-window illusion.
            manager.currentSpawn = SpaceManager.SpawnContext(
                slot: self,
                spaceId: spaceId,
                inheritedFrame: inheritedFrame,
                inheritedSidebarWidth: inheritedSidebarWidth,
                inheritedSidebarCollapsed: inheritedSidebarCollapsed
            )
            var materialized = false
            // Synchronous: the window callback (claim + registration) and the
            // completion both run inside this call.
            bridge.materializeGhostWindow(Int32(windowId), profileId: profileId) { ok in
                materialized = ok
            }
            manager.currentSpawn = nil
            guard materialized else {
                AppLogError("[SpaceWindowSlot] materialize(\(spaceId)): chromium held no ghost \(windowId) — stale record dropped")
                self.failMaterialize(.recordDropped, spaceId: spaceId, completion: completion)
                return
            }
            self.pendingSpawnSpaceIds.remove(spaceId)
            AppLogInfo("[SpaceWindowSlot] materialize(\(spaceId)): window \(windowId) rebuilt live")
            completion(true)
        }
    }

    /// Ends a failed materialization: reports it to the caller now, and puts
    /// the alert up on the next turn of the runloop.
    ///
    /// Both halves of that are load-bearing. The alert is deferred because a
    /// profile that was already loaded completes `ensureProfileLoaded`
    /// synchronously from inside Chromium's own callback stack, where
    /// `runModal` would spin a nested runloop in the middle of it. And the
    /// repeat gate is held across the deferral AND the alert, because until
    /// the user has seen and dismissed it the failure is not yet something
    /// they can act on: a second activation of the same Space arriving in
    /// that span used to open a window beside the alert — and on the
    /// dropped-record branch an EMPTY one, since the record that routes an
    /// activation to a materialization is exactly what has just gone.
    ///
    /// The alert is not conditional on the slot surviving the hop: what it
    /// reports is about the Space and its saved tabs, which outlive this
    /// slot, and the dropped-record branch is precisely where staying silent
    /// would leave the user with no account of where their tabs went.
    ///
    /// Residue, accepted: the gate is released by Space id, so an account
    /// transition that re-keys the pending-spawn claim underneath a modal
    /// (`prepareAccountTransitionPendingWindow`) leaves the destination Space
    /// claimed until a window registers for it. Every asynchronous spawn in
    /// this class releases by id across its own await and carries the same
    /// residue; what is new here is only how long the window stays open,
    /// since a modal is bounded by the user rather than by a profile load.
    private func failMaterialize(_ outcome: SpaceManager.GhostMaterializeFailure,
                                 spaceId: String,
                                 completion: @escaping (Bool) -> Void) {
        completion(false)
        DispatchQueue.main.async { [weak self] in
            SpaceManager.presentGhostMaterializeFailureAlert(outcome)
            self?.pendingSpawnSpaceIds.remove(spaceId)
        }
    }

    /// Spawns an agent Space's Chromium window WITHOUT surfacing or activating
    /// it. Reuses the same spawn primitives as `activate` (the pendingSpawn
    /// gate, `ensureProfileLoaded`, the `currentSpawn` attribution the
    /// coordinator claims, and the immediate quick-lookup-tab seed), but skips the
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
            // The agent drives navigation itself, but seed a quick-lookup tab
            // so the window has a live tab for the runtime to bind to —
            // immediately: session restore can never repopulate this window
            // (agent browsers set omit_from_session_restore, and the bridge
            // suppresses restore around the spawn call itself), so there is no
            // burst to defer past. The old 0.6s defer only delayed the runtime
            // — and its slot-local `windowsBySpaceId` re-check silently skipped
            // the seed whenever the user surfaced the Space from ANOTHER slot
            // inside that window (the adopt path in `activate` evicts the
            // controller over there). Chromium does not activate hidden
            // windows on tab creation (TabsProxy::NewQuickLookupTab), so this
            // cannot front the window either.
            bridge.createQuickLookupTab(withWindowId: windowIdNumber.int64Value,
                                        customGuid: nil)
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

    /// State machine for an animate-first SPAWN switch. Constructed by
    /// `beginSpawnVerticalPushIn` and driven from two independent sides: the
    /// slide's completion (`slideSettled`, also fired by the dropped-completion
    /// fallback) and the spawn's outcome (`spawnCompleted` / `spawnFailed`).
    /// The reveal — fronting the spawned window and hiding the leaving one —
    /// runs once BOTH sides have finished, in either order. `settle()` is the
    /// slot's `verticalSwapCancel` contract: a superseding switch (or the
    /// spawn-deadline fallback) resolves the animation immediately, revealing
    /// only if the spawn has already landed.
    private final class SpawnSwitchAnimation {
        // Wired by `beginSpawnVerticalPushIn`; all run on the main thread.
        var hotSwapBand: (MainBrowserWindowController) -> Void = { _ in }
        var reveal: (MainBrowserWindowController) -> Void = { _ in }
        var restore: () -> Void = {}
        var armSpawnDeadline: () -> Void = {}

        private var slideDone = false
        private var finished = false
        private var target: MainBrowserWindowController?
        private var failed = false

        /// The slide finished (real completion or its fallback).
        func slideSettled() {
            guard !finished else { return }
            slideDone = true
            if let target {
                finished = true
                reveal(target)
            } else if failed {
                finished = true
                restore()
            } else {
                // The slide landed first (cold profile, slow createBrowser):
                // hold the landed state — tint on the target color, band
                // empty — and give the spawn a bounded grace period.
                armSpawnDeadline()
            }
        }

        /// The spawned window registered (hidden and seeded). Returns false
        /// when the animation already resolved — the spawn path then falls
        /// back to an instant present (or stays hidden).
        func spawnCompleted(_ controller: MainBrowserWindowController) -> Bool {
            guard !finished else { return false }
            target = controller
            if slideDone {
                finished = true
                reveal(controller)
            } else {
                hotSwapBand(controller)
            }
            return true
        }

        /// The spawn bailed (profile load / createBrowser failure). Mid-slide
        /// the slide is left to land — `slideSettled` restores then — so the
        /// band doesn't snap back while still moving.
        func spawnFailed() {
            guard !finished else { return }
            failed = true
            if slideDone {
                finished = true
                restore()
            }
        }

        /// Force-settle (supersession by a newer switch, slot teardown, or
        /// the spawn-deadline fallback).
        func settle() {
            guard !finished else { return }
            finished = true
            if let target {
                reveal(target)
            } else {
                restore()
            }
        }
    }

    /// Starts the vertical push-in for the SPAWN path at click time — before
    /// the target window exists. The slide begins against a transparent
    /// entering band (the tint gradient underneath still ramps source →
    /// target, so the motion reads as entering the new Space) and the real
    /// band snapshot is hot-swapped into the moving overlay once the spawned
    /// window registers. Unlike the clicked push-in, the final swap is gated
    /// on the spawn too: the leaving window stays on screen through a slow
    /// spawn instead of giving way to an empty one.
    ///
    /// Returns nil when the animated push-in can't run — horizontal layout,
    /// zero duration, no visible previous window, no leaving band — and the
    /// spawn path then presents the target instantly when it's ready.
    private func beginSpawnVerticalPushIn(
        targetSpaceId spaceId: String,
        previous: MainBrowserWindowController?,
        leavingBand: NSImage?,
        direction: SwapDirection,
        sourceColorHex: String?,
        targetColorHex: String?,
        onActivationFailed: (() -> Void)?,
        onSwapSettled: (() -> Void)?
    ) -> SpawnSwitchAnimation? {
        let duration = Self.swapAnimationDuration
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional,
              duration > 0,
              let previous,
              let previousWindow = previous.window,
              previousWindow.isVisible,
              let leavingImage = leavingBand else { return nil }
        let prevSurface = spaceSwitchSurface(of: previous)
        let bandFrame = prevSurface.spaceSwitchBandFrame
        guard bandFrame.width > 0, bandFrame.height > 0 else { return nil }

        // Same theme choreography as the clicked push-in, except the target
        // theme is resolved from the Space's persisted state — the target
        // window doesn't exist yet. Mirrors what `applyPersistedTheme` sets on
        // the spawned controller at registration, including the Space's
        // color-component adjustment.
        let prevThemeContext = previous.browserState.themeContext
        let sourceTheme = prevThemeContext.currentTheme
        let sourceMirrors = prevThemeContext.mirrorsSharedTheme
        let targetTheme = MainActor.assumeIsolated { () -> Theme in
            manager?.resolvedTheme(forSpaceId: spaceId) ?? ThemeManager.shared.currentTheme
        }

        verticalSwapToken += 1
        let token = verticalSwapToken

        // Hide the live band and slide a transparent stand-in over it; the
        // ramping tint carries the transition until the real band exists.
        prevSurface.setSwitchBandContentHidden(true)
        let overlay = SidebarSwapOverlay(
            frame: bandFrame,
            leavingImage: leavingImage,
            enteringImage: NSImage(size: bandFrame.size),
            direction: direction
        )
        prevSurface.view.addSubview(overlay, positioned: .above, relativeTo: nil)
        activeSidebarOverlay = overlay

        let handle = SpawnSwitchAnimation()

        // Settles the animation state on the LEAVING window; shared by both
        // resolutions below.
        let restoreLeaving: () -> Void = { [weak self, weak prevSurface, weak overlay] in
            overlay?.cancel()
            prevSurface?.setSwitchBandContentHidden(false)
            self?.themeRampTimer?.invalidate()
            self?.themeRampTimer = nil
            prevThemeContext.setTheme(sourceTheme)
            prevThemeContext.mirrorsSharedTheme = sourceMirrors
        }

        handle.hotSwapBand = { [weak self, weak overlay] target in
            // One runloop for the target sidebar's SwiftUI to commit its Space
            // name — the same staging as the clicked push-in — then swap the
            // snapshot into the (still sliding) overlay. Only the content
            // changes; the frame animation carries on untouched.
            DispatchQueue.main.async { [weak self, weak overlay] in
                guard let self, self.verticalSwapToken == token,
                      let overlay else { return }
                let targetSurface = self.spaceSwitchSurface(of: target)
                if let enteringImage = targetSurface.snapshotSpaceSwitchBand() {
                    overlay.updateEnteringImage(enteringImage)
                }
            }
        }

        handle.reveal = { [weak self, weak previousWindow] target in
            guard let self else {
                restoreLeaving()
                return
            }
            // Unlike the clicked push-in's finalize, do NOT rebuild the slot
            // tab group here even if the leaving window entered native
            // fullscreen during the slide (fullscreen slots don't reach this
            // path — `activate` spawns them visible — but the green button
            // can be clicked mid-slide). The target has never been ordered
            // in, and swapping a never-shown window into a fullscreen tab
            // group corrupts NSWindowStackController's fullscreen
            // bookkeeping ("windowToTakeFrom should be in FS" crash). Front
            // it detached instead; `syncSlotTabGroup` regroups it on the
            // next switch once it has been shown.
            self.makeKeyAndOrderFrontHidingSlotTabBar(target.window)
            self.orderOutIfNotTabbedWithTarget(previousWindow, targetWindow: target.window)
            restoreLeaving()
            self.verticalSwapCancel = nil
            onSwapSettled?()
        }

        handle.restore = { [weak self] in
            restoreLeaving()
            self?.verticalSwapCancel = nil
            onActivationFailed?()
        }

        handle.armSpawnDeadline = { [weak self, weak handle] in
            // The slide landed but the spawn is still in flight. Hold the
            // landed state a bounded while longer; if the spawn still hasn't
            // resolved by then, settle back so the sidebar isn't stranded
            // bandless (the late spawn's instant-present fallback still
            // surfaces the window if this Space stays active).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak handle] in
                guard let self, self.verticalSwapToken == token else { return }
                handle?.settle()
            }
        }

        // Arm the slot-level supersession hook. This strong capture is also
        // what keeps `handle` alive until one of the resolutions clears
        // `verticalSwapCancel`.
        verticalSwapCancel = { handle.settle() }
        scheduleVerticalSwapFinalizeFallback(token: token, duration: duration) { [weak handle] in
            handle?.slideSettled()
        }

        // Ramp + slide, starting this very turn: with a placeholder entering
        // band there is nothing to wait a runloop for.
        rampWindowTheme(prevThemeContext, from: sourceTheme, to: targetTheme, duration: duration)
        prevSurface.rampSpaceTint(fromHex: sourceColorHex, toHex: targetColorHex, duration: duration)
        overlay.runAnimation(duration: duration) { [weak handle] in
            handle?.slideSettled()
        }
        return handle
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
        let finalize: () -> Void = { [weak self, weak leavingView] in
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
        windowSlideCancel = finalize

        // Drive the slide manually. CALayer's implicit animation is
        // disabled per tick (CATransaction setDisableActions) so the
        // duration is exactly the user-tunable preference rather than
        // the layer's default 0.25s.
        if duration <= 0 {
            finalize()
            return
        }

        let startTime = CACurrentMediaTime()
        let easeInOut: (CGFloat) -> CGFloat = { t in
            t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }

        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak leavingView] t in
            guard let leavingView else {
                t.invalidate()
                finalize()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            let progress = CGFloat(min(1.0, elapsed / duration))
            let eased = easeInOut(progress)
            setEnteringTransform(mainStartDx * (1 - eased))
            leavingView.frame = contentBounds.offsetBy(dx: leavingEndDx * eased, dy: 0)
            if progress >= 1.0 {
                finalize()
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
    /// True from the moment `applyPendingRestoreFullScreen` schedules the
    /// deferred `toggleFullScreen` until that toggle has been issued.
    /// `pendingRestoreFullScreen` is consumed at scheduling, but the slot's
    /// windows only start reporting `.fullScreen` once the toggle fires — a
    /// restore reconcile pass landing in that gap must still treat the slot
    /// as sharing a fullscreen Space, or it would hard-orderOut (and thereby
    /// detach) the siblings the previous pass just grouped for the re-entry.
    private var fullScreenReentryInFlight = false

    private func applyPendingRestoreFullScreen(activeWindow: NSWindow) {
        guard pendingRestoreFullScreen, activeWindow.isVisible else { return }
        pendingRestoreFullScreen = false
        guard !activeWindow.styleMask.contains(.fullScreen) else { return }
        fullScreenReentryInFlight = true
        // Defer one runloop turn so the just-surfaced window has settled before
        // the fullscreen transition begins; re-check the state at fire time.
        DispatchQueue.main.async { [weak self, weak activeWindow] in
            defer { self?.fullScreenReentryInFlight = false }
            guard let activeWindow,
                  !activeWindow.styleMask.contains(.fullScreen) else { return }
            activeWindow.toggleFullScreen(nil)
        }
    }

    private func makeKeyAndOrderFrontHidingSlotTabBar(_ window: NSWindow?) {
        guard let window else { return }

        // Every explicit fronting un-conceals: covers a mid-restore
        // pip-switch to a Space whose window is still alpha-concealed.
        revealConcealedWindow(window)

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
        if !slotHasFullScreenWindow && !pendingRestoreFullScreen && !fullScreenReentryInFlight {
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
    /// workspace), or while a window-driven cascade drains the slot (nothing to
    /// re-assert, and the display adoption keeps `activeSpaceId` on a live window,
    /// so the bail below no longer covers it). A miniaturized active window still
    /// gets its surfaced siblings hidden, but is not brought back on screen.
    /// Keyed on `activeSpaceId` — the slot's source of truth — not
    /// `visibleController`, which rapid switching can leave transiently stale.
    private func enforceSlotSingleWindowInvariant() {
        guard !isSwitchAnimationInFlight, !slotHasFullScreenWindow, !isCascadingSlotClose else { return }
        guard let activeId = activeSpaceId,
              let activeController = windowsBySpaceId[activeId],
              let activeWindow = activeController.window else { return }

        var hidCount = 0
        for (spaceId, controller) in windowsBySpaceId where spaceId != activeId {
            guard let window = controller.window, window.isVisible else { continue }
            orderOutRearmingMoveToActiveSpace(window)
            hidCount += 1
        }
        // A miniaturized active window is a valid zero-visible-window state for
        // the slot. Keep sweeping surfaced siblings, but do not re-front the
        // active window and undo the user's minimize action.
        if !activeWindow.isMiniaturized && (hidCount > 0 || !activeWindow.isVisible) {
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

    /// Space ids whose next `registerWindow` belongs to a restored
    /// sibling-Space window that must stay invisible for the whole restore
    /// burst. Marked by `PhiChromiumCoordinator.mainBrowserWindowCreated`
    /// BEFORE the controller init (registration runs inside that init, so a
    /// post-init conceal would lose the race against the registration-time
    /// tab-group enrollment below); consumed by `registerWindow`.
    private var pendingRestoreConcealSpaceIds: Set<String> = []

    /// Marks the restored window that is about to register for `spaceId` as
    /// a concealed sibling: `registerWindow` then skips the slot tab-group
    /// enrollment for it and conceals the window before Chromium's
    /// post-construction Show() can surface it.
    ///
    /// Why concealment must include staying OUT of the native tab group:
    /// grouped windows share one frame, and AppKit's automatic tabbing makes
    /// the last-shown window the group's selected tab — a transparent
    /// selected tab renders the whole shared frame transparent (the visible
    /// active window "disappears" behind it until the reconcile pops the
    /// siblings out). As an ungrouped window it surfaces alone — transparent
    /// and inert — while the active window's frame stays untouched. The next
    /// `syncSlotTabGroup` regroups it once it is genuinely surfaced — the
    /// same regroup-on-resurface contract hidden siblings already follow
    /// after a hard orderOut (see `deferGroupingForReveal` in
    /// `registerWindow`).
    func markRestoredSiblingForConcealment(spaceId: String) {
        pendingRestoreConcealSpaceIds.insert(spaceId)
    }

    /// Which arriving window the coordinator marks: a window that came back
    /// through Chromium's session restore and is NOT the Space its slot is
    /// landing on. Every other window surfaces normally.
    ///
    /// `isRestoredWindow` is the load-bearing half, and the reason this is a
    /// rule rather than one more condition inline: a materialized ghost
    /// arrives through the pending-spawn claim, not the restore claim, and
    /// its slot is very often still showing the Space the user is switching
    /// AWAY from — so a predicate that only compared Spaces would conceal the
    /// window the user just asked for, and lose it (the restore-burst reveal
    /// that undoes concealment never runs for it).
    ///
    /// A slot with no landing Space still conceals: nil is the state of a
    /// slot whose entry named no active Space, and a restored sibling has no
    /// claim to be the one on screen just because nothing else has claimed it
    /// yet — the reconcile picks the visible window once the burst settles.
    ///
    /// Whether the window has a slot at all stays at the call site: an
    /// unslotted window (Incognito, shadow) is outside the whole question,
    /// not an answer of "do not conceal". Pure and static so the rule is
    /// pinned by table: it is one of the places a Chromium rebase is most
    /// likely to shift underneath this feature, and drift here shows up as a
    /// materialized window that is simply never visible.
    static func concealsRestoredSibling(isRestoredWindow: Bool,
                                        slotActiveSpaceId: String?,
                                        windowSpaceId: String) -> Bool {
        isRestoredWindow && slotActiveSpaceId != windowSpaceId
    }

    /// Applies the conceal to a just-registered restored sibling: invisible
    /// (alpha survives every ordering call Chromium makes, unlike orderOut),
    /// inert to clicks, and barred from automatic tab-group enrollment while
    /// concealed. Reversed idempotently by `revealConcealedWindow` from
    /// every settle path; `syncSlotTabGroup` restores the preferred tabbing
    /// mode when the window is regrouped. Mirrors the dangling-window alpha
    /// conceal/restore pair in
    /// `MainBrowserWindowControllersManager.hideDanglingWindow`.
    ///
    /// Chromium is told too: alpha concealment is invisible to it, so it
    /// would otherwise start a page load for this window's selected restored
    /// tab — once per concealed Space, competing with the visible window for
    /// the main thread. This runs inside Chromium's window-created callback,
    /// ahead of the tab replay, so the mark is in place when it decides.
    private func concealRestoredSiblingWindow(_ window: NSWindow, windowId: Int) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.tabbingMode = .disallowed
        Self.setRestoredSiblingConcealedIfSupported(true, windowId: Int64(windowId))
    }

    /// The framework half of the bridge pair can lag this header during
    /// development (it only re-syncs on a Chromium rebuild), and a hard call
    /// into a framework that predates this selector raises
    /// `doesNotRecognizeSelector` and takes the app down. Skipping is safe:
    /// an old framework never marks a window, and both directions are
    /// documented no-ops for unmarked windows — concealed restores just load
    /// eagerly, the pre-feature behavior.
    private static func setRestoredSiblingConcealedIfSupported(_ concealed: Bool, windowId: Int64) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setRestoredSiblingConcealed(_:windowId:)))
        else { return }
        bridge.setRestoredSiblingConcealed(concealed, windowId: windowId)
    }

    /// Idempotent undo of `concealRestoredSiblingWindow`; safe on windows
    /// that were never concealed. Dropping the Chromium mark starts the page
    /// load that was skipped while concealed, so a Space that surfaces is
    /// never a blank page. Dropped on every call rather than only on an alpha
    /// transition — Chromium ignores the drop for a window it never marked,
    /// while gating on the alpha would strand a window some other path had
    /// already made opaque.
    ///
    /// The window carries no Chromium id, so the slot has to recover its
    /// controller; every caller passes a window this slot owns, which makes a
    /// miss a bug rather than a state to tolerate — hence the log.
    private func revealConcealedWindow(_ window: NSWindow) {
        if window.alphaValue != 1 { window.alphaValue = 1 }
        if window.ignoresMouseEvents { window.ignoresMouseEvents = false }
        guard let controller = windowsBySpaceId.values.first(where: { $0.window === window })
        else {
            AppLogWarn("[SpaceWindowSlot] revealConcealedWindow: window is not registered with this slot — Chromium keeps its restored-sibling mark")
            return
        }
        Self.setRestoredSiblingConcealedIfSupported(false, windowId: Int64(controller.windowId))
    }

    /// Catch-all for the reconcile's final pass: no restored window may stay
    /// transparent past the restore burst, even when the reconcile bailed on
    /// every pass (e.g. the active Space's window never arrived).
    private func revealAllConcealedWindows() {
        for controller in windowsBySpaceId.values {
            guard let window = controller.window else { continue }
            revealConcealedWindow(window)
        }
    }

    /// Fronts the restore's target window the moment its own content is fully
    /// applied, instead of after the whole multi-profile burst settles. Called
    /// by `PhiChromiumCoordinator` right after a restored window's snapshot
    /// transaction lands. Only the app-level last-active Space's window
    /// qualifies — the exact window the settle reconcile would front anyway —
    /// so this merely moves that reveal earlier: siblings stay concealed until
    /// the reconcile, which still runs unchanged afterwards (idempotent
    /// re-front, sibling sweep, fullscreen re-entry). Gated to the restore
    /// burst via `restoreVisibilityReconcileScheduled`, whose becomeKey
    /// suppression also keeps this early key change out of the active-Space
    /// bookkeeping; a genuine mid-restore user switch flips `activeSpaceId`
    /// away and disarms this. An apply landing after the burst window (the
    /// flag self-clears on the reconcile's final pass) simply falls back to
    /// the settle reveal — later, never wrong.
    func frontRestoredWindowOnSnapshotApplied(_ controller: MainBrowserWindowController) {
        guard restoreVisibilityReconcileScheduled,
              controller.spaceId == activeSpaceId,
              controller.spaceId == manager?.persistedActiveSpaceId,
              windowsBySpaceId[controller.spaceId] === controller,
              let window = controller.window else { return }
        makeKeyAndOrderFrontHidingSlotTabBar(window)
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
    /// True while the slot's active Space was last changed by a window key
    /// event (`handleWindowDidBecomeKey` adoption) rather than an explicit
    /// `activate`. The window-driven cascade uses this to tell a close-driven
    /// key promotion (AppKit re-keys a fullscreen sibling before the closing
    /// window's willClose, and the adoption pollutes the active-Space
    /// bookkeeping — must be undone) from a deliberate user switch made
    /// before closing the group (must be preserved): at cascade time both
    /// look identical (`activeSpaceId != closing spaceId`), only the source
    /// of the last change distinguishes them. Cleared by `activate`.
    private var activeSpaceAdoptedFromKeyEvent = false

    fileprivate var restoreVisibilityReconcileScheduled = false
    func scheduleRestoreVisibilityReconcile() {
        guard !restoreVisibilityReconcileScheduled else { return }
        restoreVisibilityReconcileScheduled = true
        for delay in [0.0, 0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if delay == 3.0 { self.restoreVisibilityReconcileScheduled = false }
                self.reconcileRestoreVisibility()
                // Final pass: whatever the reconcile did (or bailed on), no
                // window may stay alpha-concealed past the restore burst.
                if delay == 3.0 { self.revealAllConcealedWindows() }
            }
        }
    }

    private func reconcileRestoreVisibility() {
        // Nothing to re-assert while a window-driven cascade drains the slot; the
        // display adoption keeps `activeSpaceId` on a live window, so the bail
        // below no longer covers it. `revealAllConcealedWindows` runs outside
        // this pass, so no sibling stays concealed.
        guard !isCascadingSlotClose else { return }
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
        let inSharedFullScreen = slotHasFullScreenWindow || fullScreenReentryInFlight
        // A slot about to re-enter fullscreen must NOT hard-orderOut its
        // siblings: that detaches them from the native tab group, and the
        // first Space switch after the re-entry then has to re-attach and
        // key a window whose adoption into the fullscreen Space the window
        // server is still processing — which kicks macOS off the fullscreen
        // desktop entirely (the reopen-and-switch bug; deferring the key one
        // turn was measured insufficient). Group the whole slot behind the
        // active window BEFORE the fullscreen toggle instead: the tab group
        // enters the fullscreen Space as one unit, so the first switch
        // selects an already-settled member — the same shape as every later
        // switch, which never yanks. Siblings stay stacked behind the
        // selected active tab, the state the fullscreen branch below already
        // trusts on every later pass.
        if pendingRestoreFullScreen {
            syncSlotTabGroup(selecting: activeWindow)
            for controller in windowsBySpaceId.values {
                guard let window = controller.window else { continue }
                revealConcealedWindow(window)
            }
            visibleController = activeController
            makeKeyAndOrderFrontHidingSlotTabBar(activeWindow)
            updateWindowsMenuExclusion()
            applyPendingRestoreFullScreen(activeWindow: activeWindow)
            return
        }
        var hidCount = 0
        for (siblingSpaceId, controller) in windowsBySpaceId where siblingSpaceId != activeId {
            guard let window = controller.window, window.isVisible else { continue }
            if inSharedFullScreen, windowsShareTabGroup(window, activeWindow) {
                // Left stacked behind the active tab — safe to un-conceal
                // (its z-order keeps it out of sight).
                revealConcealedWindow(window)
                continue
            }
            orderOutRearmingMoveToActiveSpace(window)
            // Off screen now; restore visibility properties so the next
            // pip-switch surfaces a fully opaque, interactive window.
            revealConcealedWindow(window)
            hidCount += 1
        }
        visibleController = activeController
        // The active window is never concealed on the claim path, but reveal
        // defensively before fronting it.
        revealConcealedWindow(activeWindow)
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
        // Chromium records its "recently closed" stack inside its own close
        // handshake, before AppKit reports the close, so it needs this pairing
        // up front to stamp the Space into the restore entry — that is what
        // lets a reopened window return to this Space instead of whichever one
        // is active. A window's Space never changes, so publishing once here is
        // enough; Chromium drops the entry with the window's Browser.
        ChromiumLauncher.sharedInstance().bridge?.setWindowSpace(
            spaceId, forWindowId: Int64(controller.windowId))
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
            // session-restored windows back to their original Space. A reopen
            // replaying a saved group refuses here on every one of its windows
            // and writes once from its own completion instead — see
            // `SpaceManager.mayPersistSlotsSnapshot`.
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
        // A spawn's own queued frame wins; `reopenPlacementFrame` is the
        // fallback for a window this side never spawned — a restored one, which
        // arrives carrying Chromium's replayed bounds. Applied here because
        // registration runs inside Chromium's window-created callback, after
        // the NSWindow has its bounds and before the post-construction Show()
        // that puts it on screen: the frame the user first sees is this one.
        if let frame = pendingFrameByWindowId.removeValue(forKey: controller.windowId)
            ?? reopenPlacementFrame,
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
        // An animate-first spawn registers its window HIDDEN mid-slide
        // (`activate`'s spawn path created it with `hidden: true` while the
        // push-in it started is still running — that in-flight animation is
        // exactly what `verticalSwapCancel` being armed means here, since
        // clicked swaps never register windows). Keep that window OUT of the
        // slot's native tab group entirely: `addTabbedWindow` on a window
        // that has never been ordered in leaves NSWindowStackController's
        // synced tab-bar items one short of the group, and the next
        // `orderOut` of ANY group member (the post-switch sweep hiding the
        // leaving window) then throws NSRangeException in
        // `_removeSyncedTabBarItem:` — an app-killing crash. The reveal
        // fronts it as an ungrouped window (`makeKeyAndOrderFront` plain
        // path), and the next `syncSlotTabGroup` regroups it once it has
        // been shown — the same regroup-on-resurface contract hidden
        // siblings already follow after a hard orderOut detaches them.
        let deferGroupingForReveal = verticalSwapCancel != nil
            && controller.window?.isVisible != true
        // Restored sibling marked for concealment: conceal NOW (before
        // Chromium's post-construction Show()) and keep it out of the slot
        // tab group for the same span — a transparent window selected into
        // the shared group frame would render the whole group invisible.
        // See `markRestoredSiblingForConcealment`.
        let concealAsRestoredSibling = pendingRestoreConcealSpaceIds.remove(spaceId) != nil
        if let window = controller.window, concealAsRestoredSibling {
            concealRestoredSiblingWindow(window, windowId: controller.windowId)
        }
        // This slot now has a window the user will see, so the loading window
        // standing in for it drops behind that window rather than being taken
        // away. Nothing here can tell when the restored window paints — it is
        // ordered in well before its first frame reaches the screen, and every
        // available signal fires inside that gap — so a loading window removed
        // on any of them uncovers the desktop for as long as the gap lasts.
        // Underneath it, the loading window is hidden the instant there is
        // anything to hide it with, and closing it afterwards is invisible
        // whenever it happens (`ReopenLoadingHandoff`).
        //
        // Both steps run HERE, synchronously, before the post-construction
        // Show() later in this same turn. The shadow, so that no composited
        // frame ever has both windows casting one onto the same ring of
        // desktop. The ordering, because `pinUnder` declares a lasting
        // relationship and so needs no window on screen to point at (see it for
        // why the one-shot form could not run here). Note what this does and
        // does not buy: it removes the ordering hazard, and it is NOT what
        // makes the chrome late on about half of reopens — see
        // `ReopenLoadingWindow.featureEnabledKey` for that, which is a separate
        // and larger unsolved cost.
        //
        // Two windows are excluded, for different reasons. A concealed sibling
        // registers at alpha 0 and is not a window the user sees, so it neither
        // takes the loading window nor counts towards the deadline. And a
        // window that is not becoming the slot's visible one must not take it
        // either: re-parenting is silent, so an unrelated spawn registering
        // here mid-hand-off (a hidden agent-Space window, say) would otherwise
        // adopt the loading window and then drag it off screen with itself.
        //
        // `syncSlotTabGroup` may put this same window into a tab group on the
        // next statement, which is the NSRangeException area noted above. The
        // combination was tried: a loading window stays out of the group
        // (`tabbingMode` never opts it in), and grouping, selecting another tab
        // and ordering a grouped sibling out all leave it attached and visible.
        if !concealAsRestoredSibling, shouldBecomeVisible,
           let loading = reopenLoadingWindow,
           let window = controller.window {
            loading.yieldShadow()
            loading.pinUnder(window)
            manager?.noteReopenLoadingHandoffWindowRegistered()
            AppLogInfo("[SpaceManager] reopen: loading window put under the restored one")
        }
        if !deferGroupingForReveal && !concealAsRestoredSibling {
            syncSlotTabGroup(selecting: shouldBecomeVisible ? controller.window : visibleController?.window)
        }
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
    /// the result of closing the window itself. Called from
    /// `Tab.close()` — the tab-row ✕ button and every other UI path
    /// that funnels into it — right before dispatching the
    /// IDC_CLOSE_TAB command, when the active Space's tab count is
    /// about to drop to zero. ⌘W (`CommandDispatcher` IDC_CLOSE_TAB)
    /// deliberately does NOT call this: closing the last tab with ⌘W
    /// tears the whole slot down like ⇧⌘W instead of switching to a
    /// sibling Space. Incognito Spaces never get here on a last-tab
    /// close — both paths intercept it and route into the confirmed
    /// Space teardown (`SpaceManager.requestCloseIncognitoSpace`).
    ///
    /// The predicted auto-close does not actually happen any more:
    /// the window enters placeholder mode instead, and
    /// `cancelTabDrivenClose` drops the marker and the composite
    /// captured below. Both are kept because the vetoed-close residual
    /// documented on `pendingTabDrivenCloseDeadlines` still consumes
    /// them.
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

    /// Cancels what `markTabDrivenClose` armed for `spaceId`, marker and
    /// pre-captured composite together. Called when Chromium reports the
    /// window entered placeholder mode: the last-tab close left the window
    /// standing, so the auto-close the marker predicts never happens. Left
    /// armed it would live out its TTL and misclassify the user's next
    /// genuine close of this window as a tab-driven hand-off, switching the
    /// slot to a sibling Space instead of closing it. Idempotent — every
    /// placeholder entry runs it, most with nothing to cancel.
    func cancelTabDrivenClose(for spaceId: String) {
        pendingTabDrivenCloseDeadlines.removeValue(forKey: spaceId)
        pendingTabDrivenCloseSnapshots.removeValue(forKey: spaceId)
    }

    /// Drops the controller for `spaceId`. Behavior splits on whether the
    /// close was tab-driven or window-driven:
    ///
    /// - Tab-driven (the user just closed the last tab in the visible Space)
    ///   AND another Space in the slot still has tabs: activate that
    ///   sibling. The user-perceived window stays alive showing the
    ///   sibling Space's content. **Currently unreachable from any user
    ///   gesture**: a last-tab close now leaves the window standing on the
    ///   placeholder page, and that entry cancels the marker
    ///   (`cancelTabDrivenClose`), so no close arrives here still tagged.
    ///   The branch survives for the one residual that can still leave a
    ///   live marker behind — an `IDC_CLOSE_TAB` vetoed by an
    ///   `onbeforeunload` prompt, after which a genuine window close inside
    ///   the TTL still lands here (a known defect, see
    ///   `pendingTabDrivenCloseDeadlines`).
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
        // Land a debounced frame write while the slot is still whole. This is
        // the last moment it can be written truthfully: the map is drained on
        // the next line, the cascade below freezes persistence outright, and
        // the write `removeSlot` does on the way out no-ops for the last slot —
        // which is precisely the one a reopen restores from. A drag in the
        // second before the user hit the red X would otherwise be lost, and the
        // snapshot would keep an older position for good.
        // Mid-cascade this reduces to nothing: `persistSlotsSnapshot` refuses
        // to write while any slot is tearing down (and in the other states
        // `mayPersistSlotsSnapshot` names), so the flush cannot smuggle a
        // half-drained group into the snapshot. A refused flush keeps the
        // change pending rather than dropping it.
        manager?.flushPendingSlotsSnapshotPersist()
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
                guard let self else { return }
                // Never mid-cascade. The slot's window map is half-drained
                // there, so the reconcile reads "no fullscreen window left",
                // flips the flag, and persists a snapshot of a window group
                // that is already half gone — the group the next launch is
                // supposed to restore. The teardown settles the state either
                // way: it ends in `removeSlot` (which persists the surviving
                // slots) or, if vetoed, in `recoverFromVetoedCascade` (which
                // reconciles against the survivors).
                guard !self.isCascadingSlotClose else { return }
                self.reconcileFullScreenWithWindowState()
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
            // the sibling instead of tearing the slot down. Currently
            // unreachable from a user gesture — see the branch note in
            // this method's doc comment.
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
                // In a fullscreen tab group AppKit promotes a sibling to key
                // synchronously with the closing window's teardown, BEFORE
                // this willClose runs, so no key guard can suppress that
                // event: the adoption has already overwritten
                // `activeSpaceId`, the persisted last-active Space, and the
                // snapshot entry's active Space. Undo all three — but ONLY
                // when the change actually came from a key adoption. A
                // deliberate `activate` before closing the group leaves the
                // same `activeSpaceId != spaceId` state (the fullscreen
                // cascade can start on a background tab AppKit still reports
                // as selected), and that switch is the user's real intent —
                // it must survive the close.
                if activeSpaceId != spaceId, activeSpaceAdoptedFromKeyEvent {
                    activeSpaceAdoptedFromKeyEvent = false
                    activeSpaceId = spaceId
                    manager?.persistActiveSpaceId(spaceId)
                    manager?.amendPersistedSnapshotActiveSpaceId(
                        windowId: controller.windowId, to: spaceId)
                }
                isCascadingSlotClose = true
                cascadeCloseRemainingWindows()
                scheduleCascadeVetoRecovery()
                // In fullscreen a sibling can already hold key (the promotion the
                // undo above exists for), and AppKit posts no further key event
                // for a window that is already key — so follow it from here.
                if let keyed = windowsBySpaceId.first(where: { $0.value.window?.isKeyWindow == true }) {
                    adoptSpaceForDisplayDuringCascade(keyed.key)
                }
            }
        }
        if windowsBySpaceId.isEmpty {
            // Nothing left here to cover a reopen loading window, and the slot
            // is about to leave `restoredSlotsByIndex` below — so a user quick
            // enough to close the restored window before the hand-off deadline
            // would otherwise be left looking at a loading window with bare
            // desktop behind it. Gated on the slot emptying rather than on any
            // window leaving: a concealed sibling being retired mid-restore
            // must NOT take the loading window away from the window it is still
            // covering for.
            closeReopenLoadingWindow()
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

    /// Poll interval for a window-driven cascade's veto check. Each
    /// `IDC_CLOSE_WINDOW` roundtrip (Chromium close → browser teardown →
    /// `windowWillClose` → `unregisterWindow`) is well under 100ms, so a
    /// genuine cascade — even of several siblings — empties the slot far
    /// inside one interval; the value matches the `tabDrivenCloseTTL` sizing
    /// of that roundtrip. A deadline alone proves nothing about the windows
    /// still standing, though: a `beforeunload` prompt stays up for as long
    /// as the user cares to read it, so each deadline polls their close
    /// state through the bridge instead of assuming a veto (see
    /// `scheduleCascadeVetoRecovery`).
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
    /// the deadline, poll every survivor's close state over the bridge: only
    /// when all of them report `.notAttempting` (alive with the beforeunload
    /// flag cleared — the user kept that window) is the cascade vetoed and a
    /// survivor re-adopted. Any `.attemptingClose` (prompt up, or unwinding
    /// after "leave") or `.gone` (mid-teardown; it drops from the map on its
    /// own) re-arms the timer — with no cap, because the only unbounded state
    /// is a prompt nobody has answered yet, and a recovery fired mid-gesture
    /// is exactly the false veto this poll exists to prevent: it reports the
    /// group close settled while siblings are still deciding, committing the
    /// already-closed windows as plain closes.
    private func scheduleCascadeVetoRecovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cascadeVetoRecoveryDelay) { [weak self] in
            guard let self, self.isCascadingSlotClose,
                  !self.windowsBySpaceId.isEmpty else { return }
            var attempting = 0
            var gone = 0
            var kept = 0
            if let bridge = ChromiumLauncher.sharedInstance().bridge {
                for controller in self.windowsBySpaceId.values {
                    switch bridge.windowCloseState(forWindowId: Int64(controller.windowId)) {
                    case .attemptingClose: attempting += 1
                    case .gone: gone += 1
                    case .notAttempting: kept += 1
                    @unknown default: attempting += 1
                    }
                }
            } else {
                // No bridge to interrogate — read as not-yet-terminal. Waiting
                // is always safe; recovering on a guess is the bug this poll
                // exists to prevent.
                attempting = self.windowsBySpaceId.count
            }
            guard attempting == 0, gone == 0 else {
                AppLogInfo("[SpaceWindowSlot] cascade close still in flight; re-polling (survivors=\(self.windowsBySpaceId.count) attempting=\(attempting) gone=\(gone) kept=\(kept))")
                self.scheduleCascadeVetoRecovery()
                return
            }
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
        // `unregisterWindow`'s deferred reconcile skipped itself while the
        // cascade was armed, so a fullscreen slot whose teardown was vetoed
        // still carries the closed window's flag. Re-derive it from the
        // survivors before the snapshot below records it.
        reconcileFullScreenWithWindowState()
        // The frame observer refused every frame change while the cascade was
        // armed, so the slot's shared frame can be stale by now — a fullscreen
        // exit that landed mid-cascade is the concrete case. Re-seed it from the
        // window the user is actually left looking at. Skipped while the slot is
        // still fullscreen (the reconcile above has just refreshed that): the
        // survivor's frame is the screen rect there, and recording it would
        // discard the windowed frame every later switch and spawn inherits.
        if !slotHasFullScreenWindow {
            _ = resolveInheritedFrame(from: survivor.value)
        }
        manager?.persistActiveSpaceId(survivor.key)
        manager?.persistSlotsSnapshot()
        manager?.notifySlotBecameKey(self)
        // Windows survived the gesture, so the closes Chromium deferred are
        // plain window closes after all — let it commit them.
        manager?.reportWindowGroupCloseSettled()
        // A multi-veto (several dirty Spaces kept) can leave more than one
        // window on screen; collapse the rest behind the adopted one over the
        // standard sweep ladder.
        scheduleNonTargetSlotWindowSweep()
    }

    /// Lets the slot's DISPLAY follow the window on screen during a window-driven
    /// cascade, without touching the persisted state that
    /// `handleWindowDidBecomeKey`'s cascade guard protects.
    ///
    /// That guard drops mid-cascade key changes as teardown churn — but
    /// `IDC_CLOSE_WINDOW` honors `beforeunload`, so a background Space's prompt
    /// keeps its window on screen for as long as the user takes to answer, while
    /// `activeSpaceId` stays frozen on the Space whose window already closed
    /// (measured: 6.3s of wrong icon, since `recoverFromVetoedCascade` unfreezes
    /// it only after the answer).
    ///
    /// Writes the display-facing pair only. Persistence must keep the closing
    /// group's own active Space (see the undo in `unregisterWindow`) so a "Leave"
    /// still reopens on it; `recoverFromVetoedCascade` persists the settled state.
    private func adoptSpaceForDisplayDuringCascade(_ spaceId: String) {
        // `isVisible` is not enough: `concealRestoredSiblingWindow` hides restore
        // siblings by zeroing alpha only, and Chromium keys them as their tabs
        // load — a cascade can arm inside that burst. Every other off-screen path
        // orders the window out, which `isVisible` already catches.
        guard isCascadingSlotClose,
              let controller = windowsBySpaceId[spaceId],
              let window = controller.window,
              window.isVisible, window.alphaValue > 0 else { return }
        if activeSpaceId == spaceId, visibleController === controller { return }
        AppLogInfo("[SpaceWindowSlot] cascade close in flight; following on-screen Space \(spaceId) for display")
        activeSpaceId = spaceId
        visibleController = controller
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

    /// Prepares one in-place Native controller replacement while Guest data
    /// is promoted into an account whose migration may have remapped the
    /// Space identifier.
    ///
    /// The old controller is removed from the registry without any close,
    /// sibling handoff, or spawn. The replacement is expected to register
    /// synchronously after this returns, using `destinationSpaceId`.
    @discardableResult
    func prepareAccountTransitionWindowReplacement(
        _ controller: MainBrowserWindowController,
        from sourceSpaceId: String,
        to destinationSpaceId: String
    ) -> Bool {
        guard windowsBySpaceId[sourceSpaceId] === controller else {
            return false
        }

        _ = evictWindow(for: sourceSpaceId, removeSlotIfEmpty: false)
        if activeSpaceId == sourceSpaceId || visibleController === controller {
            activeSpaceId = destinationSpaceId
        }
        manager?.pushSpaceStateToChromium()
        manager?.persistSlotsSnapshot()
        return true
    }

    /// Remaps an empty slot captured while browser access was fenced.
    ///
    /// Crash recovery owns a Chromium window before its Native controller can
    /// be constructed. Apply the receipt's Space mapping to the slot and any
    /// still-pending spawn bookkeeping first, so registering the target-bound
    /// controller never publishes the retired Guest identifier.
    func prepareAccountTransitionPendingWindow(
        from sourceSpaceId: String,
        to destinationSpaceId: String
    ) {
        guard sourceSpaceId != destinationSpaceId else { return }

        if activeSpaceId == sourceSpaceId {
            activeSpaceId = destinationSpaceId
        }
        if lastRegularSpaceId == sourceSpaceId {
            lastRegularSpaceId = destinationSpaceId
        }
        if pendingSpawnSpaceIds.remove(sourceSpaceId) != nil {
            pendingSpawnSpaceIds.insert(destinationSpaceId)
        }
        let pendingWindowIds = pendingSpawnSpaceIdByWindowId.compactMap {
            windowId, spaceId in
            spaceId == sourceSpaceId ? windowId : nil
        }
        for windowId in pendingWindowIds {
            pendingSpawnSpaceIdByWindowId[windowId] = destinationSpaceId
        }
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
    ///
    /// Only the tab-driven hand-off consults this, so it is currently
    /// unreachable outside the residual documented on `unregisterWindow`.
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

    /// The Spaces this slot currently hosts a window for. Read by
    /// `SpaceManager.repairSlotsWithAbsentActiveSpace` to tell a slot whose
    /// active Space came back from one whose did not, and to pick a stand-in
    /// among the Spaces that did.
    var spaceIdsWithWindow: Set<String> {
        Set(windowsBySpaceId.keys)
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

    /// Where this slot should reopen, for the cross-launch restore record. Read
    /// by `SpaceManager.persistSlotsSnapshot`.
    ///
    /// Prefers the visible window's live frame and refreshes the cache from it
    /// — the same read-live-then-fall-back shape as `resolveInheritedFrame`, so
    /// a persist triggered while the window is mid-teardown still answers with
    /// the last position the window actually held. A fullscreen slot answers
    /// with its pre-fullscreen geometry: the live frame is the screen rect
    /// there, which `lastKnownWindowedFrame` deliberately never adopts.
    fileprivate func snapshotFrame() -> NSRect? {
        if let frame = visibleController?.window?.frame,
           !frame.isEmpty,
           !NSScreen.screens.contains(where: { $0.frame.equalTo(frame) }) {
            lastKnownWindowedFrame = frame
        }
        return lastKnownWindowedFrame
    }

    /// How wide this slot's sidebar is, for the cross-launch restore record.
    /// Read by `SpaceManager.persistSlotsSnapshot`, and by nothing else — the
    /// live value is `BrowserState.sidebarWidth`.
    ///
    /// Same read-live-then-fall-back shape as `snapshotFrame`, and for the same
    /// reason: a persist can be triggered while the window is mid-teardown, and
    /// the last width the slot actually had is a better answer than none.
    ///
    /// Zero is a real answer, not a missing one: it is what a collapsed sidebar
    /// reports (`MainSplitViewController.updateSidebarWidth`), and what
    /// `.comfortable` reports permanently. But it is ALSO what a window that
    /// has not laid out yet reports — `BrowserState.sidebarWidth` starts at 0
    /// and only `MainSplitViewController.viewWillAppear` wires the updates —
    /// and `registerWindow` persists from inside the controller's own
    /// initializer, before the window has ever been shown. The collapsed flag
    /// is what tells the two apart, so a zero is adopted only when the window
    /// says the sidebar really is collapsed. Left alone otherwise, which for a
    /// brand-new slot means "no remembered width" and therefore no band, until
    /// `observeSidebarWidth` sees the real value arrive.
    fileprivate func snapshotSidebarWidth() -> CGFloat? {
        if let state = visibleController?.browserState,
           state.sidebarWidth > 0 || state.sidebarCollapsed {
            lastKnownSidebarWidth = state.sidebarWidth
        }
        return lastKnownSidebarWidth
    }

    /// Where this slot's window has its leading traffic light, as a distance
    /// from the top-left of its frame, for the cross-launch restore record.
    /// Read by `SpaceManager.persistSlotsSnapshot`.
    ///
    /// Skipped while the slot is fullscreen, the same exclusion
    /// `lastKnownWindowedFrame` makes: AppKit lays a fullscreen titlebar out
    /// differently, and the loading window is only ever placed for a slot that
    /// was NOT fullscreen. Caching it means a slot that has been fullscreen
    /// since launch still answers with the windowed origin it had before.
    fileprivate func snapshotTrafficLightOrigin() -> NSPoint? {
        if !isFullScreen,
           let window = visibleController?.window,
           let origin = ReopenLoadingWindow.measuredTrafficLightOrigin(in: window) {
            lastKnownTrafficLightOrigin = origin
        }
        return lastKnownTrafficLightOrigin
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
        if isCascadingSlotClose {
            // Not adopted as a switch, but the display should still follow
            // whatever window is on screen now.
            adoptSpaceForDisplayDuringCascade(spaceId)
            return
        }
        // Ignore key changes while session restore is still surfacing this
        // slot's windows. On restore a slot owns several Chromium windows (one
        // per Space ever surfaced) and Chromium `makeKeyAndOrderFront`s every
        // one as its tabs finish loading, so each restored sibling briefly
        // becomes key. Adopting those as external switches thrashes
        // `activeSpaceId` and lands the slot on whichever window keyed last
        // instead of the Space the snapshot recorded (`slotForRestoreIndex`'s
        // `initialSpaceId`) — the "reopen flashes one Space then jumps to
        // another" symptom. `reconcileRestoreVisibility` owns visibility during
        // this window; a genuine user pip-switch goes through `activate`
        // (`userInitiated`), not here, so it is unaffected. Covers both
        // cold-launch and Dock reopen: both arm this flag via
        // `scheduleRestoreVisibilityReconcile`, and it clears once the reconcile
        // sequence settles.
        if restoreVisibilityReconcileScheduled { return }
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
        activeSpaceAdoptedFromKeyEvent = true

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
                // route, so `activate`'s swap-time frame inheritance never ran.
                // Do it here instead, from the leaving window (still alive, so
                // authoritative), or the target surfaces at whatever position it
                // was last left at. Mirrors `activate`'s swap path; safe with
                // both animation styles below.
                if let inheritedFrame = resolveInheritedFrame(from: previous),
                   let targetWindow = controller.window {
                    targetWindow.setFrame(inheritedFrame, display: false)
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
        // Ahead of the guard below, which is about the window: a controller
        // whose window has not been made yet still has the `BrowserState` the
        // sidebar width lives on, and skipping this would also leave the
        // PREVIOUS window's subscription alive.
        observeSidebarWidth(on: controller)
        guard let window = controller?.window else { return }
        let propagate: () -> Void = { [weak self, weak window] in
            guard let self,
                  !self.isAnimatingWindowSlide,
                  let window,
                  let visible = self.visibleController,
                  visible.window === window else { return }
            let frame = window.frame
            // Every frame change that reaches here is adopted as the slot's
            // position — including programmatic ones. This slot used to keep a
            // post-swap "pin" that reverted repositions no mouse button was
            // driving, because AppKit rewrote a just-ordered-in window's frame
            // into the screen's `visibleFrame` and the slot legitimately parks
            // its windows partly off-screen. That rewrite is now refused at the
            // source (Phi's `BrowserNativeWidgetWindow` overrides
            // `constrainFrameRect:toScreen:`), which left the pin with nothing
            // to consume it and therefore permanently armed after every switch —
            // at which point it only undid legitimate repositioning: Window >
            // Zoom, keyboard tiling, and AppKit re-homing a window off a display
            // the user just unplugged. "No mouse button held" was never a sound
            // proxy for "not the user" either; it also matches the didMove
            // AppKit posts right after a drag's mouse-up.
            // A frame change landing while the slot is cascading its windows
            // shut is teardown churn, not placement: Chromium is surfacing
            // whichever sibling still has a `beforeunload` prompt to answer.
            // Refuse it as the slot's authoritative frame — that value seeds
            // every later switch and spawn, so letting one in here outlives the
            // gesture (measured before this guard: a cascade rewrote
            // `lastKnownFrame` from the user's position to the screen work area,
            // and the surviving window kept it after "Cancel").
            //
            // Deliberately not qualified by `pressedMouseButtons`: that reads
            // any button anywhere, not "this window is being dragged", so it
            // would only open a hole for a reposition landing while the user
            // happens to be holding the mouse down. Nor is it safe to assume the
            // user cannot move the window meanwhile — a `beforeunload` prompt is
            // app-modal in Chromium's dialog queue, but its view is
            // `ModalType::kWindow`, i.e. a sheet, and a sheet does not stop the
            // parent being dragged. What makes refusing safe is the recovery
            // path, not the assumption: a vetoed cascade re-seeds this from the
            // survivor's live frame (`recoverFromVetoedCascade`), and a cascade
            // that runs to completion takes the slot with it.
            //
            // Known cost, accepted: with several dirty Spaces the user can drag
            // the window while the FIRST prompt is up, answer "Leave" to it, and
            // then "Cancel" a later sibling's prompt. That drag is refused here
            // and the dragged window is gone before the recovery runs, so the
            // slot settles on the survivor's older position instead. Every way
            // of keeping the drag re-opens the hole this guard closes —
            // propagating to siblings mid-cascade carries a clobbered frame the
            // same way, and `pressedMouseButtons` is the unreliable proxy that
            // was removed from here for good reason. Losing one drag on that
            // path is the cheaper failure.
            if self.isCascadingSlotClose {
                return
            }
            // The visible window is the slot's authoritative position now;
            // record it so a later spawn/switch inherits the user's drag even
            // if the source window is gone by then.
            self.lastKnownFrame = frame
            // Never push a fullscreen rect onto the siblings. A sibling that has
            // been ordered out is a plain windowed NSWindow, and a screen-sized
            // rect puts its title bar above the menu bar — AppKit used to shove
            // that back down on order-in, but Phi's
            // `constrainFrameRect:toScreen:` override deliberately hands such a
            // frame back untouched now, so an unreachable sibling would stay
            // unreachable. The slot's own frame still follows fullscreen above:
            // the in-fullscreen swap path inherits it.
            //
            // Keyed on the frame rather than on the window's `.fullScreen`
            // styleMask, so that re-aligning the siblings on the way out of
            // fullscreen does not hinge on when AppKit flips that mask — a point
            // this code cannot observe (`windowFullScreenStateChanged` runs off
            // the WILL hooks, which by design fire before the flip). The
            // didResize that lands while leaving fullscreen already carries the
            // windowed rect, so it propagates whatever the mask says.
            if NSScreen.screens.contains(where: { $0.frame.equalTo(frame) }) {
                return
            }
            // Past the fullscreen filter, so this is a windowed rect: the
            // geometry the slot should reopen at. Recording it here is what
            // makes moving and resizing reach the restore snapshot at all —
            // every other trigger of a snapshot write is a layout event
            // (registering a window, switching Space, fullscreen, key, evicting
            // a window), so without this a drag was remembered only until the
            // next one of those happened to fire, if one ever did.
            //
            // Skipped while the slot is fullscreen, on top of the exact-screen
            // check above: the will-enter hook arms that flag before AppKit
            // animates the window up to the screen, and the intermediate rects
            // that animation posts match no display exactly — the check above
            // would wave them through and the slot would remember a size it was
            // never parked at. Leaving fullscreen needs no such guard: the flag
            // is already false by then, and the trailing-edge debounce means
            // only the settled windowed rect is ever written.
            //
            // Also gated on the value actually changing, so the writes stay
            // tied to the user moving the window: a Space switch re-asserts the
            // slot's inherited frame on the entering window, which lands here
            // as a frame change carrying no new position.
            if !self.isFullScreen, self.lastKnownWindowedFrame != frame {
                self.lastKnownWindowedFrame = frame
                self.manager?.scheduleSlotsSnapshotPersist()
            }
            for (_, sibling) in self.windowsBySpaceId where sibling !== visible {
                sibling.window?.setFrame(frame, display: false)
            }
        }
        let move = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main,
            using: { _ in propagate() }
        )
        let resize = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main,
            using: { _ in propagate() }
        )
        visibleFrameObservers = [move, resize]
    }

    /// Keeps the snapshot's sidebar width current, the same way the two
    /// observers above keep its frame current.
    ///
    /// Needed for exactly the reason the frame needed it: dragging the split
    /// divider changes nothing a window notification reports, and every other
    /// trigger of a snapshot write is a layout event — registering a window,
    /// switching Space, fullscreen, key, evicting a window. Without this, a
    /// user who widened the sidebar and then closed the window would reopen to
    /// a band at the OLD width, and a band whose edge is not where the restored
    /// sidebar ends is the position jump this whole feature exists to prevent.
    /// (`unregisterWindow`'s flush covers the close-inside-the-debounce case,
    /// as it does for a drag.)
    ///
    /// Seeded rather than left to the subscription: `@Published` delivers its
    /// current value on subscribe, and the slot changing which window it shows
    /// is not the user resizing anything. The seed goes through
    /// `snapshotSidebarWidth`'s filter so a not-yet-laid-out window cannot
    /// donate its initial zero.
    private func observeSidebarWidth(on controller: MainBrowserWindowController?) {
        visibleSidebarWidthObserver = nil
        guard let controller else { return }
        _ = snapshotSidebarWidth()
        visibleSidebarWidthObserver = controller.browserState.$sidebarWidth
            .dropFirst()
            .sink { [weak self, weak controller] width in
                guard let self, let controller,
                      self.visibleController === controller,
                      // The two refusals the frame path makes, for the same
                      // reasons: a slot cascading shut is producing teardown
                      // churn rather than layout the user asked for, and a
                      // Space-switch slide is re-asserting the slot's own
                      // shape onto the entering window.
                      !self.isCascadingSlotClose,
                      !self.isAnimatingWindowSlide,
                      // Same "is this zero real" test as the snapshot read.
                      width > 0 || controller.browserState.sidebarCollapsed,
                      self.lastKnownSidebarWidth != width else { return }
                self.lastKnownSidebarWidth = width
                self.manager?.scheduleSlotsSnapshotPersist()
            }
    }

    /// The frame `frame` has to be corrected to for the current screen layout,
    /// or nil when it is still usable as-is.
    ///
    /// The correction itself is `SpaceManager.clampedSlotFrame` — the same rule
    /// a saved frame is read back through, so a slot repaired live and a slot
    /// reopened from the snapshot land in the same place. This wrapper only
    /// adds "nil when nothing changed", which its caller uses to skip a
    /// pointless `setFrame`.
    private static func screenRepairedFrame(for frame: NSRect) -> NSRect? {
        let screens = SpaceManager.currentScreenGeometries()
        guard !screens.isEmpty else { return nil }
        let repaired = SpaceManager.clampedSlotFrame(frame, toScreens: screens)
        return repaired.equalTo(frame) ? nil : repaired
    }

    /// Re-checks this slot's placement after a screen-layout change and pulls
    /// the windows back when the new layout left them unreachable. Only the
    /// visible window is moved; the frame observer mirrors the correction onto
    /// the siblings and records it, exactly as it does for a user drag.
    ///
    /// Skipped in fullscreen (the frame is legitimately the whole screen there)
    /// and mid-cascade (the slot is tearing down, and the observer refuses
    /// frame changes for the duration anyway).
    fileprivate func revalidatePlacementForScreenChange() {
        guard !isCascadingSlotClose, !slotHasFullScreenWindow,
              let visibleWindow = visibleController?.window,
              let repaired = Self.screenRepairedFrame(for: visibleWindow.frame)
        else { return }
        AppLogInfo("[SpaceWindowSlot] screen layout changed; repairing unreachable slot frame \(visibleWindow.frame) -> \(repaired)")
        visibleWindow.setFrame(repaired, display: true)
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
        visibleSidebarWidthObserver = nil
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

    /// Replaces the entering half's content mid-slide. Used by the spawn
    /// push-in, which starts against a transparent placeholder and swaps the
    /// real band in once the spawned window exists — only the image changes,
    /// so the in-flight frame animation carries on seamlessly.
    func updateEnteringImage(_ image: NSImage) {
        enteringImageView.image = image
    }

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

extension Notification.Name {
    /// Posted by a `SpaceWindowSlot` (as the notification object) whenever the
    /// window it shows on screen changes — user switches and programmatic ones
    /// alike. Unlike `NSWindow.didBecomeKeyNotification`, this also fires while
    /// the app is inactive, where an ordered-front window cannot become key.
    static let spaceSlotVisibleWindowDidChange =
        Notification.Name("PhiSpaceSlotVisibleWindowDidChange")
}

/// The loading window a windowless reopen puts on screen immediately, on the
/// frame the reopening slot's snapshot remembered, while Chromium replays the
/// session behind it.
///
/// It buys no time — nothing here makes the restore do less work, and it costs
/// the restore a little (see the switch below). What it removes is the second
/// and a half of blank desktop in between. It can only do that without a
/// position jump because the restored window is then FORCED onto this same rect
/// (`SpaceWindowSlot.registerWindow`) rather than trusted to come back with
/// bounds that happen to match.
///
/// Sharing a rect is necessary and not sufficient: the two windows also have to
/// be the same SHAPE, or the user watches one window be replaced by another
/// rather than one window fill in. So this is a titled window wearing the
/// browser window's own style mask and the same titlebar dressing (transparent
/// titlebar, hidden title). Titled is the point: the corner radius and the
/// window shadow come from an AppKit frame view at whatever values this macOS
/// uses, instead of being guessed at in a borderless window's content layer and
/// re-guessed every OS release.
///
/// Not quite for free, though, and this is the part that looks free and is not:
/// the fork puts its OWN frame view under the browser window
/// (`BrowserWindowFrame`), so the two shapes come from different classes and
/// agree only as far as they happen to. On macOS 26.5 they do not entirely:
///
/// - the **corners differ**. That frame view returns 20 from
///   `_getCachedWindowCornerRadius` where a stock one on this OS returns 16, and
///   the arcs measured off a real reopen sit up to ~2pt apart through the upper
///   half of the corner. Small, unfixable from this side, and NOT introduced
///   here — this window has had the stock radius since it became titled. Worth
///   knowing because an earlier note in this file claimed the two radii matched
///   point for point; they do not.
/// - the **traffic lights it moves outright**, and
///   `alignTrafficLights(to:)` below is what puts them back, at the origin
///   the snapshot saw on the window this one stands in for.
///
/// The bill for being titled is AppKit's frame constraint: it rewrites a titled
/// window's frame into the screen's `visibleFrame` on every order-in, and a
/// slot the user parked half off an edge would be dragged back — the position
/// jump this whole feature exists to prevent. Browser windows are exempted from
/// it in the Chromium fork
/// (`-[BrowserNativeWidgetWindow constrainFrameRect:toScreen:]`), and
/// `constrainFrameRect(_:to:)` below is the same refusal on this side.
/// Measured on this deployment target: the same overhanging frame ordered in on
/// a plain titled window comes back pulled to the work-area origin, on this one
/// it comes back untouched. `ReopenLoadingWindowPlacementTests` holds both ends
/// of that down.
///
/// Inside that shape it draws three things: the three traffic lights, in the
/// inactive grey a window that can be neither key nor main is entitled to; the
/// sidebar itself down the leading edge, at the width it had; and three dots in
/// the middle of whatever is left, taking it in turns to light. Nothing here
/// reads a preference, and every number the first two need — the rect, the
/// band's width, the lights' origin — comes off the slot snapshot, measured
/// from the very window this one stands in for. The band's COLOUR is the one
/// thing resolved live rather than stored, because a theme the user changed
/// while the app had no windows would otherwise be a stale fill. The dots need
/// nothing stored at all.
///
/// The dots are also the only thing here that moves, and how fast they move is
/// the only decision here that could cost measurable time — "could" because at
/// the rate it settled on it does not, and two rates above it do. The sweep is
/// in the spinner bullet below, along with what it does NOT bound: the cost of
/// the three layers existing at all, which the control arm also draws.
///
/// It has all three because the empty version was used in anger, three times.
/// The first report was that a blank rect reads as an application that has not
/// started rather than one that is loading — the same user finding
/// `.comfortable` the least bad of the three layouts, and finding it so because
/// its first painted frame carries a skeleton (lights, `+`, a search icon, an
/// empty tab strip) even though its tabs arrive no sooner and its total time to
/// tabs is LONGER. What reads as alive is having something in the window, not
/// having the right thing in it. The lights alone did not answer that — three
/// 14pt discs are about 0.05% of a 1183x788 rect — and the second report said
/// so: still no skeleton. The band is what `.comfortable` gets for free and the
/// other two layouts had nothing of. A rect split into a sidebar and a content
/// area reads as a browser window; a rect in one colour does not. The third
/// report was that a browser-shaped window with nothing happening in it is
/// still a window with nothing happening in it: there should be something in
/// the large blank area saying it is loading, in every layout. That is the one
/// requirement here about time passing rather than about shape, and it is the
/// only one that cannot be met by holding still.
///
/// Six visuals were considered; this is what is left standing:
///
/// - **A spinner could not be afforded; the thing it was saying could.** The
///   first version turned a 32pt ring here. Measured against the same scene
///   with the switch off, it put the first thing on screen ~780ms sooner and
///   the page's own first frame ~450ms LATER; with only the ring's animation
///   frozen and everything else identical, roughly two thirds of that second
///   number went away (n=3 per group, so the size is indicative and the
///   direction is not). The ring had been making the window server recomposite
///   this rect at 60fps for two seconds, to report that the main thread was too
///   busy to draw — spending the restore it exists to cover.
///
///   The bill is per recomposition and not per second the window is up, so when
///   the third report asked for the message back, the RATE was swept on the
///   real reopen instead of guessed at a second time. Four arms, one binary,
///   interleaved, 8 rounds each, all of them with the band in place — the
///   ring's number could not be reused, because it was measured before this
///   window had any vibrancy in it and vibrancy is not cheap to recomposite.
///   Median of the page's own first frame against a control that draws these
///   same three dots and does not animate them:
///
///   | rate | vs the still control | overlaps the control's range? |
///   |---|---|---|
///   | 3 steps a second | +14.0ms | yes, entirely |
///   | 15 steps a second | +44.0ms | **no, 8/8 apart** |
///   | interpolated, per display refresh | +133.5ms | **no, 8/8 apart** |
///
///   The bottom row is the positive control, and it is the reason the top row
///   means anything: this batch CAN see an animation's cost — it separated
///   44ms with no overlap at all — and it still could not separate three steps
///   a second. That +14.0ms is smaller than the difference in frame
///   quantisation between those same two arms (the 3-step arm's events land in
///   a 67ms gap against the control's 33ms, so it is reported an expected 17ms
///   late before the app has done anything at all). That is where
///   `activityStepsPerSecond` comes from. Raising it is not a free change of
///   taste; 15 was measured, and 15 costs. Making the dots BIGGER is free —
///   the bill is per recomposition, and nothing here was measured against
///   their size.
///
///   What the sweep does not bound: the three layers merely existing. The
///   control arm draws them too, so what is measured is the animation. The
///   nearest bound on the layers is the band — a full-height vibrancy view,
///   far heavier than three 8pt layers — at +7.5ms on this same metric, and
///   that is a cross-batch number.
/// - **Traffic lights need nothing known about the window** beyond where they
///   go. Phi leaves the browser window's own buttons in the titlebar —
///   `FloatingTrafficLightsView` draws its own and forwards clicks rather than
///   reparenting them — and only hides them for a collapsed sidebar in a
///   non-traditional layout, which a freshly restored window is not. What they
///   are NOT is free: their position had to be measured, because the style
///   mask alone does not reproduce it. See `trafficLightOrigin(remembered:)`.
/// - **The sidebar band needs one number, and it must be the real one.** A
///   guessed width would put the boundary somewhere the restored window's
///   sidebar does not end, and the band would step sideways at the hand-off —
///   worse than no band. So it is read from the snapshot and nowhere else, and
///   a snapshot that does not carry it draws nothing (`sidebarBandWidth`). The
///   objection this had to get past — that a band would have to be one of three
///   layouts, and `.comfortable` has no sidebar — turned out to cost nothing:
///   `.comfortable` keeps the sidebar collapsed permanently, a collapsed
///   sidebar records itself as width 0, and 0 draws nothing. One number covers
///   the width, the collapsed state and the layout together, and nothing here
///   reads `LayoutMode`.
/// - **A flat fill of the sidebar's theme colour shows nothing, measured.**
///   The obvious build — one `CALayer` filled with `windowOverlayBackground` —
///   was built first. On the default theme it is invisible: Pure's light
///   overlay is white at the fixed 0.8 overlay alpha over a white
///   `windowBackgroundColor`, so the two tones are one tone. The real sidebar's
///   separation (measured on a real reopen: 220 against the content's 253 on
///   the same row) comes from its `NSVisualEffectView` material. So the band is
///   that view, with that material, wearing that colour, resolved against the
///   theme the Space that is reopening will be given
///   (`SpaceManager.sidebarTint(forSpaceId:)`) — the sidebar's own recipe
///   rather than a colour chosen to look like its output, which is the
///   difference between following a theme and matching one.
/// - **The indicator is the one thing here that copies nothing**, and that is
///   allowed for the opposite reason to everything else: it corresponds to no
///   part of the restored window, so there is nowhere it can be drawn in the
///   wrong place relative to one. It is not replaced at the hand-off, it is
///   covered — measured on all three layouts, and the frame after it goes has
///   no trace of it left. What it must not be is a progress bar: that would
///   either state a fraction nobody here knows, or move continuously, which is
///   the expensive shape again under a different name.
/// - **The closing window's last frame is not obtainable.** Phi can only
///   capture those pixels synchronously on the close path, and under remote
///   CoreAnimation there is no app-side IOSurface to capture from. Not merely
///   unchosen — unbuildable, so do not spend a round rediscovering it.
///
/// What is deliberately absent is anything that is data: no tabs, no Space
/// chips, no favicons. The `+ New Tab` row was considered and left out on a
/// measured fact rather than on principle — it has no resting fill of its own
/// to reproduce (`NewTabButtonCellView` sets its background clear and fills
/// only on hover), so any shape drawn where it goes would be invented, and the
/// hand-off would then remove it.
///
/// What is left is the window itself: this rect, this shape, this shadow, this
/// background colour, three grey lights, a sidebar-coloured band, and three
/// dots taking turns in the middle of the content area, arriving where the
/// restored window will arrive. The restored window's first painted frame then
/// fills it in — one visual change, which is what the z-order hand-off below is
/// for.
final class ReopenLoadingWindow: NSWindow {
    /// Toggle at runtime:
    ///   defaults write <bundle-id> PhiReopenLoadingWindowEnabled -bool YES
    /// then relaunch. Off by default, and the measurements are why.
    ///
    /// Over 5 matched rounds each way on one six-Space scene, marker-anchored
    /// from the Dock click: the first thing on screen arrives 633ms sooner
    /// (median 65ms against 698ms), and the page's own first frame comes out
    /// level (1832ms against 1815ms — a difference far inside either arm's own
    /// spread of 176ms and 50ms, so no difference is claimed).
    ///
    /// The browser chrome is the problem, and it is not a matter of a median.
    /// With the switch off it is on screen in the restored window's very first
    /// painted frame, every round: 682-700ms, and the traffic lights are
    /// already coloured in it. With the switch on the same measurement splits
    /// in two — 746/748/748 against 1330/1374 — and across every round of this
    /// scene measured either way, about half land in the late half. The
    /// restored window's first frame is either flushed during a pause in the
    /// restore's window-creation burst or it waits for the end of the burst,
    /// and this window's existence is what decides that: with it off the pause
    /// was enough in 6 rounds out of 6. Neither its overlap with the restored
    /// window nor how long it stays up accounts for it (both were measured with
    /// it moved off the rect and with it closed on registration; neither
    /// changed the number), so the cost is paid by building and ordering it in
    /// at all, before the restore is even asked for. Why that should be is NOT
    /// established, and nothing here should be read as if it were.
    ///
    /// So the trade on offer is 633ms of earlier feedback against roughly even
    /// odds of the chrome arriving ~590ms later. That is a product call and not
    /// one this file can make — but it is a worse one than it looked while the
    /// late half was believed to be a z-order race. With the switch off nothing
    /// here is constructed and no other path consults it.
    static let featureEnabledKey = "PhiReopenLoadingWindowEnabled"

    static var isFeatureEnabled: Bool {
        UserDefaults.standard.bool(forKey: featureEnabledKey)
    }

    /// Whether one saved slot gets a loading window on this reopen.
    ///
    /// Pure, and answerable before any window exists: two of the facts are
    /// app-wide and three come straight off the slot's snapshot entry, so every
    /// slot in a multi-slot reopen decides for itself. Every "no" leaves the
    /// reopen behaving exactly as it does without the feature.
    ///
    /// - `featureEnabled`: the switch above.
    /// - `sessionRestoreEnabled`: with restore off the reopen opens a single
    ///   plain window on its own path — there is no replay to wait through.
    /// - `isWindowlessReopen`: with a browser window already on screen the
    ///   click has visible feedback already, and this would just be a second
    ///   window in the way.
    /// - `snapshotFrame`: nil for a slot saved before the snapshot carried
    ///   geometry, or one whose stored rect no longer parses. Inventing a
    ///   position would produce the jump this feature exists to prevent.
    /// - `slotWasFullScreen`: a restored window always comes back windowed and
    ///   only re-enters fullscreen once restore settles, so the sequence would
    ///   be loading window → normal window → fullscreen animation. Worse than today,
    ///   hence out of scope.
    static func shouldShow(featureEnabled: Bool,
                           sessionRestoreEnabled: Bool,
                           isWindowlessReopen: Bool,
                           snapshotFrame: NSRect?,
                           slotWasFullScreen: Bool) -> Bool {
        guard featureEnabled,
              sessionRestoreEnabled,
              isWindowlessReopen,
              snapshotFrame != nil,
              !slotWasFullScreen
        else { return false }
        return true
    }

    /// - Parameters:
    ///   - frame: the slot's remembered rect, already clamped to the screens
    ///     attached now.
    ///   - sidebarWidth: how wide the slot's sidebar was, from the snapshot.
    ///     Nil for a snapshot written before that was recorded, `0` for a
    ///     collapsed one; both mean no band (`sidebarBandWidth`).
    ///   - sidebarTint: the colour that sidebar filled itself with. Only read
    ///     when there is a band to draw.
    ///   - trafficLightOrigin: where the restored window's leading light sat,
    ///     from the snapshot. Nil falls back to a constant copied out of the
    ///     fork (`copiedTrafficLightOrigin`).
    ///
    /// Every default is nil, and nil is the honest degradation rather than a
    /// convenience: it is exactly what an older snapshot supplies, and what the
    /// window does with it is what the first reopen after an upgrade will do.
    init(frame: NSRect,
         sidebarWidth: CGFloat? = nil,
         sidebarTint: NSColor? = nil,
         trafficLightOrigin: NSPoint? = nil) {
        // Resolved before `super.init` because it decides the style mask: no
        // usable origin, no buttons at all.
        let lightOrigin = Self.trafficLightOrigin(remembered: trafficLightOrigin)
        // Byte for byte the mask the fork gives a normal browser window
        // (`BrowserNativeWidgetMac::PopulateCreateWindowParams`: titled,
        // closable, miniaturizable, resizable, plus full-size content for the
        // `kBrowser` window class). Matching it is not decoration — it is what
        // brings the three traffic lights into existence. A titled window
        // WITHOUT closable/miniaturizable/resizable has no standard buttons at
        // all: `standardWindowButton` answers nil for all three, measured, so
        // before this they were not hidden here, they were absent.
        //
        // The mask gets them drawn. It does NOT get them in the right place —
        // that takes `alignTrafficLights(to:)`, called at the end of this
        // initializer — and when no origin can be trusted the mask reverts to
        // the buttonless one, so no lights are drawn at all.
        //
        // They are drawn in AppKit's inactive grey, because this window can
        // become neither key nor main (both refused below) — which is also the
        // honest reading of a window that takes no input. The restored window's
        // own first painted frame has them coloured, so the hand-off changes
        // their colour but not their position.
        super.init(contentRect: frame,
                   styleMask: lightOrigin != nil
                       ? [.titled, .closable, .miniaturizable, .resizable,
                          .fullSizeContentView]
                       : [.titled, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        // Whatever the band and the dots do not cover is this colour, and with
        // no band it is nearly the whole rect: an opaque titled window's own
        // frame view fills itself with it and rounds the corners, which is why
        // the content view installed below carries only those two things and
        // never a background of its own.
        //
        // The value is the literal one
        // `MainBrowserWindowController.setupWindow` gives the browser window,
        // so the rect held here is already the colour the restored window
        // arrives in. Light and dark cannot diverge between the two either:
        // both resolve it against one app-wide preference —
        // `ThemeManager.userAppearanceChoice` sets `NSApp.appearance`, which
        // this window inherits, and is also what the browser window's own
        // `window.appearance` is built from. The one window that overrides it,
        // Incognito, is never a reopen target: Incognito Spaces are dropped
        // from the restore snapshot wholesale.
        backgroundColor = .windowBackgroundColor
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        // Titled windows are restorable by default, and the browser window
        // turns that off for the same reason: AppKit re-creating a stand-in for
        // a window this app builds itself, on a launch it knows nothing about,
        // can only get in the way.
        isRestorable = false
        // Inert: it takes no input and becomes neither key nor main (both
        // refused below). A deliberate departure from the original sketch,
        // which had this window take key because the user just clicked the
        // Dock — the restored window is the one they type into, a reopen
        // already loses key on the target window for a few hundred ms, and
        // nothing here can accept a keystroke anyway.
        //
        // Pass-through was re-examined when the visual became a blank rect, and
        // again now that the rect carries three things shaped like buttons, and
        // kept both times. The app a click falls through to is the one the user
        // just left, and it is only reachable until the restored window is
        // pinned over this rect: 155 to 175ms after this window goes up, median
        // 165, over 16 reopens. (From this file's own two log lines, "loading
        // window shown at" to "loading window put under the restored one"; the
        // rounds and the command that recomputes it are in the ticket's
        // evidence directory.) Hit testing is geometric, so from then on the
        // restored window takes the click whether or not it has painted yet.
        //
        // Inside those 165ms the pointer is on the Dock tile the user just
        // pressed, which is the gesture that got here — nowhere near this
        // window's top-left corner. And a click that DID land there was going
        // to the application underneath anyway a moment earlier, so passing it
        // through is the behaviour that keeps doing what the user meant.
        // Swallowing clicks instead would put a window that can be neither key
        // nor main into the click path, where whether AppKit raises it over the
        // restored window is not something this codebase knows — and it being
        // raised is the one outcome worse than today.
        //
        // The lights are inert in the other direction too. No mouse event
        // reaches them because of this line, and the one path this line does
        // not close — an accessibility press — is closed by
        // `makeTrafficLightsUnpressable` below, which costs nothing visually.
        ignoresMouseEvents = true
        // Not a window the user opened, so it must appear in none of the places
        // the user's own windows are listed or cycled through — Window menu,
        // Cmd+` , Mission Control.
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        // No fade-in: the point of this window is to be on screen at the first
        // opportunity, and an implicit animation would spend the first frames
        // of that opportunity being invisible.
        animationBehavior = .none
        // The other half of the tax for being titled, and a separate one from
        // the order-in constraint below: `init(contentRect:)` moves an
        // overhanging rect up into the work area itself, before any
        // `constrainFrameRect` call it could be refused through. Measured: a
        // rect 60pt below the work area comes back 90pt above where it was
        // asked for. A plain `setFrame` after the fact does land exactly (that
        // path asks, and is refused), so put it back.
        setFrame(frame, display: false)
        // After the final `setFrame`, because all three read the settled size.
        // Content view before the lights as a precaution rather than a measured
        // need: installing one was checked and does NOT move the buttons, so
        // the order is only insurance against a future AppKit that lays the
        // titlebar out again when it gets one.
        // `testTheSidebarBandDoesNotDisturbTheLights` is what would notice.
        let host = NSView(frame: NSRect(origin: .zero, size: self.frame.size))
        // The width actually drawn, not the width remembered: with no tint
        // there is no band, and the indicator has to be centred in what the
        // window really looks like.
        var bandWidth: CGFloat?
        if let width = Self.sidebarBandWidth(remembered: sidebarWidth,
                                             inWindowOfWidth: self.frame.width),
           let sidebarTint {
            installSidebarBand(width: width, tint: sidebarTint, in: host)
            bandWidth = width
        }
        if let dots = Self.activityDotsFrame(besideBandOfWidth: bandWidth,
                                             inWindowOfSize: self.frame.size) {
            installActivityDots(dots, in: host)
        }
        contentView = host
        if let lightOrigin {
            alignTrafficLights(to: lightOrigin)
            makeTrafficLightsUnpressable()
        }
    }

    /// The band while there is one, so the tests can hold its geometry down.
    /// Nil is a real state — the snapshot remembered no width — and not a
    /// zero-width view, so a reopen without one costs exactly what it cost
    /// before the band existed.
    private(set) var sidebarBand: ColoredVisualEffectView?

    /// How wide a band to draw over the slot's sidebar, or nil for none.
    ///
    /// Nil in, nil out, and that is the rule the band exists under: a snapshot
    /// written before this was recorded has no width, and a default would be a
    /// guess. A band whose edge does not land exactly where the restored
    /// window's sidebar ends moves at the hand-off, which is the one thing this
    /// route exists to prevent — so no band beats a wrong band.
    ///
    /// `0` is a value rather than a gap: it is how a collapsed sidebar is
    /// recorded, and `.comfortable` records itself the same way because it
    /// keeps the sidebar collapsed permanently
    /// (`MainSplitViewController.updateLayoutForHorizontalTabs`). One number
    /// therefore settles the width, the collapsed state and which layouts draw
    /// anything, which is why nothing in this class reads `LayoutMode` — and
    /// `.comfortable` is the layout that needs no help, since its own first
    /// painted frame already carries a tab-strip skeleton.
    ///
    /// A width that does not fit the window is refused outright rather than
    /// clamped, by the same rule: the frame is clamped to the screens attached
    /// now, so a slot saved on a wide display can in principle come back
    /// narrower than its own sidebar was, and a band clamped to the window is
    /// the whole rect in one colour — a solid block, not a browser window, and
    /// nowhere near where the restored sidebar will end. Unreachable in
    /// practice (`leftItemMaxWidth` is 500 and no display is narrower), which
    /// is the other reason not to invent a behaviour for it.
    static func sidebarBandWidth(remembered: CGFloat?,
                                 inWindowOfWidth windowWidth: CGFloat) -> CGFloat? {
        guard let remembered, remembered > 0, remembered <= windowWidth else { return nil }
        return remembered
    }

    /// Covers the leading `width` points of the window with the sidebar.
    ///
    /// Built the way `SidebarViewController.loadView` builds the real one — the
    /// same class, the same `.fullScreenUI` material, the same
    /// `windowOverlayBackground` colour over it — and that is not fastidiousness,
    /// it is the only thing that works. A flat fill of the colour alone was
    /// built first and is INVISIBLE on the default theme: Pure's light overlay
    /// is `0xFFFFFF` at the fixed 0.8 overlay alpha, over a window whose
    /// background is `NSColor.windowBackgroundColor`, which is white too, so
    /// the "two-tone split" composites to one tone. Measured off a real reopen
    /// at 8 device pixels per point, the restored window's sidebar reads 220
    /// and its content 253 on the same row — a 33-level step that comes from
    /// the MATERIAL, not from the token. Reproducing the token without the
    /// material reproduces none of it.
    ///
    /// Given the colour directly rather than through `themedBackgroundColor`,
    /// on purpose: that property would subscribe this window to theme changes
    /// and resolve against `ThemeManager.shared`, whereas the colour handed in
    /// here is already resolved against the theme the Space that is reopening
    /// will actually be given (`SpaceManager.sidebarTint(forSpaceId:)`).
    ///
    /// `state` is forced active because this window can be neither key nor
    /// main, and the default would render the material in its inactive variant
    /// while the restored window's sidebar — whose window does take key —
    /// renders the active one.
    ///
    /// A full-size-content window's content view spans the frame, so the band's
    /// coordinates are the frame's and the boundary is at exactly `width`.
    /// Nothing resizes this window after `init`, so it is placed once.
    private func installSidebarBand(width: CGFloat, tint: NSColor, in host: NSView) {
        let band = ColoredVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: width, height: frame.height))
        band.material = .fullScreenUI
        band.state = .active
        band.backgroundColor = tint
        host.addSubview(band)
        sidebarBand = band
    }

    // MARK: - The activity indicator

    /// The three dots while there are any, so the tests can hold their geometry
    /// and their rhythm down. Nil is a real state — a content area too small to
    /// hold them draws none (`activityDotsFrame`) — rather than an empty view.
    private(set) var activityDots: NSView?

    /// Three, and the same three twice over: it is how many dots there are AND
    /// how many steps a cycle has, because each dot lights exactly once per
    /// cycle. Named rather than left as a literal because it is the one number
    /// here that couples the geometry to the timing, across three functions.
    static let activityDotCount = 3
    /// Sized to the traffic lights' own discs rather than picked by eye: at 8pt
    /// the group was 0.016% of the window by ink, a third of the lights the user
    /// had already called too little to notice, and it read as too small on a
    /// 1183x788 window. Matching them is the one non-arbitrary size available.
    ///
    /// Free to change. The A/B in `activityStepsPerSecond` priced the *rate* --
    /// the window server bills per recomposition -- and nothing here is billed
    /// by area: three 14pt discs animate 462pt² of a ~932,000pt² window.
    static let activityDotDiameter: CGFloat = 14
    static let activityDotGap: CGFloat = 12
    static let activityDotLitOpacity: Float = 1
    static let activityDotRestingOpacity: Float = 0.25
    static let activityAnimationKey = "phiReopenLoadingActivity"

    /// How many times a second the light moves on to the next dot.
    ///
    /// The one number this indicator costs anything through, and it was swept
    /// rather than chosen. See the class comment for the curve.
    static let activityStepsPerSecond: Double = 3

    /// The group, laid out in a row.
    private static var activityDotsSize: NSSize {
        NSSize(width: CGFloat(activityDotCount) * activityDotDiameter
                    + CGFloat(activityDotCount - 1) * activityDotGap,
               height: activityDotDiameter)
    }

    /// Where the group goes in the window's own coordinates, or nil for "no
    /// room for it".
    ///
    /// The blank area the user is looking at is the content area, so the group
    /// is centred in what is left of the rect once the band has taken the
    /// leading edge — not in the window. With no band (`.comfortable`, and any
    /// snapshot with no remembered width) that is the whole rect, which is
    /// exactly what is blank there. One number covers all three layouts here
    /// for the same reason it does for the band, and nothing in this class
    /// reads `LayoutMode`.
    ///
    /// Refused rather than squeezed when it does not fit, by the band's rule: a
    /// group crushed against the band or clipped by the window is not an
    /// indicator, it is a defect the user gets a second to look at. Vertically
    /// it is the window's own centre and not the content pane's, because the
    /// snapshot carries no toolbar height and inventing one is the same
    /// mistake — the offset is at most a tab strip's worth on one layout.
    ///
    /// Total rather than nearly-total, and the finiteness test is why. Every
    /// caller today hands in numbers that already passed a finite check
    /// (`decodedSidebarWidth`, `decodedSlotFrame`), so it is unreachable — but
    /// an infinity here would come back out as an infinite origin rather than
    /// as a refusal, and this campaign has already lost an afternoon to a
    /// non-finite number travelling further than anyone expected it to.
    static func activityDotsFrame(besideBandOfWidth bandWidth: CGFloat?,
                                  inWindowOfSize size: NSSize) -> NSRect? {
        let leading = bandWidth ?? 0
        guard leading.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        let group = activityDotsSize
        let contentWidth = size.width - leading
        guard contentWidth >= group.width, size.height >= group.height else { return nil }
        return NSRect(x: leading + (contentWidth - group.width) / 2,
                      y: (size.height - group.height) / 2,
                      width: group.width,
                      height: group.height)
    }

    /// Puts the dots in the middle of the content area and starts them.
    ///
    /// The fill goes through the window's own appearance, and that wrapper is
    /// load-bearing rather than tidy. `NSAppearance.currentDrawing()` is Aqua
    /// outside a drawing context EVEN WHEN `NSApp.appearance` is darkAqua,
    /// which is exactly what `ThemeManager` sets for a dark theme — so a bare
    /// `.cgColor` here resolves the LIGHT variant, measured as black at 0.498
    /// alpha where the dark variant is white at 0.549. That is black dots on a
    /// dark window. It has nothing to do with the window not being on screen
    /// yet: measured before and after `orderFront`, the answer is identical.
    ///
    /// Layer-hosting rather than layer-backed — the dots ARE this view's
    /// content, so handing AppKit the layer is both simpler than asking for one
    /// and non-optional, which removes a `guard` that could only ever have
    /// failed silently.
    ///
    /// Nothing suppresses implicit actions here, and that is deliberate rather
    /// than an omission: a `CALayer` that has never been committed has no
    /// previous value to animate from, so setting frame, corner radius and
    /// colour before `addSublayer` attaches nothing. Measured on a live render
    /// server — the same mutations on an already-committed layer DO attach
    /// `position` and `backgroundColor` animations, which is the case a
    /// `CATransaction` would be for and is not the case here.
    /// `testTheIndicatorIsTheOnlyThingThatAnimates` is what notices if that
    /// ever stops being true.
    private func installActivityDots(_ rect: NSRect, in host: NSView) {
        let group = NSView(frame: rect)
        let root = CALayer()
        group.layer = root
        group.wantsLayer = true
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.secondaryLabelColor.cgColor
        }
        // The closure above is synchronous and unconditional, so this fallback
        // is unreachable. It is spelled out rather than force-unwrapped because
        // what it produces is the wrong variant, and a reader should be able to
        // see that rather than have to discover it.
        let fill = resolved ?? NSColor.secondaryLabelColor.cgColor
        let diameter = Self.activityDotDiameter
        let pitch = diameter + Self.activityDotGap
        for step in 0..<Self.activityDotCount {
            let dot = CALayer()
            dot.frame = NSRect(x: CGFloat(step) * pitch, y: 0,
                               width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = fill
            // What a still one would look like, and what the first frame shows
            // before the render server picks the rhythm up. It is the rhythm's
            // own first keyframe, so there is no flash between the two.
            dot.opacity = step == 0
                ? Self.activityDotLitOpacity : Self.activityDotRestingOpacity
            root.addSublayer(dot)
            dot.add(Self.activityRhythm(lightingDotAt: step),
                    forKey: Self.activityAnimationKey)
        }
        host.addSubview(group)
        activityDots = group
    }

    /// One dot's share of the rhythm: lit for step `step` of three, resting for
    /// the other two, forever.
    ///
    /// Discrete on purpose and not as a style: the calculation mode is the
    /// whole cost argument. An interpolated animation of the same duration has
    /// a new value on every display refresh and puts the window server back to
    /// recompositing this rect at the refresh rate, which is what the ring it
    /// replaces was doing. Discrete holds each value until the next key time,
    /// so the work is three composites a cycle however long the cycle is.
    ///
    /// Driven by the render server rather than by a timer, which is not an
    /// implementation detail either: the main thread is saturated by the very
    /// restore this is reporting on, so anything clocked on it would freeze
    /// exactly when it is supposed to say "still working".
    private static func activityRhythm(lightingDotAt step: Int) -> CAKeyframeAnimation {
        let rhythm = CAKeyframeAnimation(keyPath: "opacity")
        rhythm.values = (0..<activityDotCount).map {
            $0 == step ? activityDotLitOpacity : activityDotRestingOpacity
        }
        // Discrete mode wants one more key time than value — the last one is
        // when the final value stops applying, not when it starts — which is
        // why these are generated from the count rather than written out.
        //
        // 🔴 Not a formality. Measured against a live render server: three key
        // times for three values makes the LAST DOT NEVER LIGHT and drops the
        // realized rate from 3 steps a second to 2, while every property on the
        // animation object still reads correctly. Nothing about the object
        // looks wrong, so `testTheIndicatorAdvancesInDiscreteStepsAtTheSettledRate`
        // asserts this array itself.
        rhythm.keyTimes = (0...activityDotCount).map {
            NSNumber(value: Double($0) / Double(activityDotCount))
        }
        rhythm.calculationMode = .discrete
        rhythm.duration = Double(activityDotCount) / activityStepsPerSecond
        // The window outlives any finite count worth choosing, and a stopped
        // indicator on a restore that has not stopped is a worse lie than none.
        rhythm.repeatCount = .infinity
        return rhythm
    }

    private static let trafficLightKinds: [NSWindow.ButtonType] =
        [.closeButton, .miniaturizeButton, .zoomButton]

    /// Takes the three lights out of the one path that can still reach them.
    ///
    /// `ignoresMouseEvents` stops the mouse and nothing in this app targets
    /// them, but an accessibility press is neither of those, and all three are
    /// live wiring: their actions read `_close:`, `miniaturize:` and
    /// `_setNeedsZoom:`. A press on close would destroy this window inside the
    /// gap `ReopenLoadingHandoff.revealGrace` exists to cover; a press on
    /// miniaturize would send a window the user never opened — and which is
    /// deliberately kept out of the Window menu and Cmd-` — to the Dock.
    ///
    /// Costs nothing to look at, which is why it is worth doing: rendered off
    /// screen on a window that can be neither key nor main, the enabled and
    /// disabled titlebars come out byte-identical. Looking exactly like the
    /// restored window's is the whole reason these are here, so a change that
    /// altered them by a pixel would not have been worth this.
    private func makeTrafficLightsUnpressable() {
        for kind in Self.trafficLightKinds {
            standardWindowButton(kind)?.isEnabled = false
        }
    }

    /// Where `window` has its leading traffic light, as a distance from the
    /// top-left corner of its frame — the one frame of reference the loading
    /// window and the window it stands in for share.
    ///
    /// The reader half of the pair; `alignTrafficLights(to:)` is the writer,
    /// and they must keep the same convention. Taken through window
    /// coordinates rather than the titlebar view's own so neither depends on
    /// how tall AppKit made that view or where it put it, and counted down
    /// from the frame height because window coordinates start at the bottom
    /// left.
    ///
    /// Called on a real browser window while the slot snapshot is being
    /// written, which is the whole point: it answers with what THIS Chromium on
    /// THIS macOS actually does, so nothing has to be copied out of the fork
    /// and kept in step with it.
    static func measuredTrafficLightOrigin(in window: NSWindow) -> NSPoint? {
        // The close button specifically, not whichever one exists: the origin
        // describes the LEADING light, so reading any other would shift the
        // group by a whole 23pt pitch.
        guard let leading = window.standardWindowButton(.closeButton),
              let titlebar = leading.superview else { return nil }
        let height = window.frame.height
        guard height > 0 else { return nil }
        let inWindow = titlebar.convert(leading.frame.origin, to: nil)
        return NSPoint(x: inWindow.x,
                       y: height - inWindow.y - leading.frame.height)
    }

    /// Where to put the lights, or nil for "draw none at all".
    ///
    /// A remembered origin wins over the copied constant. It was read off the
    /// very window this one stands in for, on this machine, under this
    /// Chromium, in this layout — so it needs no cross-repository coupling, and
    /// a Chromium that moves its titlebar is followed automatically at the next
    /// persist. Without one, the constant below, which is a copy and carries
    /// all the problems a copy carries; reachable on the first reopen after
    /// this started being recorded, and on any older snapshot.
    ///
    /// The macOS 26 test governs BOTH, and deliberately: it is not about where
    /// the leading light goes, which a remembered origin does answer anywhere.
    /// It is about the other two. `alignTrafficLights(to:)` translates the
    /// group rigidly off the leading button, so it is right only if AppKit's
    /// 23pt pitch and 14pt discs match the fork's — and that was measured on
    /// 26.5 only. Below 26 the fork's inset override does not apply but its
    /// `_shouldCenterTrafficLights` still does, so the two frame views are
    /// known to differ there in a way nobody has looked at. Shipping an
    /// unmeasured misalignment is worse than shipping no lights, which is what
    /// this window did before it had any, and lifting this on the strength of
    /// one measured point would be claiming the other two for free.
    static func trafficLightOrigin(remembered: NSPoint?) -> NSPoint? {
        guard #available(macOS 26, *) else { return nil }
        return remembered ?? copiedTrafficLightOrigin
    }

    /// The fallback origin: where a restored window put its leading light when
    /// that was measured by hand off a real reopen. NOT where AppKit puts a
    /// plain titled window's.
    ///
    /// The fork installs its own `NSThemeFrame` subclass under every browser
    /// window (`BrowserWindowFrame`, in
    /// `components/remote_cocoa/app_shim/browser_native_widget_window_mac.mm`)
    /// and that class moves them: `_minXTitlebarWidgetInset` returns 13 on
    /// macOS 26, to sit concentric with the window corner it widens to 13 + 7 in
    /// the same file, and `_shouldCenterTrafficLights` returns YES.
    ///
    /// Measured off a real reopen on macOS 26.5, at 8 device pixels per point:
    /// the restored window's first disc has its origin at (13.00, 13.50) and a
    /// plain titled window's at (9.00, 9.00), with the same 14pt diameter and
    /// 23pt pitch in both, and the same numbers in `.performance`, `.balanced`
    /// and `.comfortable`. Four points is small; it is also exactly the kind of
    /// small this route cannot afford, because the hand-off is supposed to read
    /// as one window filling in and three discs stepping sideways as it does is
    /// the jump the whole route exists to remove.
    ///
    /// The x follows from the inset above. **Why the y is 13.5 and not 13 is not
    /// established** — 13.5 is what was measured, not what was derived, and an
    /// earlier version of this comment invented a cause for the half point that
    /// did not survive review. Note also that "centre" plausibly makes the y a
    /// function of the titlebar height, which `BrowserWindowFrame` takes from
    /// the browser view per window; it did not vary across the three layouts,
    /// which is the only evidence there is that it is a constant at all.
    ///
    /// That is the debt, and `trafficLightOrigin(in:)` above is what pays it
    /// off: a snapshot that has seen a real window never reaches this value.
    /// It stays for the reopens that have no such snapshot, and it stays a
    /// standing coupling to that file for exactly those — if the fork changes
    /// its inset, nothing here goes red and only a pixel round would notice.
    ///
    /// The other thing that could put the two sets out of step is the restored
    /// window hiding its own lights, which it does when the sidebar is
    /// collapsed in a non-traditional layout
    /// (`MainBrowserWindowController.setupContentView`) — the sidebar's
    /// floating pair is drawn instead, at its own metrics. That would not be a
    /// four-point step, it would be three discs moving and changing size, so it
    /// matters more than the correction above.
    ///
    /// It does not happen, and this is measured rather than argued, because the
    /// obvious argument is wrong. AppKit's split-view autosave DOES persist the
    /// sidebar item's collapsed flag — `defaults read` shows it as the fifth
    /// field of `NSSplitView Subview Frames phiMainBrowserSplitView` — and a
    /// restored window adopts that autosave before it is ever shown
    /// (`PhiChromiumCoordinator`, `adoptAutosavedSplitPositionNow`). What
    /// defeats it is that `BrowserState.sidebarCollapsed` is a fresh `false` on
    /// a new window and `MainSplitViewController.viewWillAppear` re-asserts it
    /// through the split item on subscription. Checked on the machine: with
    /// that autosave field reading YES, a `.performance` reopen came back with
    /// a 193pt sidebar and its native lights at (13.00, 13.50). `.comfortable`
    /// does force the flag true but is the traditional layout the hide
    /// condition exempts.
    ///
    /// Nothing moves them either: the floating view draws its own and forwards
    /// clicks rather than reparenting the real ones, and the only other
    /// traffic-light path in this file (`performHorizontalWindowSlide`) belongs
    /// to a Space switch, which needs two windows in a slot and cannot be a
    /// reopen.
    static let copiedTrafficLightOrigin = NSPoint(x: 13.0, y: 13.5)

    /// Moves all three lights so the leading one sits on `origin`.
    private func alignTrafficLights(to origin: NSPoint) {
        // No version test of its own, and no test for whether the buttons
        // exist beyond this guard: the caller only reaches here with an origin,
        // and an origin is exactly what made the style mask ask for buttons.
        guard let leading = standardWindowButton(.closeButton),
              let titlebar = leading.superview else { return }
        // Same convention as `trafficLightOrigin(in:)`, inverted.
        let target = NSPoint(x: origin.x,
                             y: frame.height - origin.y - leading.frame.height)
        let have = titlebar.convert(leading.frame.origin, to: nil)
        let dx = target.x - have.x
        let dy = target.y - have.y
        // One translation for all three: the 23pt pitch already matches, so
        // only the group's position is wrong.
        for kind in Self.trafficLightKinds {
            guard let button = standardWindowButton(kind) else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.minX + dx,
                                          y: button.frame.minY + dy))
        }
    }

    override var canBecomeKey: Bool { false }

    /// The third tax for being titled, and the one with teeth: AppKit's default
    /// says any window with a title bar may be the app's MAIN window, and this
    /// one is frontmost and alone on screen for the first half second of a
    /// reopen. `NSApp.mainWindow` is what menu validation, the updater's theme
    /// lookup and the alert presenter fall back to — none of which this window
    /// can answer for. Same refusal `OverlayWindowController` and the Sparkle
    /// update window already make.
    override var canBecomeMain: Bool { false }

    /// See the class comment: AppKit would otherwise pull an overhanging frame
    /// back into the work area on order-in, and the restored window — exempted
    /// from the same constraint in the fork — would then arrive somewhere else.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Gives up its shadow to the restored window that is about to be shown.
    ///
    /// Both windows are on the same rect, so their shadows fall on the same
    /// ring of desktop and would composite into one visibly heavier one — which
    /// would then LIGHTEN when this window is destroyed, exactly the visible
    /// event the z-order arrangement exists to avoid. From here the restored
    /// window's shadow is the one that belongs to the shape the user sees.
    /// Called before that window is shown, so no frame is ever composited with
    /// both.
    func yieldShadow() {
        hasShadow = false
        invalidateShadow()
    }

    /// Declares that this window belongs underneath the restored window that
    /// has come to replace it, from now until it is destroyed.
    ///
    /// This is the whole hand-off. Nothing waits for the restored window to
    /// paint, because nothing can see it paint: it is ordered in well before
    /// its first frame reaches the screen, and every state signal available
    /// fires inside that gap. Underneath it, the loading window shows through
    /// for exactly as long as there is nothing to show instead, and stops being
    /// visible the instant there is — so destroying it later
    /// (`ReopenLoadingHandoff`) is a decision the user cannot see.
    ///
    /// A standing child relationship, not a one-shot `order(.below:)`, and the
    /// name says so on purpose. This is declared inside Chromium's
    /// window-created callback, where the restored window exists but has never
    /// been ordered in, and ordering relative to a window that is not on screen
    /// is simply dropped (measured, not assumed). AppKit maintains a child
    /// ordering across every later ordering operation instead, including the
    /// parent's own show, so the restored window is above this one from its
    /// first frame with nothing left to repair. Declaring it against an unshown
    /// parent does not take this window off screen (also measured); the rect
    /// stays covered.
    ///
    /// Two further properties, both measured. This window is ordered out
    /// whenever the restored one is, which is what should happen while the
    /// restored window is the slot's active window — but it is a consequence of
    /// the relationship, not a guarantee this file is making, and the slot
    /// hard-`orderOut`s its windows from several ladders during this same span.
    /// And `close()` detaches a child by itself, so destroying this window
    /// needs no `removeChildWindow`; `unregisterWindow` and
    /// `ReopenLoadingHandoff` are the two paths that do destroy it.
    ///
    /// The relationship is to one window, and that is sound only because a
    /// reopen has at most one of these on screen: a windowless reopen's
    /// snapshot always holds exactly one entry, because `removeSlot` shrinks it
    /// on every close and the last close is the one that cannot (see T-b).
    /// Should several ever coexist, each would still be pinned under its own
    /// slot's window, which is what a shared window LEVEL could never express —
    /// and a level below normal is not the fix in any case, since it would also
    /// sink below the other application whose window is still on this rect,
    /// which is the whole thing being covered.
    func pinUnder(_ window: NSWindow) {
        window.addChildWindow(self, ordered: .below)
    }
}

/// Decides when a reopen's loading windows may be destroyed.
///
/// The loading window is not swapped for the restored window, it is left UNDER
/// it (`ReopenLoadingWindow.pinUnder`), so the awkward part of the hand-off
/// is gone by construction: from the first frame the restored window paints,
/// the loading window is covered, and every later moment to remove it looks the
/// same to the user. That leaves this type two things to get right, neither of
/// them a matter of hitting an instant:
///
/// - the moment must ARRIVE, including when the restore never reports settling
///   and when it brings no window back at all (`backstop`);
/// - it must not arrive while the restored window is still contributing no
///   pixels. Registration is not evidence of a painted window: a restored
///   window is ordered in several hundred milliseconds before its first frame
///   reaches the screen, and taking the loading window away inside that gap
///   uncovers the desktop (`revealGrace`).
///
/// Kept apart from `SpaceManager` because it is the one piece here with real
/// case analysis, and because none of the cases that matter — a restore that
/// never settles, one that settles instantly, one that brings nothing back —
/// can be produced on demand with a real reopen.
final class ReopenLoadingHandoff {
    /// Something the hand-off waits on.
    enum Fact {
        /// A restored window the user will actually see registered into one of
        /// this reopen's slots. Concealed siblings do not count: they register
        /// at alpha 0 and cover nothing.
        case restoredWindowRegistered
        /// Chromium reported every profile's restore settled — no further
        /// window is coming from this reopen.
        case restoreSettled
    }

    enum Outcome: Equatable {
        /// Keep the loading windows up and ask again after this many seconds.
        case wait(TimeInterval)
        /// Close them now.
        case tearDown
        /// Already closed; the caller has nothing to do.
        case alreadyTornDown
    }

    /// How long the loading window stays after the first restored window
    /// registers. Covers the gap between a window being ordered in and it
    /// painting, and that gap is much wider than it first looked: measured over
    /// 12 reopens of the six-Space scene it runs from 538ms to 1095ms, because
    /// the restored window's first frame is flushed either during a pause in
    /// the restore's window-creation burst or only once the burst ends. 1.5s
    /// clears the widest of those by about 400ms, which is the whole margin
    /// there is — do not shorten this without re-measuring that gap, and note
    /// that an earlier version of this comment justified it against 414ms,
    /// which was the gap on a round that caught the pause. Only ever the
    /// binding deadline on a restore that settles almost at once; on a real
    /// multi-Space reopen the settle is later still.
    static let revealGrace: TimeInterval = 1.5
    /// Hard cap from the moment the loading windows went up, for the restore
    /// that reports nothing back. Long enough never to fire on a slow but
    /// healthy reopen, short enough that a wedged one is not left covering this
    /// rect for the rest of the session.
    static let backstop: TimeInterval = 8.0

    private let startedAt: Date
    private var firstWindowAt: Date?
    private var settledAt: Date?
    private var isTornDown = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Records a fact and re-decides.
    @discardableResult
    func record(_ fact: Fact, at now: Date) -> Outcome {
        guard !isTornDown else { return .alreadyTornDown }
        switch fact {
        case .restoredWindowRegistered:
            // First one only. The grace covers the window the user is looking
            // at; the tail of sibling Space windows that keeps arriving for
            // the rest of the restore must not keep pushing it out.
            if firstWindowAt == nil { firstWindowAt = now }
        case .restoreSettled:
            if settledAt == nil { settledAt = now }
        }
        return decide(at: now)
    }

    /// Re-decides without a new fact: an armed wait elapsed, or the run has
    /// just begun and needs its first one.
    func reconsider(at now: Date) -> Outcome {
        guard !isTornDown else { return .alreadyTornDown }
        return decide(at: now)
    }

    private func decide(at now: Date) -> Outcome {
        let backstopAt = startedAt.addingTimeInterval(Self.backstop)
        if now >= backstopAt { return tearDown() }
        // Still replaying: more windows may yet arrive on these frames.
        guard let settledAt else {
            return .wait(backstopAt.timeIntervalSince(now))
        }
        // Grace from the window that has to paint before the loading window may
        // go — or, when the restore brought nothing back, from the settle
        // itself. "Nothing restored" is not "nothing is coming": the reopen
        // answers it by spawning a plain window instead
        // (`spawnPersistedSpaceWindow`), and that window needs exactly the
        // cover a restored one needs. Timing the grace from the settle keeps
        // the loading window up across the spawn; if the spawned window
        // registers inside it, the line above takes over and the grace restarts
        // from the window, which is the later and safer of the two.
        let coverAt = (firstWindowAt ?? settledAt).addingTimeInterval(Self.revealGrace)
        if now >= coverAt { return tearDown() }
        return .wait(min(coverAt, backstopAt).timeIntervalSince(now))
    }

    private func tearDown() -> Outcome {
        isTornDown = true
        return .tearDown
    }
}
