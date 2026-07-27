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
    // The sibling tabs use 32×32 template PDF assets whose drawn glyphs
    // occupy only 14–18pt of that canvas. A symbol's pointSize is a FONT
    // size, not a glyph size — the hammer's ink comes out ~25% larger than
    // the pointSize — so 13pt is what actually lands in the siblings'
    // 14–18pt ink range (measured: 16.5×15.5). Draw it centered into the
    // same 32×32 template canvas to match their size and tinting.
    var toolbarItemIcon: NSImage = {
        guard let symbol = NSImage(systemSymbolName: "hammer",
                                   accessibilityDescription: "developer")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else {
            return NSImage()
        }
        let canvas = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2,
                                   y: (rect.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        canvas.isTemplate = true
        return canvas
    }()
    let hostingController = DeveloperSettingHostingViewController()

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
