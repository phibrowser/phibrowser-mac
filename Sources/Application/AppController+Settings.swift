// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Settings
extension AppController {
    
    private func panes() -> [SettingsPane] {
        [AccountSettingViewController(),
         GeneralSettingViewController(),
         AISettingsViewController(),
         IMChannelsSettingViewController(),
         ShortcutsSettingViewController(),
        ]
    }
    
    /// Returns the shared settings window controller, creating it on first access.
    @discardableResult
    func ensureSettingsWindowController() -> SettingsWindowController {
        if let existingController = settingsWindowController {
            return existingController
        }
        
        let controller = SettingsWindowController(panes: panes(),
                                                  style: .toolbarItems,
                                                  animated: false,
                                                  hidesToolbarForSingleItem: false)
        settingsWindowController = controller
        
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingsWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        
        return controller
    }
    
    @objc func showPreferences(_ sender: Any?) {
        let controller = ensureSettingsWindowController()
        controller.show()
        controller.window?.orderFront(self)
    }
    
    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindowController?.window else {
            return
        }
        
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: closingWindow
        )
        
        settingsWindowController = nil
    }
    
}
