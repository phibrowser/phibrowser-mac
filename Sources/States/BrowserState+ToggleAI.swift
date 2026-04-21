// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

extension BrowserState {
    func onAIEnabledChanged(_ enabled: Bool, sentinelOnLogin: Bool) {
        if enabled {
            ChromiumLauncher.sharedInstance().bridge?.enablePhiExtensions()
        } else {
            ChromiumLauncher.sharedInstance().bridge?.disablePhiExtensions(false)
        }
        if enabled {
            UserDefaults.standard.set(true, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
            updateSentinelRegistration(sentinelOnLogin)
        } else {
            UserDefaults.standard.set(false, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
            Task {
                await SentinelHelper.unregister()
            }

            SentinelHelper.terminateAll()
            closeAllAIContent()
        }
    }

    /// Only called when AI is enabled.
    func updateSentinelRegistration(_ launchOnLogin: Bool) {
        if launchOnLogin {
            SentinelHelper.register()
            SentinelHelper.launch()
            // register() may steal focus. poll up to 2s and reactivate main app if needed
            Task {
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if await !NSApp.isActive {
                        await MainActor.run { NSApp.activate() }
                        break
                    }
                }
            }
        } else {
            let running = SentinelHelper.isRunning
            Task {
                await SentinelHelper.unregister()
                if running || PhiPreferences.AISettings.phiAIEnabled.loadValue() {
                    SentinelHelper.launch()
                }
            }
        }
    }

    func closeAllAIContent() {
        for tab in tabs {
            tab.toggleAIChat(true)
        }
        aiChatCollapsed = true

        let aiTabsSnapshot = aiChatTabs
        aiChatTabs.removeAll()
        for (_, aiTab) in aiTabsSnapshot {
            aiTab.webContentWrapper?.close()
        }

        let conversationTabs = tabs.filter { tab in
            guard let url = tab.url else { return false }
            return url.hasPrefix("chrome://conversation") || url.hasPrefix("phi://conversation")
        }

        guard !conversationTabs.isEmpty else { return }

        let nonConversationCount = tabs.count - conversationTabs.count
        if nonConversationCount == 0 {
            createTab("chrome://newtab", focusAfterCreate: true)
        }

        for tab in conversationTabs {
            tab.webContentWrapper?.close()
        }
    }
}
