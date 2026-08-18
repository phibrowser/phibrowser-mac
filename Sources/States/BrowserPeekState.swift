// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// Window-scoped state for the Peek popup: a floating panel that previews a
/// cross-site page opened from a bookmark- or pinned-bound tab instead of
/// creating a normal tab. Owned by `BrowserState` (one instance per window).
///
/// One peek per opener tab, any number of opener tabs: each bound tab can
/// carry its own peek, keyed here by the opener's tab id. Only the focused
/// opener's peek is visible — switching tabs swaps the panel to the newly
/// focused opener's peek (or hides it), and closing an opener closes its
/// peek.
///
/// Presented tabs are live Chromium strip tabs that are deliberately NOT in
/// `BrowserState.tabs` — the same off-strip pattern as AI Chat tabs — which is
/// what makes "Open as Tab" a pure bookkeeping move that preserves page state.
final class BrowserPeekState: ObservableObject {
    /// The strip tab shown in the Peek panel for each opener tab id;
    /// empty = no peeks.
    @Published private(set) var peeksByOpener: [Int: Tab] = [:]

    func present(_ tab: Tab, openerTabId: Int) {
        peeksByOpener[openerTabId] = tab
    }

    func peek(forOpener openerTabId: Int) -> Tab? {
        peeksByOpener[openerTabId]
    }

    func peekTab(withId tabId: Int) -> Tab? {
        peeksByOpener.values.first { $0.guid == tabId }
    }

    func openerTabId(forPeekTabId tabId: Int) -> Int? {
        peeksByOpener.first { $0.value.guid == tabId }?.key
    }

    func removePeek(forOpener openerTabId: Int) {
        peeksByOpener.removeValue(forKey: openerTabId)
    }

    func clear() {
        peeksByOpener.removeAll()
    }
}
