// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

final class AISettingHostingViewController: NSViewController {
    private var hostingController: ThemedHostingController<AISettingView>?
    private let connectorViewModel = AISettingsConnectorViewModel()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(PhiPreferences.fixedWindowBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSwiftUIView()
        observeOAuthConnectorReturn()
    }

    private func setupSwiftUIView() {
        let hostingController = ThemedHostingController(rootView: AISettingView(connectorViewModel: connectorViewModel))

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observeOAuthConnectorReturn() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOAuthConnectorReturn(_:)),
            name: .oauthConnectorFlowDidReturn,
            object: nil
        )
    }

    @objc private func handleOAuthConnectorReturn(_ notification: Notification) {
        guard let userInfo = notification.userInfo as? [String: String],
              let provider = userInfo["provider"],
              let result = userInfo["result"] else {
            connectorViewModel.refreshConnections()
            return
        }

        connectorViewModel.handleOAuthReturn(
            provider: provider,
            result: result,
            error: userInfo["error"]
        )
    }
}
