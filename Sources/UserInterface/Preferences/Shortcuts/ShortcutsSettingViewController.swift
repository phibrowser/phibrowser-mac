// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit
class ShortcutsSettingViewController: NSViewController, SettingsPane{
    var paneIdentifier: Settings.PaneIdentifier = .shortcuts
    var paneTitle: String = NSLocalizedString("settings.navigation.shortcutsTitle", value: "Shortcuts", comment: "Settings - Tab title for keyboard shortcuts settings")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingShortcutsIcon)
    let hostingController = ShortcutsSettingHostingViewController()
    
    // AppKit only synthesizes an empty view for a nib-less `loadView` on
    // macOS 14+; macOS 12/13 raise an NSNib exception instead. Panes are
    // built purely in code, so provide the view explicitly.
    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
    
}
