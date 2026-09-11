// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Seam over the app-modal window so the gate's logic is testable without AppKit.
///
/// `controller` is OPTIONAL on purpose. The gate holds its controller weakly, so
/// it really can be nil in production (the controller is dropped on sign-out /
/// self-revoke while a notification is still in flight), and the gate's own unit
/// tests drive it with no controller at all. A `fatalError` on that branch would
/// be both a crash risk in the shipping app and an instant test-process abort.
/// The production host logs and does nothing; the fake records the call.
@MainActor
protocol ProfilePairingModalHost: AnyObject {
    func present(controller: SyncKeyController?)
    func dismiss()
    /// Re-drives the load behind a modal that is ALREADY up.
    ///
    /// Without it the window got exactly one load attempt for its whole life:
    /// `present` starts one, and every later announcement returned at the
    /// `isPresented` short circuit. A load that hangs -- the device-B case this
    /// exists for -- then leaves a spinner nothing can restart but the user.
    func reloadPresented()
}

extension ProfilePairingModalHost {
    /// Defaulted so a host that has nothing to re-drive (a test double, or any
    /// future non-window host) is not forced to implement it.
    func reloadPresented() {}
}

/// The blocking, always-on-top pairing modal of the DEVICE JOIN flow, plus the
/// hysteresis safety net for the rare run-time stall.
///
/// It is presented for exactly one situation: the profiles that existed on BOTH
/// sides before this device joined, which no machine can match on its own. Every
/// profile that appears in the account afterwards is created locally, silently,
/// by §3.6 -- the modal never comes back for that.
@MainActor
final class ProfilePairingGate {
    static let shared = ProfilePairingGate()

    /// Consecutive idle refresh rounds after which the safety net presents.
    static let pairingStuckRounds = 3

    /// THE single read/write port for `sync.joinPairingPending`. Three writers --
    /// the four join terminal paths (`KeyLayerViewModel`), the pairing wrap-up,
    /// and self-revoke (which may run when no gate instance exists) -- and none
    /// of them touches `AccountUserDefaults` behind this property's back.
    static var joinPairingPending: Bool {
        get {
            if let staticPendingOverride { return staticPendingOverride }
            return AccountController.shared.account?.userDefaults.bool(forKey: defaultsKey) ?? false
        }
        set {
            if staticPendingOverride != nil { staticPendingOverride = newValue; return }
            AccountController.shared.account?.userDefaults.set(newValue, forKey: defaultsKey)
        }
    }
    private static let defaultsKey = "sync.joinPairingPending"

    /// Test seam for the STATIC port. The per-instance override below covers a
    /// gate instance; §3.6's per-round refresh reads this port with no gate in
    /// hand, and its "gate shut => one network call is not sent" case
    /// (§12.1 ⑧) has to be able to set it. Reset it in `tearDown`.
    static var staticPendingOverride: Bool?

    /// Test seam; nil in production, where the static port above is used.
    var joinPairingPendingOverride: Bool?
    var modalHost: ProfilePairingModalHost?

    private weak var controller: SyncKeyController?
    private var isPresented = false
    private var idleRounds = 0
    private var observers: [NSObjectProtocol] = []
    /// The last `(needsPairing, needsPairingActionable)` pair this gate was told
    /// about. The hysteresis safety net runs off THESE, not off
    /// `controller.needsPairingActionable`: the controller is held weakly and a
    /// gate with no controller (sign-out in flight, or a unit test) must still
    /// behave, instead of silently returning early and never presenting.
    private var lastPredicates: (needsPairing: Bool, actionable: Bool) = (false, false)

    private var pending: Bool {
        get { joinPairingPendingOverride ?? Self.joinPairingPending }
        set {
            if joinPairingPendingOverride != nil { joinPairingPendingOverride = newValue }
            else { Self.joinPairingPending = newValue }
        }
    }

