// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

class IMChannelsSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.imchannels
    var paneTitle: String = NSLocalizedString("Phi Link", comment: "Settings - Tab title for Phi Link settings")
    var toolbarItemIcon: NSImage = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Phi Link") ?? NSImage()

    let hostingController = IMChannelsSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
