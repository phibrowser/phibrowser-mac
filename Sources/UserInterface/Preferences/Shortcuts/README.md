# macOS Shortcut Customization and Chromium Integration

## Design Goals

- Keep Chromium authoritative for ordinary `IDC_*` command dispatch.
- Intercept native Phi shortcuts before falling back to Chromium.
- Use one event-normalization path for recording and native matching.
- Keep Phi's stored shortcut identity separate from AppKit's menu representation.
- Keep settings, conflict reporting, native menus, and Chromium menu overrides in sync.
- Rebuild the main menu after an override changes without replacing existing menu actions or targets.

## Native Ownership and Key Representations

- `ShortcutsKey` in `Shortcuts.swift` is the shared shortcut identity used by
  recording, display, conflict detection, native dispatch, and the Chromium
  bridge. `eventKeys(for:)` owns `NSEvent` normalization.
- `EventKeys.canonical` is the primary identity used for new recordings and
  native lookup. For covered non-Latin letter events it is Latin; otherwise it
  remains the normalized semantic key.
- `EventKeys.legacy` preserves a different active-layout semantic character as
  a secondary native lookup candidate for previously stored non-Latin overrides.
- `ShortcutsKey.menuKeyEquivalent` projects the stored identity into the form
  AppKit and Chromium menu matching expect.
- `Shortcuts+Custom.swift` owns effective-key lookup, overrides, persistence,
  change notification, and menu rebuild requests. It does not normalize events.
- `ShortcutsViewModel` owns settings presentation and conflict reporting.
- `CommandDispatcher` owns pre-Chromium interception for the commands listed in
  `phiInterceptedCommands`. Other commands continue through Chromium.

## Event Normalization and Input Sources

`charactersIgnoringModifiers` removes Command, Option, and Control character
transformations, but it retains Shift-produced printable characters and the
active input source. A Cyrillic layout can therefore report a Cyrillic character
even when the same physical key represents a Latin shortcut.
Phi first reads the focused `NSTextInputContext` input-source identifier. That
API can be `nil` when focus is outside an editable responder, so Phi falls back
to the process-wide source returned by Carbon TIS, matching Chromium's source
lookup boundary.

Recording and native dispatch resolve an event in this order:

1. Build the semantic key from `charactersIgnoringModifiers`. Physical Tab is
   normalized to `"\t"`, Delete to Backspace, and supported modifiers are limited
   to Command, Option, Shift, and Control.
2. If `charactersIgnoringModifiers` is empty or non-ASCII and `characters`
   contains one printable ASCII character, use that AppKit menu equivalent as
   the canonical character.
3. Handle the same observed AppKit exceptions as Chromium for Apple Hebrew
   Cmd-Q and Arabic PC/AZERTY Shift-Cmd-V. Both event strings are ASCII in these
   cases, so the input-source identifier is required to disambiguate them from
   intentional ASCII layout mappings.
4. For the same Command-QWERTY input sources recognized by Chromium, use the
   Carbon `kVK_ANSI_*` physical identity while Command is held. This covers the
   26 letters, 10 digits, and 11 punctuation keys on the main ANSI keyboard,
   including their Shift-produced characters.
5. If no verified Latin identity is available, retain the semantic key.

Ordinary ASCII-to-ASCII differences do not trigger a physical fallback. This
preserves semantic layouts such as Dvorak instead of treating every differing
character as a QWERTY key. Chromium's explicit Command-QWERTY layouts are the
exception and use the same main-keyboard printable mapping in both Phi and
Chromium. Other punctuation remains layout-defined.

The Hebrew and Arabic handling recognizes known Apple input-source families and
observed event shapes. It is not a guarantee for every third-party input method,
future input-source identifier, punctuation mapping, or macOS event behavior.

## Stored Keys and Menu Key Equivalents

Phi stores printable shortcuts as a normalized character plus explicit
modifiers. AppKit encodes Shift differently for printable menu shortcuts:

```text
Stored/display identity: p + Command + Shift
AppKit menu identity:     P + Command
```

`menuKeyEquivalent` performs this projection by uppercasing a printable
character and removing Shift from the modifier mask. Control characters and
function keys retain Shift; for example, Shift-Tab remains `"\t" + Shift`.

Shifted punctuation must store the character AppKit actually reports. For
example, the US-layout Select Previous/Next Tab defaults store `{` and `}` plus
Shift, so their menu identities remain distinct from Back/Forward's `[` and `]`.
The settings view presents those two defaults as the familiar physical-key labels
`Cmd-Shift-[` and `Cmd-Shift-]`; that presentation exception does not change the
stored or executable identity.