    func start(controller: SyncKeyController?) {
        self.controller = controller
        guard observers.isEmpty else { return }
        // `queue: nil` on purpose: every poster of both notifications is already
        // `@MainActor`, so nil-queue delivery is synchronous on the main thread
        // (which keeps `MainActor.assumeIsolated` valid) and a caller that posts
        // and then reads the gate's state sees the effect, instead of racing an
        // operation queued for a later turn of the run loop.
        observers.append(NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let c = note.object as? SyncKeyController ?? self.controller else { return }
                // An announcement with no outcome reads as `.held`: the safe
                // direction, since `.held` is the one value that changes nothing.
                let outcome = (note.userInfo?[SyncKeyController.mappingsOutcomeKey] as? String)
                    .flatMap(SyncKeyController.MappingsOutcome.init(rawValue:)) ?? .held
                self.handleMappingsDidResolve(needsPairing: c.needsPairing,
                                              needsPairingActionable: c.needsPairingActionable,
                                              outcome: outcome)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAutoCreateDidRun(note.userInfo) }
        })
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if isPresented { modalHost?.dismiss(); isPresented = false }
    }

    /// Presentation predicate (§3.2): `joinPairingPending && needsPairingActionable`.
    /// NOT "needsPairing is true" -- after the second revision that flips true for
    /// a moment every time §3.6 creates a profile.
    ///
    /// `outcome` says what the two predicates are worth (see
    /// `SyncKeyController.MappingsOutcome`). ONLY `.measured` may retire
    /// `sync.joinPairingPending`. Retiring it on either of the others would end a
    /// join that never happened: a device joins, quits, relaunches offline, and
    /// the pre-existing profiles on both sides -- the one situation only this
    /// modal can resolve -- would never be offered again. `.cleared` (locked ARK,
    /// sign-out, teardown) takes the window down because the key layer behind it
    /// is gone; `.held` (a pass whose network call flapped) leaves the window
    /// alone, because nothing about the pairing picture changed.
    func handleMappingsDidResolve(needsPairing: Bool, needsPairingActionable: Bool,
                                  outcome: SyncKeyController.MappingsOutcome = .measured) {
        switch outcome {
        case .cleared:
            // Nothing is known about the pairing picture any more, so the
            // hysteresis net is reset too rather than left holding a stale
            // `actionable` that would present a modal against a controller that
            // has already been dropped.
            lastPredicates = (false, false)
            idleRounds = 0
            if isPresented {
                isPresented = false
                modalHost?.dismiss()
            }
            return
        case .held:
            // These predicates are the last MEASURED answer carried forward -- on
            // a fresh controller, the initial `false, false`, which measured
            // nothing at all. So: never retire `pending`, and never take a live
            // window down. Presenting is still allowed, because `actionable ==
            // true` can only have come from a real pass; that keeps a gate which
            // started between two passes from waiting for the next one.
            lastPredicates = (needsPairing, needsPairingActionable)
            if pending, needsPairingActionable, !isPresented {
                isPresented = true
                idleRounds = 0
                modalHost?.present(controller: controller)
            }
            return
        case .measured:
            break
        }
        lastPredicates = (needsPairing, needsPairingActionable)
        if pending, needsPairingActionable {
            if isPresented {
                // One modal per session (`presentCount` stays 1), but not one
                // LOAD per session: a window already up gets re-driven, so a
                // load that hung has a second chance without the user having to
                // find the retry button.
                modalHost?.reloadPresented()
                return
            }
            isPresented = true
            idleRounds = 0
            modalHost?.present(controller: controller)
            return
        }
        // Past the branch above, `pending` implies `!needsPairingActionable`, so
        // this covers both terminal shapes at once:
        //
        //  - nothing left to pair at all (`!needsPairing`): the join is finished;
        //  - something is left, but nothing the user could decide -- an account
        //    profile whose envelope will not open under this ARK. §3.2 is
        //    explicit that this class never presents a modal, so a join left
        //    pending on it can never be finished by one either.
        //
        // The second case is not hypothetical: `KeyLayerViewModel.submitPairing`
        // sets the flag unconditionally, the Devices pane included, and an
        // undecryptable remote keeps `needsPairing` true forever. Retiring only
        // on `!needsPairing` (or only while a window happened to be up) wedged
        // `sync.joinPairingPending` true for good, and with it §3.5's Space gate:
        // no Space pull, no Space publish, `ensureLocalProfilesForAccount`
        // skipped every round, and no UI anywhere to say why.
        if pending, !needsPairingActionable {
            pending = false
        }
        if isPresented, !needsPairingActionable {
            isPresented = false
            modalHost?.dismiss()
        }
    }

    /// Hysteresis (§3.2). Counted on THIS notification only: a refresh round is
    /// not the same thing as a `resolveMappings()` pass, and one round may drive
    /// zero or several passes.
    func handleAutoCreateDidRun(_ userInfo: [AnyHashable: Any]?) {
        let outcome = userInfo?["outcome"] as? String ?? ""
        let created = userInfo?["created"] as? Int ?? 0
        let skipped = userInfo?["skippedUuids"] as? Int ?? 0
        // ANY progress resets: a round that created its throttled maximum while
        // the account still has more is converging, not stuck. A skipped uuid
        // means work is still outstanding, so it does not count either.
        guard outcome == "unchanged", created == 0, skipped == 0 else {
            idleRounds = 0
            return
        }
        idleRounds += 1
        // Driven by the predicates the last `.phiProfileMappingsDidResolve`
        // carried, NOT by `controller?.needsPairingActionable`: `guard let
        // controller` here would make the whole safety net dead code whenever
        // the controller has been released -- and dead in every unit test.
        guard idleRounds >= Self.pairingStuckRounds,
              lastPredicates.actionable, !isPresented else { return }
        AppLogWarn("[phi-sync] profile pairing appears stuck after \(idleRounds) idle rounds; presenting the gate")
        pending = true
        handleMappingsDidResolve(needsPairing: lastPredicates.needsPairing,
                                 needsPairingActionable: true)
    }
}

