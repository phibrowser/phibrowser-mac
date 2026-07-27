// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

class IMChannelsSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.imchannels
    var paneTitle: String = NSLocalizedString("settings.navigation.phiLinkTitle", value: "Phi Link", comment: "Settings - Tab title for Phi Link settings")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingLinkIcon)

    let hostingController = IMChannelsSettingHostingViewController()

    // AppKit only synthesizes an empty view for a nib-less `loadView` on
    // macOS 14+; macOS 12/13 raise an NSNib exception instead. Panes are
    // built purely in code, so provide the view explicitly.
    override func loadView() {
        view = NSView()
    }

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
