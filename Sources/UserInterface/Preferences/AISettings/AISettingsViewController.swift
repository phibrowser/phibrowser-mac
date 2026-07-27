// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Settings

class AISettingsViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.aisettings
    var paneTitle: String = NSLocalizedString("settings.navigation.aiTitle", value: "Phi & AI", comment: "Settings - Tab title for AI and Phi assistant settings")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingPhiIcon)

    let hostingController = AISettingHostingViewController()

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

extension Notification.Name {
    static let browserMemorySwitchDidChange = Notification.Name("browserMemorySwitchDidChange")
}
