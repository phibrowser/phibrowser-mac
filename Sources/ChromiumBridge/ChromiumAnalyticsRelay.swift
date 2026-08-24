// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

/// Relays product-analytics events captured by Chromium browser-process code
/// (the phi_analytics component, arriving over the bridge delegate's
/// `captureAnalyticsEvent:module:properties:`) into the same PostHog pipeline
/// every Mac-originated event uses — the single Chromium egress (chromium
/// ADR 0008).
///
/// The relay owns the guard rules, so a Chromium-side mistake cannot reach
/// the SDK: reserved `$`-prefixed event names are dropped with a log, and
/// every accepted event is stamped with `source: "chromium"` and its
/// `module` before capture — call sites cannot forget or forge them. It
/// deliberately checks no consent: the metrics-reporting switch gates
/// identity association, not event flow, and that policy stays with the
/// identity layer.
///
/// Every accepted event produces a log line even when PostHog was never
/// initialized (OpenSource build, empty token) — on such builds the log line
/// is the end-to-end observable; only the SDK call itself is skipped.
@MainActor
final class ChromiumAnalyticsRelay {
    static let shared = ChromiumAnalyticsRelay()

    private let isPostHogInitialized: () -> Bool
    private let capture: (String, [String: Any]) -> Void
    private let logger: (String) -> Void

    init(
        isPostHogInitialized: @escaping () -> Bool = {
            // Mirrors the AppController setup condition: PostHog is set up at
            // will-finish-launching exactly when both values are present, and
            // bridge events cannot arrive before that moment.
            #if PHI_OSS_BUILD
            return false
            #else
            return PostHogEnv.projectToken.value != nil
                && PostHogEnv.host.value != nil
            #endif
        },
        capture: @escaping (String, [String: Any]) -> Void = { eventName, properties in
            #if !PHI_OSS_BUILD
            PostHogSDK.shared.capture(eventName, properties: properties)
            #endif
        },
        logger: @escaping (String) -> Void = { AppLogInfo("[ChromiumAnalytics] \($0)") }
    ) {
        self.isPostHogInitialized = isPostHogInitialized
        self.capture = capture
        self.logger = logger
    }

    /// Applies the relay rules to one Chromium-captured event and hands it to
    /// the PostHog SDK. Names only in logs — properties stay out by the
    /// privacy contract.
    func relay(eventName: String, module: String, properties: [String: Any]) {
        guard !eventName.hasPrefix("$") else {
            logger("dropped reserved event name \(eventName) (module \(module))")
            return
        }
        var stamped = properties
        stamped["source"] = "chromium"
        stamped["module"] = module
        logger("accepted \(module)/\(eventName)")
        guard isPostHogInitialized() else { return }
        capture(eventName, stamped)
    }
}
