// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

final class AISettingHostingViewController: NSViewController {
    #if ATHENA_CANARY_TRIAL
    private var hostingController: ThemedHostingController<AthenaSettingsView>?
    #else
    private var hostingController: ThemedHostingController<AISettingView>?
    private let connectorViewModel = AISettingsConnectorViewModel()
    #endif

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(PhiPreferences.fixedWindowBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSwiftUIView()
    }

    private func setupSwiftUIView() {
        #if ATHENA_CANARY_TRIAL
        let hostingController = ThemedHostingController(rootView: AthenaSettingsView())
        #else
        let hostingController = ThemedHostingController(rootView: AISettingView(connectorViewModel: connectorViewModel))
        #endif

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
        #if !ATHENA_CANARY_TRIAL
        if PhiBuildCapabilities.supportsAI {
            connectorViewModel.loadConnectionsIfNeeded()
        } else {
            connectorViewModel.suspendForUnauthenticatedAccess()
        }
        #endif
    }

}
