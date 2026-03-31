// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Countly

struct EventTracker {
    static func initTracker() {
        let config: CountlyConfig = CountlyConfig()
        #if NIGHTLY_BUILD || DEBUG
        config.appKey = ""
        #else
        config.appKey = ""
        #endif
        config.host = ""
        #if DEBUG
        config.enableDebug = true
        #endif
        config.enableAllConsents = true
        Countly.sharedInstance().start(with: config)
    }
    
    /// Records an immediate event.
    static func trackEvent(_ eventKey: String, segmentation: [String: Any]? = nil, count: UInt = 1) {
        Countly.sharedInstance().recordEvent(eventKey, segmentation: segmentation, count: count)
    }
    
    /// Starts a timed event.
    static func startEvent(_ eventKey: String) {
        Countly.sharedInstance().startEvent(eventKey)
    }
    
    /// Ends a timed event.
    static func endEvent(_ eventKey: String, segmentation: [String: Any]? = nil, count: UInt = 1, sum: Double = 0) {
        Countly.sharedInstance().endEvent(eventKey, segmentation: segmentation, count: count, sum: sum)
    }
    
    /// Cancels a timed event that was previously started.
    static func cancelEvent(_ eventKey: String) {
        Countly.sharedInstance().cancelEvent(eventKey)
    }
    
    static func updateUserProfile(_ user: User) {
        if let sub = user.sub {
            Countly.user().name = sub as CountlyUserDetailsNullableString
        }
        Countly.user().save()
    }
}
