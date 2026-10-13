// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

/// PostHog events for Reader View usage.
///
/// Captured when the extension's `reader.state` report lands, not when the
/// user asks: `reader_view_opened` means the surface actually mounted, and
/// a request the extractor refused becomes `reader_view_open_failed` with
/// its reason. Entry points only *record* the request here; the bridge's
/// state handler decides which event it became.
@MainActor
enum ReaderViewAnalytics {

    /// Which control asked for the reader. `automation` is the DEBUG
    /// `-phi-auto-reader` trigger, kept distinct so unattended runs never
    /// read as users.
    enum EntryPoint: String {
        case addressBar = "address_bar"
        case viewMenu = "view_menu"
        case shortcut
        case contextMenu = "context_menu"
        case peekPanel = "peek_panel"
        case automation
    }

    /// The most recent open request per tab (Chromium tab id), consumed by
    /// the state report that answers it. A report with no recorded request
    /// is attributed to `unknown` rather than dropped.
    private static var pendingOpens: [Int: EntryPoint] = [:]

    static func noteOpenRequested(for tab: Tab, from entryPoint: EntryPoint) {
        pendingOpens[tab.guid] = entryPoint
    }

    static func surfaceMounted(tabId: Int) {
        let entryPoint = pendingOpens.removeValue(forKey: tabId)
        PostHogSDK.shared.capture("reader_view_opened", properties: [
            "entry_point": entryPoint?.rawValue ?? "unknown",
        ])
    }

    static func openRefused(tabId: Int, reason: String) {
        let entryPoint = pendingOpens.removeValue(forKey: tabId)
        PostHogSDK.shared.capture("reader_view_open_failed", properties: [
            "entry_point": entryPoint?.rawValue ?? "unknown",
            "reason": reason,
        ])
    }
}
