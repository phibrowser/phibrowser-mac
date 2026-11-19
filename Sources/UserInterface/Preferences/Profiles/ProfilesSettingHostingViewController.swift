// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

final class ProfilesSettingHostingViewController: NSViewController {
    private var hostingController: ThemedHostingController<ProfilesSettingsView>?
    private let listFocus = SettingsListFocus()

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
        let hostingController = ThemedHostingController(rootView: ProfilesSettingsView(listFocus: listFocus))

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let hostingView = hostingController?.view else { return }
        listFocus.paneDidAppear(in: hostingView)
    }
}
