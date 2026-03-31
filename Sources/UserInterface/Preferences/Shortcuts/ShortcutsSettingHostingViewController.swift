// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI
final class ShortcutsSettingHostingViewController: NSViewController {
    private var hostingController: NSHostingController<ShortcutsSettingsView>?
    
    override func loadView() {
        view = NSView()
//        if #unavailable(macOS 26, ) {
            view.wantsLayer = true
            view.phiLayer?.setBackgroundColor(.windowBackground)
//        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSwiftUIView()
    }
    
    private func setupSwiftUIView() {
        let shortcutsView = ShortcutsSettingsView()
        let hostingController = NSHostingController(rootView: shortcutsView)
        
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
        // Force a layout pass once the window becomes visible.
        hostingController?.view.needsLayout = true
    }
}
