// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
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
         ShortcutsSettingViewController(),
        ]
        settingsPanesIncludeDeveloper = PhiPreferences.AgentSpaces.developerModeEnabled
        if settingsPanesIncludeDeveloper {
            panes.append(DeveloperSettingViewController())
        }
        return panes
    }

    /// Applies the General-tab "Developer mode" toggle. Off is a kill-switch,
    /// not just UI hiding: the Developer tab disappears AND the features it
    /// governs shut off — agent CDP access (listener, View-menu items,
    /// transcript panel) and the agent password manager (provider disabled,
    /// vault locked; the account stays on disk).
    ///
    /// It also revokes, not merely suspends, every standing agent permission:
    /// the allowed-agent list and all credential approvals — including the
    /// persisted "Always" ones — are erased. Nothing an agent was previously
    /// trusted with survives the switch, so turning developer mode back on
    /// starts from zero: each agent asks for browser control again, and for
    /// each credential again. That is the whole point of a kill-switch; a
    /// version that left the grants in place would silently re-arm them.
    ///
    /// SwiftUI callers must defer to the next runloop turn: the window
    /// rebuild closes the window hosting the toggle's own view.
    @MainActor
    func setDeveloperModeEnabled(_ enabled: Bool) {
        PhiPreferences.AgentSpaces.developerModeEnabled = enabled
        if !enabled {
            // Agent browser control: sever live connections, then forget every
            // agent that was ever allowed through. Idempotent when the switch
            // was already off — the grants still have to go.
            AgentCDPListener.shared.setEnabled(false)
            AgentCDPListener.shared.forgetAllGrants()

            // Agent credential access: revoke every approval outright (the
            // approvals sheet's own Revoke All), not just the timed ones.
            CredentialGrantStore.shared.revokeAll()
            if PhiPreferences.PasswordManagerSettings.bitwardenEnabled.loadValue() {
                // Mirrors the password manager card's own disable path.
                UserDefaults.standard.set(
                    false, forKey: PhiPreferences.PasswordManagerSettings.bitwardenEnabled.rawValue)
                Task { await BitwardenService.shared.lock() }
            }
        }
        developerModeDidChange()
    }

    /// Rebuilds an open settings window when its toolbar no longer matches the
    /// developer-mode gate (the pane list is fixed at window creation), staying
    /// on the General pane, where the toggle lives.
    @MainActor
    private func developerModeDidChange() {
        guard settingsWindowController != nil,
              settingsPanesIncludeDeveloper != PhiPreferences.AgentSpaces.developerModeEnabled
        else { return }
        settingsWindowController?.close()
        settingsWindowController = nil
        let controller = ensureSettingsWindowController()
        controller.show(pane: .general)
        controller.window?.orderFront(self)
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
    
    /// Shows the settings window, optionally jumping to a specific pane.
    ///
    /// `SettingsWindowController.show(pane:)` re-centers the window and then
    /// restores the autosaved frame on every call. When the window is already
    /// on screen that discards any position the user dragged it to (the frame
    /// autosave can lag behind the move), so the popup visibly jumps. Capture
    /// the current top-left before showing and put it back afterwards; the
    /// top-left anchor keeps pane-switch height changes looking native.
    @discardableResult
    func showSettings(pane paneIdentifier: Settings.PaneIdentifier? = nil) -> SettingsWindowController {
        let controller = ensureSettingsWindowController()

        let visibleTopLeft: NSPoint? = {
            guard let window = controller.window, window.isVisible else { return nil }
            return NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }()

        controller.show(pane: paneIdentifier)

        if let visibleTopLeft {
            controller.window?.setFrameTopLeftPoint(visibleTopLeft)
        }

        return controller
    }

    @MainActor
    @objc func showPreferences(_ sender: Any?) {
        let controller = showSettings()
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
