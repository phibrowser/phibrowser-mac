// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

class AdvancedSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .advanced
    var paneTitle: String = NSLocalizedString("settings.navigation.advancedTitle", value: "Advanced", comment: "Settings - Tab title for advanced settings")
    var toolbarItemIcon: NSImage = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()

    let hostingController = AdvancedSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