The Chromium bridge, native menu writers, conflict detection, and native
equivalent matching must all use this projected identity. Display and JSON
persistence continue to use the stored identity.

## Data Flow

### Recording

1. `CommandShortcutCaptureView` captures an `NSEvent`.
2. `ShortcutsSettingsView` calls `ShortcutsKey.recordingKey(for:)`.
3. `ShortcutsViewModel` passes the canonical key to `Shortcuts.override`.
4. `Shortcuts+Custom` saves the override, rebuilds the native intercepted-command
   map, posts `shortcutsDidChange`, and requests a Chromium main-menu rebuild.

Unmodified keys are not recorded. A non-Latin event is stored and displayed with
a canonical Latin character only when AppKit supplies a verified ASCII equivalent
or Chromium defines an input-source-specific physical mapping. Otherwise Phi
keeps the semantic local-script character instead of saving an identity that one
of the execution paths cannot reproduce.

### Execution

- Native intercepted commands:
  `phi_command_dispatcher_delegate.mm` -> `PhiChromiumCoordinator` ->
  `CommandDispatcher.handleKeyEquivalent` -> `ShortcutsKey.eventKeys` ->
  canonical lookup -> legacy lookup -> native dispatch.
  New Kiosk Window uses this path so its effective shortcut takes precedence
  over Chromium's `IDC_NEW_SPLIT_TAB` accelerator only while both are bound to
  the same key.
- Ordinary Chromium commands:
  `keyEquivalentOverrideForCommand:` returns the override's projected
  `menuKeyEquivalent`, after which Chromium performs its normal menu and command
  lookup.
- Native menu items:
  `AppController+Menu`, `Shortcuts.updateShortcut`, and tab context menus apply
  `menuKeyEquivalent` directly.

### Display and Conflicts

- Settings display is rendered from the effective stored `ShortcutsKey`.
- Conflict detection compares `menuKeyEquivalent`, because representationally
  different keys can execute as the same AppKit shortcut.
- Select Previous/Next Tab use command-specific labels for their shifted bracket
  defaults while conflict detection continues to use `{` and `}`.

## Chromium Shortcut and Command Dispatch Overview

- Chromium's original menu and shortcut definitions live in:
  - `chrome/browser/ui/cocoa/main_menu_builder.mm`
  - `chrome/browser/ui/cocoa/accelerators_cocoa.mm`
  - `chrome/browser/global_keyboard_shortcuts_mac.mm`
  - `chrome/app/chrome_command_ids.h`
- `Shortcuts.DefaultShortcuts` is Phi's default source for settings and native
  integration. Chromium retains its original default when no override exists,
  so corresponding values must stay aligned.
- Dispatch pipeline:
  - `ChromeCommandDispatcherDelegate::prePerformKeyEquivalent` matches a menu or
    accelerator, executes non-overridable commands, or dispatches to the host.
  - `CommandForKeyEvent()` checks the main menu and then Chromium's synthetic
    hidden shortcuts.
  - `postPerformKeyEquivalent` performs additional redispatch work.
- Cmd-W / Shift-Cmd-W switch behavior:
  - `PhiAppController::updateMenuItemKeyEquivalents` adjusts Close Tab / Close
    Window title, tag, and action before matching.

## Phi Integration Points

- Interception and bridging:
  - `phi_command_dispatcher_delegate.mm` calls the Phi bridge's native
    `handleKeyEquivalent` path first. Unhandled events continue through Chromium.
  - `phi_command_handler.mm` calls the native `commandDispatch` path before its
    normal command handling.
- Main-menu override:
  - Under `BUILDFLAG(IS_MAC_PHI)`, `main_menu_builder.mm` asks
    `keyEquivalentOverrideForCommand:` for each command override.
  - No override returns `nil` and preserves Chromium's default.
  - An explicit disable returns an empty key equivalent and zero modifiers.
  - An assigned override returns `ShortcutsKey.menuKeyEquivalent`, never the raw
    stored character/modifier pair.
  - Only `keyEquivalent` and the modifier mask are changed. Existing actions and
    targets remain Chromium-owned.
- Main-menu rebuild:
  - `requestRebuildMainMenu` reruns `BuildMainMenu` and reapplies custom shortcuts.
  - `PhiAppController::mainMenuRebuilt` restores the File menu delegate, rebuilds
    History/Bookmark/Tab MenuBridge content, and updates dynamic key equivalents.
- Native-menu synchronization:
  - `Shortcuts.updateShortcut(for:)` projects both an effective override and the
    corresponding Phi default. Menu items outside `DefaultShortcuts` are left
    unchanged.
