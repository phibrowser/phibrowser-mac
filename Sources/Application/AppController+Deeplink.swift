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
            switch section {
            case .account:
                showSettings(pane: .account)
            case .aisetting:
                showSettings(pane: .aisettings)
            case .general:
                showSettings(pane: .general)
            case .imchannels:
                showSettings(pane: .aisettings)
            case .shortcus:
                showSettings(pane: .shortcuts)
            case .profiles:
                showSettings(pane: .profiles)
            }
        }
    }
}
