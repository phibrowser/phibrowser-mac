# Phi Chat Hotkey Preference

Phi Browser owns the user-facing switch under Settings > Phi & AI > Phi
Sentinel. Sentinel owns the global triple-Shift monitor and Accessibility
permission request. The switch controls only the fixed shortcut; it does not
change the always-available "Open Phi Chat" status-menu item.

## Cross-process contract

- Both apps use the `group.com.phibrowser.shared` UserDefaults suite.
- The key is `phiChat.hotkeyEnabled.<channel>`, where `<channel>` is `stable`,
  `canary`, or `dev`.
- Browser persists the Boolean before posting the matching distributed
  notification. The notification has no payload; Sentinel treats it only as a
  signal to reread the shared preference.
- Stable uses `com.phibrowser.phiChat.hotkeyPreferenceDidChange`, Canary uses
  `com.phibrowser.canary.phiChat.hotkeyPreferenceDidChange`, and Dev uses
  `com.phibrowser.dev.phiChat.hotkeyPreferenceDidChange`.
- Sentinel migrates `phiChat.hotkeyEnabled` from its standard defaults only
  when the matching shared key has no value. The old value is retained for
  downgrade compatibility; once the shared value exists, it is authoritative.
- Enabling the preference launches Sentinel if needed. Sentinel requests
  Accessibility permission when the preference becomes enabled and starts or
  stops its event monitor based on the persisted value.

Browser channel construction is in
`Sources/Application/PhiChatHotkeyPreferenceSync.swift`; Sentinel's matching
reader and migration are in `sentinel/Sources/Utilities/PhiChatHotkeyPreference.swift`.