- Hidden-shortcut boundary:
  - Menu overrides affect built `NSMenuItem` instances only. They do not remove
    entries from `global_keyboard_shortcuts_mac.mm`'s synthetic hidden-shortcut
    table.
  - A native Phi command that conflicts with a hidden Chromium accelerator must
    match in the pre-dispatch interceptor. An unhandled event continues to the
    hidden Chromium lookup.

## Persistence and Compatibility

`CustomShortcuts.json` represents three states:

- No command entry: use the default shortcut.
- Entry with a null key: explicitly disabled.
- Entry with a key: custom override.

The file is decoded exactly as stored. Phi does not migrate a legacy character
during load because persisted data contains neither the original physical key
code nor the input-source identity needed for a reliable conversion.

New recordings use the current canonical form. Legacy lookup can preserve native
execution for an existing non-Latin intercepted-command override when the
canonical key is unassigned, but it does not guarantee Latin display,
cross-layout execution, or compatibility for ordinary Chromium commands.
Legacy records also cannot be assigned a reliable Latin alias during static
conflict reporting: the JSON has no original key code or input-source metadata.
Re-recording the shortcut persists the current canonical identity and restores
normal conflict comparison without guessing at old data.

## Key Files

- Native identity, recording, persistence, and conflict reporting:
  - `Sources/UserInterface/Preferences/Shortcuts/Shortcuts.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/Shortcuts+Custom.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/ShortcutsSettingsView.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/ShortcutsViewModel.swift`
  - `Sources/CommandDispatcher/CommandDispatcher.swift`
  - `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`
- Chromium bridge and interception:
  - `chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h|.mm`
  - `chrome/browser/phinomenon/phi_app_bridge/phi_command_dispatcher_delegate.mm`
  - `chrome/browser/phinomenon/phi_app_bridge/phi_command_handler.mm`
- Chromium menu and matching:
  - `chrome/browser/ui/cocoa/main_menu_builder.mm`
  - `ui/base/cocoa/nsmenuitem_additions.mm`
  - `chrome/browser/global_keyboard_shortcuts_mac.mm`
  - `chrome/app/chrome_command_ids.h`
- Cmd-W / close-window dispatch:
  - `chrome/browser/phinomenon/phi_app_bridge/phi_app_controller_mac.mm`
- Related Chromium documentation:
  - `docs/mac/about_hotkeys_and_keycodes.md` in the Chromium source tree.
- Representative tests:
  - `Tests/PhiBrowserTests/PhiBrowserTests.swift`

## Phi Extension-Bridged Commands

Some `PHI_*` commands act on the Sidecar extension instead of a native target.
`PHI_NEW_CONVERSATION` (raw value `90004`, default Shift-Cmd-O) is one: its logic
lives in the extension, so the native selector broadcasts a message.

- It is defined like other customizable shortcuts: `CommandWrapper` and
  `DefaultShortcuts` in `Shortcuts.swift`, plus settings group/presentation data
  in `Shortcuts+Custom.swift`.
- The View-menu item calls `newConversation(_:)` in `AppController+Menu.swift`,
  which broadcasts `newConversation` with the focused tab's Chromium `guid` as
  `tabId`. Each tab owns a Sidecar WebContents, so this targets exactly the
  focused tab.
- `validateUserInterfaceItem(_:)` enables it only while focus is in an enabled
  AI sidebar. When disabled, normal key-equivalent processing can continue.
- The extension listens on `chrome.phinomenonPrivate.onAppMessage`. See the
  ai-extension repository's `docs/sidecar-new-conversation-shortcut.md`.

## Verification Boundaries

Shortcut unit tests use synthetic `NSEvent` values to cover representative
Cyrillic, Hebrew, Arabic, ASCII-layout, Command-QWERTY printable,
Shift-printable, and Tab cases. Tests pass explicit input-source identifiers so
their results do not depend on the developer's active keyboard layout. They
verify the normalization and identity rules, but do not replace live testing of
every macOS input source,
real `NSMenuItem` tracking, Chromium hidden accelerators, settings UI rendering,
or legacy JSON compatibility.

## Notes

- Never write a raw stored `ShortcutsKey` directly to an `NSMenuItem`; use
  `menuKeyEquivalent`.
- Do not overwrite original menu actions or targets when applying an override.
- After rebuilding the main menu, keep Cmd-W / Shift-Cmd-W items compatible with
  `updateMenuItemKeyEquivalents` lookup and routing.
- To let Cmd-W on non-browser windows fall back to system `performClose:`, return
  unhandled for those windows or remove the Close Tab binding.
