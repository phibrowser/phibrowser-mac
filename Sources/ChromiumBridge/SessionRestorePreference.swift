// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The single accessor for the app-level "restore previous session" switch.
///
/// The value lives in Chromium local state — the cold-start path reads it
/// there to decide whether to restore the last session — so this reads and
/// writes it through the bridge rather than keeping a separate Mac-side copy
/// that could drift. Reads fall back to `true` (the key-absent meaning, i.e.
/// the pre-switch always-restore behavior) while the bridge is not yet wired.
enum SessionRestorePreference {
    static var isEnabled: Bool {
        get {
            ChromiumLauncher.sharedInstance().bridge?
                .isRestorePreviousSessionEnabled() ?? true
        }
        set {
            ChromiumLauncher.sharedInstance().bridge?
                .setRestorePreviousSessionEnabled(newValue)
        }
    }
}
