// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Native owner for Chromium browsers carrying the Kiosk semantic type.
final class KioskBrowserWindowController: MainBrowserWindowController {
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    init(window: NSWindow,
         windowId: Int,
         browserType: ChromiumBrowserType,
         profileId: String,
         account: Account = AccountController.shared.account
            ?? AccountController.defaultAccount) {
        let state = KioskBrowserState(
            windowId: windowId,
            localStore: account.localStorage,
            profileId: profileId,
            isIncognito: browserType == .kioskIncognito
        )
        super.init(
            window: window,
            windowId: windowId,
            browserType: browserType,
            profileId: profileId,
            spaceId: LocalStore.defaultSpaceId,
            account: account,
            slot: nil,
            browserState: state
        )
        configureKioskWindow(window)
    }

    @MainActor
    func handleCommand(_ command: CommandWrapper) -> Bool {
        switch command {
        case .IDC_BACK:
            browserState.focusingTab?.goBack()
            return true
        case .IDC_FORWARD:
            browserState.focusingTab?.goForward()
            return true
        case .IDC_RELOAD:
            browserState.focusingTab?.reload()
            return true
        case .IDC_RELOAD_BYPASSING_CACHE:
            browserState.focusingTab?.reloadBypassingCache()
            return true
        case .IDC_STOP:
            browserState.focusingTab?.stopLoading()
            return true
        case .IDC_FOCUS_LOCATION:
            focusAddressBar(clearContents: false)
            return true
        case .IDC_NEW_TAB, .IDC_NEW_TAB_TO_RIGHT, .IDC_FOCUS_SEARCH:
            focusAddressBar(clearContents: true)
            return true
        case .IDC_CLOSE_TAB:
            ChromiumLauncher.sharedInstance().bridge?.executeCommand(
                Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue),
                windowId: Int64(windowId)
            )
            return true
        case .IDC_TAB_SEARCH, .IDC_DUPLICATE_TAB, .IDC_WINDOW_PIN_TAB,
             .IDC_DEV_TOOLS, .IDC_DEV_TOOLS_INSPECT,
             .IDC_DEV_TOOLS_CONSOLE, .PHI_TOGGLE_SIDEBAR,
             .PHI_TOGGLE_CHATBAR,
             .IDC_SELECT_PREVIOUS_TAB, .IDC_SELECT_NEXT_TAB,
             .IDC_SELECT_LAST_TAB, .PHI_TAB_SWITCHER_FORWARD,
             .PHI_TAB_SWITCHER_BACKWARD, .PHI_SELECT_NEXT_SPACE,
             .PHI_SELECT_PREVIOUS_SPACE:
            return true
        case let command where command.spaceSelectionIndex != nil:
            return true
        case let command
            where command.rawValue >= CommandWrapper.IDC_SELECT_TAB_0.rawValue
                && command.rawValue <= CommandWrapper.IDC_SELECT_TAB_7.rawValue:
            return true
        default:
            return false
        }
    }

    private func configureKioskWindow(_ window: NSWindow) {
        window.styleMask.formUnion([
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 360)
        if window.frame.width < 640 || window.frame.height < 480 {
            window.setContentSize(NSSize(width: 900, height: 640))
        }
    }

    @MainActor
    private func focusAddressBar(clearContents: Bool) {
        (contentViewController as? KioskBrowserContentViewController)?
            .focusAddressBar(clearContents: clearContents)
    }
}