/// Production host: a titled window WITHOUT `.closable` (the Devices pane's
/// key-layer window is `[.titled, .closable]`), at `.modalPanel` level, driven
/// through `NSApp.runModal(for:)`. The modal session is what makes the browser
/// unusable: it stops UI EVENT DELIVERY, not the main queue, so the engine's
/// main-thread hops keep running and settings sync keeps converging.
///
/// THE INVARIANT THAT PROMISE RESTS ON: a nested modal run loop must be entered
/// from a RUN-LOOP-NATIVE callout -- `RunLoop.main.perform(inModes:)`, i.e.
/// `CFRunLoopPerformBlock` -- and NEVER from inside a main-actor task or a
/// `DispatchQueue.main.async` block.
///
/// The main dispatch queue is serial and non-reentrant. A nested run loop
/// started from inside one of its blocks does not drain that queue again while
/// the outer block is still on the stack, so every main-actor continuation the
/// modal depends on -- its own load finishing, the engine's `@MainActor` hops,
/// any `Task.sleep` deadline -- is starved until `runModal` returns, and
/// `runModal` is waiting on exactly those continuations. That is a deadlock,
/// and it is what device B hit: `sample` caught the main thread in
/// `completeTaskWithClosure` -> `-[NSApplication runModalForWindow:]` ->
/// `nextEventMatchingMask` -> `mach_msg`, with the log silent from the moment
/// the window appeared. Deferring to "the next main-actor turn" does not help:
/// the next turn is another main-queue block.
///
/// Entered from the run loop itself, the main queue is idle when the nested
/// loop starts, so the loop drains it and §3.2's "the engine keeps running
/// while the modal is up" (pinned by §12.2 step 1) is true again.
@MainActor
final class AppModalPairingHost: ProfilePairingModalHost {
    /// Run-loop modes the modal session may be ENTERED in.
    ///
    /// The same set, for the same reason, as `KeyLayerView.finishDeliveryModes`:
    ///
    ///  * `.eventTracking` is deliberately absent. Entering `runModal` from
    ///    inside an AppKit mouse-tracking loop parks that loop underneath the
    ///    modal for the modal's whole user-bounded life, and the mouse-up that
    ///    would have ended tracking goes to the modal session instead -- the
    ///    T17 step 0 hang, one step worse.
    ///  * `.modalPanel` is deliberately present: `present` is reachable while
    ///    the Devices pane's key-layer window already has the run loop spinning
    ///    there, and a `.default`-only block would then wait for that window to
    ///    go away before the gate could ever open.
    ///  * `.common` is not used: it would pull `.eventTracking` back in.
    static let presentationModes: [RunLoop.Mode] = [.default, .modalPanel]

    /// Hands a block to the run loop. Injected so a test can assert that the
    /// session is SCHEDULED rather than entered on the caller's stack -- the
    /// one property this whole class exists to get right.
    private let scheduler: @MainActor (@escaping () -> Void) -> Void
    /// `NSApp.runModal(for:)` and `NSApp.stopModal()` in production; inert
    /// closures in tests, which must never park the test process in a modal
    /// loop nothing is left to stop.
    private let runModal: @MainActor (NSWindow) -> Void
    private let stopModal: @MainActor () -> Void
    /// The wizard view model's three external dependencies, injected here so
    /// `present()` never reaches for a singleton itself (see `init`).
    private let previewAccountSpaces: () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>
    private let pairableLocalSpaces: () -> [PhiLocalSpace]
    private let themeDisplayName: (String) -> String?

