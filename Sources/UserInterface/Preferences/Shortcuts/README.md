# macOS Shortcut Customization and Chromium Integration

## Design Goals

- Keep Chromium's original event dispatch flow intact.
- Let PhiBrowser users customize shortcuts and keep menu labels in sync.
- Support rebuilding the main menu at runtime and applying custom key bindings.

## Chromium Shortcut and Command Dispatch Overview

- Main menu and default shortcuts are defined in:
  - `chrome/browser/ui/cocoa/main_menu_builder.mm`
  - `chrome/browser/ui/cocoa/accelerators_cocoa.mm`
  - `chrome/app/chrome_command_ids.h`
- Dispatch pipeline:
  - `ChromeCommandDispatcherDelegate::prePerformKeyEquivalent`: matches menu/accelerator to a command, executes non-overridable commands, or dispatches to host.
  - `CommandForKeyEvent()`: scans menu items (including hidden shortcuts) and matches `keyEquivalent`.
  - `postPerformKeyEquivalent`: performs additional redispatch work.
- Cmd+W / Shift+Cmd+W switch behavior:
  - `PhiAppController::updateMenuItemKeyEquivalents` adjusts Close Tab / Close Window title, tag, and action before key matching.

## Phi Integration Points

- Interception and bridging:
  - `phi_command_dispatcher_delegate.mm`: `prePerformKeyEquivalent` first calls `PhiChromiumBridge.delegate handleKeyEquivalent:event window:`. If unhandled, fallback to Chromium flow.
  - `phi_command_handler.mm`: `commandDispatch:` first calls `PhiChromiumBridge.delegate commandDispatch:window:`.
- Main menu shortcut override:
  - In `main_menu_builder.mm`, under `BUILDFLAG(IS_MAC_PHI)`, iterate menu items and call `PhiChromiumBridgeDelegate keyEquivalentOverrideForCommand:`.
  - Update `keyEquivalent` and `modifierMask` only. Do not override action/target for non-`commandDispatch` items.
- Main menu rebuild:
  - `PhiChromiumBridge` exposes `requestRebuildMainMenu` to rerun `BuildMainMenu` and reapply custom shortcuts.
  - `PhiAppController::mainMenuRebuilt` resets File menu delegate, rebuilds History/Bookmark/Tab MenuBridge via `setLastProfile:`, then calls `updateMenuItemKeyEquivalents`.
- Custom shortcut config:
  - In `PhiChromiumBridgeDelegate keyEquivalentOverrideForCommand:`, return values like:
    - `@"keyEquivalent": @"t"`
    - `@"modifierFlags": @(NSEventModifierFlagCommand)`
  - Return `nil` to use default mapping.

## Key Files

- Bridge / interception:
  - `chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h|.mm`
  - `chrome/browser/phinomenon/phi_app_bridge/phi_command_dispatcher_delegate.mm`
  - `chrome/browser/phinomenon/phi_app_bridge/phi_command_handler.mm`
- Menu / shortcut construction:
  - `chrome/browser/ui/cocoa/main_menu_builder.mm`
  - `chrome/browser/ui/cocoa/accelerators_cocoa.mm`
  - `chrome/app/chrome_command_ids.h`
- Cmd+W / close-window dispatch:
  - `chrome/browser/phinomenon/phi_app_bridge/phi_app_controller_mac.mm` (`updateMenuItemKeyEquivalents`, `mainMenuRebuilt`)
- Related docs:
  - `docs/mac/about_hotkeys_and_keycodes.md`

## Notes

- When applying custom shortcuts, do not overwrite original action/target for items such as Preferences; only update `keyEquivalent`.
- After rebuilding the main menu, ensure Cmd+W / Shift+Cmd+W menu items still satisfy lookup conditions so `updateMenuItemKeyEquivalents` can route correctly.
- To let Cmd+W on non-browser windows fall back to system `performClose:`, return unhandled in `handleKeyEquivalent:` for those windows, or remove Cmd+W binding from Close Tab.
