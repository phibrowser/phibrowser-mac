// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

/// PostHog events for Peek View usage.
///
/// `peek_view_opened` fires when the panel actually presents — a same-site
/// candidate that becomes a plain tab never counts. `peek_view_ended` fires
/// once per peek with how it ended and how long it lived; window teardown
/// deliberately reports nothing (quit noise). The Settings › Navigations
/// toggles report `peek_view_setting_changed` (master) and
/// `peek_view_auto_setting_changed` (automatic diversion).
@MainActor
enum PeekViewAnalytics {

    /// How the peek came to be. `explicit` covers both the context-menu item
    /// and Shift+click — the bridge routes them through one entry point.
    enum EntryPoint: String {
        case auto
        case explicit
        case restored
    }

    enum OpenerKind: String {
        case bookmark
        case pinned
        case normal
    }

    enum EndReason: String {
        case closed
        case openedAsTab = "opened_as_tab"
        case openedAsSplit = "opened_as_split"
        case openerClosed = "opener_closed"
        case pageClosed = "page_closed"
        case replaced
    }

    /// Open time per live peek (Chromium tab id), consumed by the end event
    /// for the duration property. An end with no recorded open (e.g. window
    /// teardown already dropped the bookkeeping) reports nothing.
    private static var openedAt: [Int: Date] = [:]

    static func opened(peekTabId: Int,
                       entryPoint: EntryPoint,
                       openerKind: OpenerKind) {
        openedAt[peekTabId] = Date()
        PostHogSDK.shared.capture("peek_view_opened", properties: [
            "entry_point": entryPoint.rawValue,
            "opener_kind": openerKind.rawValue,
        ])
    }

    static func ended(peekTabId: Int, reason: EndReason) {
        guard let start = openedAt.removeValue(forKey: peekTabId) else { return }
        PostHogSDK.shared.capture("peek_view_ended", properties: [
            "reason": reason.rawValue,
            "duration_seconds": Int(Date().timeIntervalSince(start)),
        ])
    }

    static func settingChanged(enabled: Bool) {
        PostHogSDK.shared.capture("peek_view_setting_changed", properties: [
            "enabled": enabled,
        ])
    }

    static func autoSettingChanged(enabled: Bool) {
        PostHogSDK.shared.capture("peek_view_auto_setting_changed", properties: [
            "enabled": enabled,
        ])
    }
}