    /// True for exactly as long as THIS host's `runModal` call is on the stack.
    ///
    /// `NSApp.stopModal()` is process-wide: it ends whatever modal session is
    /// running, which need not be ours. Between `present` and the run loop's
    /// callout there is no session of ours at all, so a `dismiss()` landing in
    /// that window must not call it.
    private var sessionActive = false

    private var window: NSWindow?
    /// The live modal's view model and the controller it was presented for, so
    /// `reloadPresented()` has both halves of `start(controller:)`.
    ///
    /// Weak on purpose, and safe for as long as the window is up: the view model
    /// is retained by `PairingWizardView`'s `@StateObject` inside the hosting
    /// controller `window` holds (`StateObject(wrappedValue:)` captures it
    /// strongly in the root view), and the controller is owned by the key layer
    /// (the gate itself only holds it weakly). Both are cleared in `dismiss()`
    /// alongside `window`.
    ///
    /// The setter stays private -- `present()` and `dismiss()` are still its
    /// only two writers, and `private(set)` is what makes the compiler say so --
    /// but the getter is internal so a test can drive the wizard the user drives
    /// (§10.7 case 1 presses Continue for real).
    private(set) weak var viewModel: PairingWizardViewModel?
    private weak var presentedController: SyncKeyController?

    /// Every seam carries its production default, so `AppModalPairingHost()`
    /// stays the one call the app makes (`PhiChromiumCoordinator`).
    ///
    /// 后三条是 M3-2b 新加的：向导 VM 的三条外部依赖。放在这里而不是
    /// `present()` 体内，`ProfilePairingGateTests` 才不会在 `present()` 时把
    /// `PhiChromiumCoordinator.shared` 与它背后的 `AccountController.shared` 拉起来
    /// ——那正是向导 VM 收注入闭包想避免的耦合，直接写在 `present()` 里等于把单例
    /// 从 VM 搬进了宿主。
    init(scheduler: @escaping @MainActor (@escaping () -> Void) -> Void = { block in
             RunLoop.main.perform(inModes: AppModalPairingHost.presentationModes) { block() }
         },
         runModal: @escaping @MainActor (NSWindow) -> Void = { NSApp.runModal(for: $0) },
         stopModal: @escaping @MainActor () -> Void = { NSApp.stopModal() },
         previewAccountSpaces: @escaping () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>
             = { await PhiChromiumCoordinator.shared.previewAccountSpaces() },
         // 非隔离闭包：`themeDisplayName` 要原样传给纯函数 `SpaceOverwriteDiff.diffs`
         // （一个 `@MainActor` 闭包无法转换过去），两条都只会被 `@MainActor` 的向导 VM
         // 调用，所以 `assumeIsolated` 成立。
         pairableLocalSpaces: @escaping () -> [PhiLocalSpace]
             = { MainActor.assumeIsolated { PhiChromiumCoordinator.shared.pairableLocalSpaces() } },
         themeDisplayName: @escaping (String) -> String?
             = { id in MainActor.assumeIsolated { ThemeManager.shared.registeredThemes[id]?.name } }) {
        self.scheduler = scheduler
        self.runModal = runModal
        self.stopModal = stopModal
        self.previewAccountSpaces = previewAccountSpaces
        self.pairableLocalSpaces = pairableLocalSpaces
        self.themeDisplayName = themeDisplayName
    }

