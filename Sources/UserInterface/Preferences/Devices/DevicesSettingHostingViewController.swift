import Cocoa
import SwiftUI

final class DevicesSettingHostingViewController: NSViewController, NSWindowDelegate {
    /// The app-scoped shared controller (built via `PhiChromiumCoordinator`, same
    /// instance the bridge pulls sync info from); nil only in the signed-out empty
    /// state, since there is no account for the coordinator to build one against.
    /// Kept around (not just its manager/approvals) so pairing entry points
    /// (`needsPairing`, `startPairing(controller:)`) have something to call.
    ///
    /// Resolved on every access rather than captured once: the coordinator
    /// drops and rebuilds this controller across sign-out / sign-in, so a pane
    /// that was opened while signed out must pick up the real controller once
    /// an account exists instead of staying pinned to nil.
    private var syncKeyController: SyncKeyController? {
        PhiChromiumCoordinator.shared.syncKeyControllerCreatingIfNeeded()
    }
    /// Signed-out fallback stack. Created at most once per pane so the pane's
    /// view model and its key-layer window keep talking to the same
    /// `AccountKeyManager` (the unlocked ARK lives in that instance).
    private var fallbackSyncStack: (manager: AccountKeyManager, approvals: DeviceApprovalService)?
    /// Manager/approvals for the pane's own unlock + approval flow — from the
    /// shared controller when one exists, otherwise the pane-local fallback.
    private var syncStack: (manager: AccountKeyManager, approvals: DeviceApprovalService) {
        if let shared = syncKeyController {
            return (shared.manager, shared.approvals)
        }
        if let fallbackSyncStack { return fallbackSyncStack }
        let stack = SyncKeyStack.make(accountId: AccountController.shared.account?.userID)
        let made = (manager: stack.manager, approvals: stack.approvals)
        fallbackSyncStack = made
        return made
    }
    private lazy var viewModel = DevicesSettingViewModel(manager: syncStack.manager, approvals: syncStack.approvals)
    /// Rebuilt alongside `viewModel` whenever the pane rebinds, so a removal
    /// state left over from a previous account never shows up under a new one.
    private lazy var removeModel = makeRemoveDeviceModel()
    /// The `AccountKeyManager` the current `viewModel` was built against, used
    /// to detect that the pane is showing a stack from a previous account.
    private weak var boundManager: AccountKeyManager?
    private var hostingController: ThemedHostingController<DevicesSettingView>?
    private var keyLayerWindow: NSWindow?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(PhiPreferences.fixedWindowBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHostingController()
    }

    /// Rebinds the pane when the account changed underneath it. `viewModel`
    /// captures an `AccountKeyManager` at construction, so a pane first laid
    /// out while signed out stays bound to the fallback stack even after the
    /// coordinator builds the real one. Comparing manager identity keeps this
    /// a no-op in the common case (same account, pane merely re-shown).
    override func viewWillAppear() {
        super.viewWillAppear()
        guard boundManager !== syncStack.manager else { return }
        let stale = viewModel
        Task { @MainActor in await stale.stopPolling() }
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
        viewModel = DevicesSettingViewModel(manager: syncStack.manager, approvals: syncStack.approvals)
        removeModel = makeRemoveDeviceModel()
        installHostingController()
        Task { @MainActor in await viewModel.loadAll() }
    }

    /// The runtime "remove this device from sync" entry point.
    ///
    /// The teardown is bound to the coordinator-owned `syncKeyController` and to
    /// nothing else: that is the only instance with `retirePhiSync` /
    /// `deviceKeyRotator` / `engineDefaults` / `spaceStateStore` injected, so a
    /// removal run on any other one would revoke this device server-side and then
    /// leave the engine running, the device key unrotated and the Space cursors
    /// in place. The pane's `fallbackSyncStack` cannot be reached from here by
    /// construction — `SyncKeyStack.make(accountId:)` yields a
    /// `(manager, approvals)` pair, never a controller — and that fallback only
    /// exists while signed out, where `unlockState` is `.notSignedIn` and the
    /// button is not rendered at all.
    private func makeRemoveDeviceModel() -> DevicesRemoveDeviceModel {
        DevicesRemoveDeviceModel(remove: { [weak self] in
            guard let controller = self?.syncKeyController else {
                // All but unreachable while the button is on screen (unlocked
                // implies an account, and the coordinator builds a controller for
                // any account) — but a sign-out in another window can empty it
                // under a pane still showing a stale `.unlocked`. Throwing keeps
                // the model out of `.done`: a removal that never reached the
                // server must not be reported as one that did.
                AppLogWarn("[phi-sync] remove this device: no shared sync key controller")
                throw DevicesRemoveDeviceError.syncControllerUnavailable
            }
            try await controller.removeThisDeviceFromSync()
        }, onRemoved: { [weak self] in
            // `unlockState` lives on `DevicesSettingViewModel` and only moves when
            // `loadAll()` runs, so the pane is refreshed by hand here: the poll is
            // stopped first (it would otherwise keep asking the account this
            // device just left for pending approvals), then the reload drops the
            // pane to `.needsJoin` and "Set up sync on this device" comes back.
            await self?.viewModel.stopPolling()
            await self?.viewModel.loadAll()
        })
    }

    private func installHostingController() {
        boundManager = syncStack.manager
        let host = ThemedHostingController(rootView: DevicesSettingView(viewModel: viewModel,
            removeModel: removeModel,
            onJoinThisDevice: { [weak self] in self?.presentKeyLayer() },
            onResolvePairing: { [weak self] in self?.presentKeyLayer(startPairing: true) },
            needsPairingCheck: { [weak self] in self?.syncKeyController?.needsPairing ?? false }))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.hostingController = host
    }

    /// Opens the key-layer window. `startPairing` routes the entry reason: normal
    /// (false) drives `beginSetup()` as before; pairing (true, from the Devices
    /// pane's "needs pairing" banner) drives `startPairing(controller:)` instead,
    /// landing directly on `.pairingProfiles`. The shared controller is always
    /// handed to `KeyLayerView` (when one exists) so that phase can apply
    /// decisions regardless of which entry point reached it.
    private func presentKeyLayer(startPairing: Bool = false) {
        if let existing = keyLayerWindow { existing.makeKeyAndOrderFront(nil); return }
        let vm = KeyLayerViewModel(manager: syncStack.manager)
        let root = KeyLayerView(viewModel: vm, controller: syncKeyController, onFinish: { [weak self] in
            self?.keyLayerWindow?.close()
            self?.keyLayerWindow = nil
            Task { @MainActor in await self?.viewModel.loadAll() }
        })
        let window = NSWindow(contentViewController: ThemedHostingController(rootView: root))
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("Set up sync", comment: "Key layer window title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        keyLayerWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            if startPairing, let controller = syncKeyController {
                await vm.startPairing(controller: controller)
            } else {
                await vm.beginSetup(controller: syncKeyController)
            }
        }
    }

    func windowWillClose(_ notification: Notification) { keyLayerWindow = nil }
}
