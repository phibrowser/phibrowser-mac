// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

class GeneralSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .general
    var paneTitle: String = NSLocalizedString("General", comment: "Settings - Tab title for general settings")
//    var toolbarItemIcon: NSImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "general") ?? NSImage()
    var toolbarItemIcon: NSImage = NSImage(resource: .settingGeneralIcon)
    
    let hostingController = GeneralSettingHostingViewController()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
