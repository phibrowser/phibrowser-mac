// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

/// Settings pane for link-opening behavior. It hosts the Kiosk, Peek, and URL
/// Rules controls that apply across Spaces.
class NavigationsSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .navigations
    var paneTitle: String = NSLocalizedString("settings.navigation.navigationsTitle",
                                              value: "Navigation",
                                              comment: "Settings - Tab title for link-opening behavior")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingLinkIcon)
    let hostingController = NavigationsSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
