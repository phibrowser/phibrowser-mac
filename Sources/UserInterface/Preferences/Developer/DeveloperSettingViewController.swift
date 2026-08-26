// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

/// Settings pane for developer tooling (remote debugging, the phi-browser
/// skill installer). Mirrors the host/hosting/SwiftUI split used by the other
/// panes (e.g. Spaces): this `SettingsPane` is the AppKit toolbar entry, the
/// content lives in the SwiftUI `DeveloperSettingsView` hosted by
/// `DeveloperSettingHostingViewController`.
class DeveloperSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .developer
    var paneTitle: String = NSLocalizedString("settings.navigation.developerTitle", value: "Developer", comment: "Settings - Tab title for developer tooling")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingDevIcon)
    let hostingController = DeveloperSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
