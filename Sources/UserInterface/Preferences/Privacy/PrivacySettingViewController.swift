// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

class PrivacySettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .privacy
    var paneTitle: String = NSLocalizedString("settings.navigation.privacy", value: "Privacy", comment: "Settings - Tab title for the privacy pane")
    var toolbarItemIcon: NSImage = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: nil) ?? NSImage()

    let hostingController = PrivacySettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
