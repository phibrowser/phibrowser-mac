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
            guard !isPresented else { return }
            isPresented = true
            idleRounds = 0
            modalHost?.present(controller: controller)
            return
        }
        if pending, !needsPairing {
            // Nothing left to pair: this join is finished.
            pending = false
        }
        if isPresented, !needsPairingActionable {
            isPresented = false
            pending = false
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

/// The gate modal's root view: `ProfilePairingView` in its `.gate` context, plus
/// the secondary "remove this device" slot. `onRemoveDevice` is nil here (Task 12
/// supplies the action), and a nil action hides the button entirely rather than
/// showing one that does nothing.
struct ProfilePairingGateView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    let controller: SyncKeyController
    var onRemoveDevice: (() -> Void)?

    var body: some View {
        switch viewModel.phase {
        case .pairingProfiles(let locals, let remotes):
            ProfilePairingView(
                viewModel: viewModel,
                locals: locals,
                remotes: remotes,
                context: .gate,
                secondaryButton: secondaryButton,
                onSubmit: { decisions in
                    Task { await viewModel.submitPairing(decisions, controller: controller) }
                })
        case .error(let message):
            // `startPairing` lands here whenever `accountProfiles()` throws --
            // the likeliest outcome right after a join if the network drops or
            // the ARK is not up yet. This window is app modal and its only
            // automatic dismissal needs `needsPairingActionable` to go false,
            // which it will not while the account really does need pairing, so a
            // branch with no button is a browser locked behind an error string.
            statusView(message: message, retryEnabled: true)
        default:
            // `.working` while `startPairing` loads, `.done` for the moment
            // between a successful submit and the gate's dismissal. Both are
            // meant to be transient, but the same "no exit" reasoning applies if
            // one of them ever sticks, so they carry the exits too.
            statusView(message: nil, retryEnabled: viewModel.phase != .working)
        }
    }

    /// The "remove this device" slot, offered in EVERY branch: the gate is app
    /// modal, so a branch without it is a window with no exit at all. nil here
    /// this task (Task 12 supplies the action) hides the button.
    private var secondaryButton: (title: String, action: () -> Void)? {
        onRemoveDevice.map { action in
            (title: NSLocalizedString("从同步中移除本设备…",
                                      comment: "Pairing gate - remove this device"),
             action: action)
        }
    }

    /// Non-pairing phases: title, optional message, and the two exits (reload
    /// the candidates, or leave sync from this device).
    @ViewBuilder
    private func statusView(message: String?, retryEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("完成 Profile 配对", comment: "Pairing gate - title"))
                .font(.title2.bold())
            if let message {
                Text(message).font(.callout)
            } else {
                ProgressView()
            }
            HStack(spacing: 12) {
                Button(NSLocalizedString("重试", comment: "Pairing gate - retry")) {
                    Task { await viewModel.startPairing(controller: controller) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!retryEnabled)
                if let secondaryButton {
                    Button(secondaryButton.title, action: secondaryButton.action)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(32)
        .frame(minWidth: 420, alignment: .leading)
    }
}

/// Production host: a titled window WITHOUT `.closable` (the Devices pane's
/// key-layer window is `[.titled, .closable]`), at `.modalPanel` level, driven
/// through `NSApp.runModal(for:)`. The modal session is what makes the browser
/// unusable: it stops UI EVENT DELIVERY, not the main queue, so the engine's
/// main-thread hops keep running and settings sync keeps converging.
@MainActor
final class AppModalPairingHost: ProfilePairingModalHost {
    private var window: NSWindow?

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
        let viewModel = KeyLayerViewModel(manager: controller.manager)
        let root = ProfilePairingGateView(viewModel: viewModel, controller: controller)
        let window = NSWindow(contentViewController: ThemedHostingController(rootView: root))
        window.styleMask = [.titled]
        window.title = NSLocalizedString("完成 Profile 配对", comment: "Pairing gate window title")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in await viewModel.startPairing(controller: controller) }
        NSApp.runModal(for: window)
    }

    func dismiss() {
        guard let window else { return }
        NSApp.stopModal()
        window.close()
        self.window = nil
    }
}
