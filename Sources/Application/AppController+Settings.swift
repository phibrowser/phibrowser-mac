// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import Settings

/// Tracks the context from which the Settings window was last presented so
/// individual panes can adapt their UI (e.g. hide app-wide preferences when
/// invoked from an incognito window).
@MainActor
final class SettingsPresentationState: ObservableObject {
    static let shared = SettingsPresentationState()

    @Published var openedFromIncognito: Bool = false

    private init() {}
}

extension AppController {
    
    private func panes() -> [SettingsPane] {
        var panes: [SettingsPane] =
        [AccountSettingViewController(),
         GeneralSettingViewController(),
         ProfilesSettingViewController(),
         SpacesSettingViewController(),
         AISettingsViewController(),
         IMChannelsSettingViewController(),
         DevicesSettingViewController(),
         ShortcutsSettingViewController(),
        ]
        if PhiPreferences.AgentSpaces.skillFeatureEnabled {
            panes.append(DeveloperSettingViewController())
        }
        return panes
    }
    
    /// Returns the shared settings window controller, creating it on first access.
    /// Refreshes the presentation context (e.g. incognito source) on every call so
    /// individual panes see the right state regardless of which entry point was used.
    @discardableResult
    func ensureSettingsWindowController() -> SettingsWindowController {
        refreshSettingsPresentationState()

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

    private func refreshSettingsPresentationState() {
        Task { @MainActor in
            let isIncognito = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.isIncognito ?? false
            SettingsPresentationState.shared.openedFromIncognito = isIncognito
        }
    }
    
    @MainActor
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
