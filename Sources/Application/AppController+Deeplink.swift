// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
extension AppController {
    func handleOpenPage(_ page: DeeplinkHandler.PageRootParam) {
        switch page {
        case .settings(let section):
            guard let section else { return }
            let controller = ensureSettingsWindowController()
            switch section {
            case .account:
                controller.show(pane: .account)
            case .aisetting:
                controller.show(pane: .aisettings)
            case .general:
                controller.show(pane: .general)
            case .imchannels:
                controller.show(pane: .imchannels)
            case .shortcus:
                controller.show(pane: .shortcuts)
            }
        }
    }
}
