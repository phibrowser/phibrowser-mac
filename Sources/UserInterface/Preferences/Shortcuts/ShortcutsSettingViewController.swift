// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit
class ShortcutsSettingViewController: NSViewController, SettingsPane{
    var paneIdentifier: Settings.PaneIdentifier = .shortcuts
    var paneTitle: String = NSLocalizedString("Shortcuts", comment: "Settings - Tab title for keyboard shortcuts settings")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingShortcutsIcon)
    let hostingController = ShortcutsSettingHostingViewController()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
    
}
