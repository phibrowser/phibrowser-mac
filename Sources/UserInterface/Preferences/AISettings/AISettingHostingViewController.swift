// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

final class AISettingHostingViewController: NSViewController {
    private var hostingController: NSHostingController<AISettingView>?
    private let connectorViewModel = AISettingsConnectorViewModel()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.windowBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSwiftUIView()
    }

    private func setupSwiftUIView() {
        let aiSettingView = AISettingView(connectorViewModel: connectorViewModel)
        let hostingController = NSHostingController(rootView: aiSettingView)

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hostingController)
        view.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        self.hostingController = hostingController
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        hostingController?.view.needsLayout = true
        connectorViewModel.loadConnectionsIfNeeded()
    }
}
