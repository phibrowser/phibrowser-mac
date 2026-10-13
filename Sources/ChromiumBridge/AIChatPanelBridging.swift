// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The two bridge calls `BrowserState` makes for the AI Chat panel, so tests
/// can observe them without the Chromium bridge (absent in the test process).
protocol AIChatPanelBridging {
    /// Hands Chromium the panel record of the page tab `tabId` to keep for
    /// undo close; nil clears it.
    func setAIChatPanelRecord(_ record: String?, forTabId tabId: Int)
    /// Opens a panel tab at `url` in the window `windowId`, bound to its page
    /// tab by `customGuid`, without focusing it.
    func createAIChatPanelTab(url: String, customGuid: String, windowId: Int)
}

/// Forwards to the live Chromium bridge. A record push to a framework that
/// predates `setAIChatPanelRecord` is dropped (header/framework skew).
struct LiveAIChatPanelBridge: AIChatPanelBridging {
    func setAIChatPanelRecord(_ record: String?, forTabId tabId: Int) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setAIChatPanelRecord(_:forTabId:))) else {
            return
        }
        bridge.setAIChatPanelRecord(record, forTabId: Int64(tabId))
    }

    func createAIChatPanelTab(url: String, customGuid: String, windowId: Int) {
        ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: url,
                                                               windowId: Int64(windowId),
                                                               customGuid: customGuid,
                                                               focusAfterCreate: false)
    }
}
