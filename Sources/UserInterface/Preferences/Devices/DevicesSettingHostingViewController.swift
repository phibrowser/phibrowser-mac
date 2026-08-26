import Cocoa
import SwiftUI

final class DevicesSettingHostingViewController: NSViewController {
    private let stack = SyncKeyStack.make()
    private lazy var viewModel = DevicesSettingViewModel(manager: stack.manager, approvals: stack.approvals)
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
        let vm = KeyLayerViewModel(manager: stack.manager)
        let root = KeyLayerView(viewModel: vm, onFinish: { [weak self] in
            self?.keyLayerWindow?.close()
            self?.keyLayerWindow = nil
            Task { @MainActor in await self?.viewModel.loadAll() }
        })
        let window = NSWindow(contentViewController: ThemedHostingController(rootView: root))
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("Set up sync", comment: "Key layer window title")
        window.isReleasedWhenClosed = false
        window.center()
        keyLayerWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in await vm.beginSetup() }
    }
}