    func present(controller: SyncKeyController?) {
        // No controller means the key layer has already been torn down (sign-out
        // or self-revoke, with a notification still in flight). There is nothing
        // to pair against, so blocking the browser would be strictly worse than
        // doing nothing; the next `.phiProfileMappingsDidResolve` from a fresh
        // controller presents properly.
        guard let controller else {
            AppLogWarn("[phi-sync] pairing gate asked to present with no key controller; ignoring")
            return
        }
        guard window == nil else { return }
        let viewModel = PairingWizardViewModel(
            keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: previewAccountSpaces,
            pairableLocalSpaces: pairableLocalSpaces,
            themeDisplayName: themeDisplayName)
        let root = PairingWizardView(viewModel: viewModel, controller: controller,
                                     onDismiss: { [weak self] in self?.dismiss() })
        let window = NSWindow(contentViewController: ThemedHostingController(rootView: root))
        // 仍然没有 `.closable`（与今天的理由一致）；`.resizable` 是新的：可放大、
        // 不可缩到 720×560 以下。
        window.styleMask = [.titled, .resizable]
        window.title = NSLocalizedString("Finish setting up sync",
                                         comment: "Pairing wizard - window title")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 560))
        window.contentMinSize = NSSize(width: 720, height: 560)
        window.center()
        self.window = window
        self.viewModel = viewModel
        self.presentedController = controller
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in await viewModel.start(controller: controller) }
        // ONLY the modal session is deferred; everything above stays
        // synchronous. `dismiss()`, `reloadPresented()` and the `window == nil`
        // re-entrancy guard all read state this method just wrote, so deferring
        // the window build too would let a `dismiss()` arriving in between
        // return early and leave the session to open an app-modal window with
        // nothing alive to close it.
        //
        // `NSApp.runModal(for:)` does not return until `stopModal()`, i.e. until
        // the user finishes pairing or removes this device. The hysteresis safety
        // net reaches here from INSIDE an engine round: `PhiSyncEngine.pull()`
        // awaits `refreshAccountProfiles()` -> `SyncKeyController.finishRefresh`,
        // which posts `.phiProfileAutoCreateDidRun` synchronously, and the gate
        // observes that notification with `queue: nil`. So this line runs on a
        // main-actor stack, i.e. inside a main-queue block -- and a nested run
        // loop entered from there never drains that queue again (see the class
        // comment). `scheduler` hands the session to the run loop itself
        // instead, which runs it once the poster's block has returned and the
        // main queue is idle; the nested loop then drains the queue, so the
        // round's suspended continuation, the load's own continuations and the
        // engine's later hops all resume WHILE the window is up.
        //
        // The identity check makes a `dismiss()` that lands before the callout
        // a no-op rather than a session started after its own dismissal.
        scheduler { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.window === window else { return }
                // Metadata only (R12). If the "ends" line never follows on a
                // device that closed the modal, the main actor was starved
                // under the session and this invariant has been broken again.
                AppLogInfo("[phi-sync] pairing modal session begins")
                self.sessionActive = true
                self.runModal(window)
                self.sessionActive = false
                AppLogInfo("[phi-sync] pairing modal session ends")
            }
        }
    }

    /// 一个 re-drive 是对**卡住的加载**的救援，不是刷新（R-D6-11）。
    ///
    /// **只有 `.loading` 与 `.error(_, .reload)` 允许**；四个交互态
    /// （`.profiles` / `.spaces` / `.confirmOverwrite` / `.submitting`）与 `.done`
    /// 一律拒绝——gate 每一趟 `.measured` 都会对已呈现的模态调 `reloadPresented()`，
    /// 大约一分钟一次。两处相对 `KeyLayerPhase` 时代新加的拒绝，理由各不相同：
    ///  - **`.confirmOverwrite`**：确认页是交互态，一次重驱会把用户正在读的那页差异
    ///    连同他的选择一起冲掉；
    ///  - **`.error(_, .backToSpaces)`**：Space 侧应用失败停下来的那个 `.error`，
    ///    背后是一份用户已经做完的第 2 步选择。`.error` 整类允许重驱是
    ///    `KeyLayerPhase` 时代的口径（那时 `.error` 只可能是一次加载失败），在向导里
    ///    照抄就会每分钟重跑一次 `start()`，把 `spacesInput` 与第 2 步的指派一起冲掉。
    static func reloadAllowed(for phase: PairingWizardPhase) -> Bool {
        switch phase {
        case .loading: return true
        case .error(_, let resume): return resume == .reload
        case .profiles, .spaces, .confirmOverwrite, .submitting, .done: return false
        }
    }

    /// Restarts the load behind the window that is already up. `start()` (and
    /// the `startPairing` underneath it) cancels whatever is still in flight and
    /// replaces it, so this cannot pile loads on top of one another however
    /// often the gate calls it.
    func reloadPresented() {
        guard let viewModel, let presentedController else { return }
        guard Self.reloadAllowed(for: viewModel.phase) else {
            // Metadata only (R12).
            AppLogInfo("[phi-sync] pairing modal re-drive skipped; the user is choosing pairings")
            return
        }
        Task { @MainActor in await viewModel.start(controller: presentedController) }
    }

    func dismiss() {
        guard let window else { return }
        // `window` is cleared first, so a session that has been scheduled but
        // not yet entered bails on the identity check in `present`.
        self.window = nil
        self.viewModel = nil
        self.presentedController = nil
        // And `sessionActive` is what keeps a dismissal that arrives BEFORE the
        // run loop's callout from calling a process-wide `stopModal()` that
        // would end some other component's modal session instead of ours.
        if sessionActive {
            sessionActive = false
            stopModal()
        }
        window.close()
    }
}
