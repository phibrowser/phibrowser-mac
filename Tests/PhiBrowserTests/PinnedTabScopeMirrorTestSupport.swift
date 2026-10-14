// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Clear the pin-scope key and both sidecars to protect the developer's real preferences.
/// LocalStore.changePinnedTabScope no longer writes the key (B-3 stage 1, design principle 3),
/// but a test that writes the key itself, as Settings and settings sync do, writes UserDefaults.standard.
/// Hosted XCTest runs inside Phi, whose standard domain is real, not a disposable suite.
/// A test that leaves PhiPinnedTabScope at some target makes the next normal launch's
/// follower and account replay treat it as authoritative (§7.1 step 3, case 2) and migrate
/// the developer's real pins to that scope.
///
/// Clear all three keys together: clearing only the primary leaves mismatched sidecars.
/// Replay then follows case 1, reseeding from rows and writing matching sidecars.
/// Every test class driving changePinnedTabScope calls this from tearDown.
extension XCTestCase {
    func clearPinnedTabScopeMirrorDefaults() {
        let defaults = UserDefaults.standard
        let key = PinnedTabScopeMirror.key
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: SyncableSettings.timestampKey(for: key))
        defaults.removeObject(forKey: SyncableSettings.valueKey(for: key))
    }
}
