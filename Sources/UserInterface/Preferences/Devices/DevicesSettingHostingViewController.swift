import Cocoa
import SwiftUI

final class DevicesSettingHostingViewController: NSViewController, NSWindowDelegate {
    /// Shares the app-scoped controller's manager/approvals once an account
    /// exists (built via `PhiChromiumCoordinator`, same instance the bridge
    /// pulls sync info from); falls back to a pane-local stack only for the
    /// signed-out empty state, since there is no account for the coordinator
    /// to build a shared controller against.
    private lazy var syncStack: (manager: AccountKeyManager, approvals: DeviceApprovalService) = {
        if let shared = PhiChromiumCoordinator.shared.syncKeyControllerCreatingIfNeeded() {
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
            onJoinThisDevice: { [weak self] in self?.presentKeyLayer() }))
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

    private func presentKeyLayer() {
        if let existing = keyLayerWindow { existing.makeKeyAndOrderFront(nil); return }
        let vm = KeyLayerViewModel(manager: syncStack.manager)
        let root = KeyLayerView(viewModel: vm, onFinish: { [weak self] in
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
        Task { @MainActor in await vm.beginSetup() }
    }

    func windowWillClose(_ notification: Notification) { keyLayerWindow = nil }
}
