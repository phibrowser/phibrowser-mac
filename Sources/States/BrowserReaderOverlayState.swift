// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// Window-scoped state for the Reader View overlay: the reader extension
/// answers a reader-open request by creating a tab on its reading surface
/// (`reader.html`), and the app hosts that tab in a panel covering the whole
/// page pane — the origin tab keeps its live page underneath. Owned by
/// `BrowserState` (one instance per window).
///
/// One reader per origin tab, any number of origin tabs. Only the focused
/// origin's reader is visible — switching tabs swaps the panel to the newly
/// focused origin's reader (or hides it), and closing an origin closes its
/// reader.
///
/// Presented tabs are live Chromium strip tabs that are deliberately NOT in
/// `BrowserState.tabs` — the same off-strip pattern as Peek and AI Chat tabs
/// — which is what lets a link clicked inside the reader page become a
/// normal tab without losing page state.
final class BrowserReaderOverlayState: ObservableObject {
    /// The reader-surface tab shown for each origin tab id; empty = none.
    @Published private(set) var readersByOrigin: [Int: Tab] = [:]

    func present(_ tab: Tab, originTabId: Int) {
        readersByOrigin[originTabId] = tab
    }

    func reader(forOrigin originTabId: Int) -> Tab? {
        readersByOrigin[originTabId]
    }

    func readerTab(withId tabId: Int) -> Tab? {
        readersByOrigin.values.first { $0.guid == tabId }
    }

    func originTabId(forReaderTabId tabId: Int) -> Int? {
        readersByOrigin.first { $0.value.guid == tabId }?.key
    }

    func removeReader(forOrigin originTabId: Int) {
        readersByOrigin.removeValue(forKey: originTabId)
    }

    func clear() {
        readersByOrigin.removeAll()
    }
}
