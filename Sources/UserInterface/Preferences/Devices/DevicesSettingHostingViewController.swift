import Cocoa
import SwiftUI

final class DevicesSettingHostingViewController: NSViewController, NSWindowDelegate {
    /// The app-scoped shared controller (built via `PhiChromiumCoordinator`, same
    /// instance the bridge pulls sync info from); nil only in the signed-out empty
    /// state, since there is no account for the coordinator to build one against.
    /// Kept around (not just its manager/approvals) so pairing entry points
    /// (`needsPairing`, `startPairing(controller:)`) have something to call.
    private lazy var syncKeyController: SyncKeyController? =
        PhiChromiumCoordinator.shared.syncKeyControllerCreatingIfNeeded()
    /// Manager/approvals for the pane's own unlock + approval flow — from the
    /// shared controller when one exists, otherwise a pane-local fallback stack.
    private lazy var syncStack: (manager: AccountKeyManager, approvals: DeviceApprovalService) = {
        if let shared = syncKeyController {
            return (shared.manager, shared.approvals)
        }
        let stack = SyncKeyStack.make()
        return (stack.manager, stack.approvals)
    }()
    private lazy var viewModel = DevicesSettingViewModel(manager: syncStack.manager, approvals: syncStack.approvals)
    private var hostingController: ThemedHostingController<DevicesSettingView>?
    private var keyLayerWindow: NSWindow?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(PhiPreferences.fixedWindowBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = ThemedHostingController(rootView: DevicesSettingView(viewModel: viewModel,
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
                await vm.beginSetup()
            }
        }
    }

    func windowWillClose(_ notification: Notification) { keyLayerWindow = nil }
}
