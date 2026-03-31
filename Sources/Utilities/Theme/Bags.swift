// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Stores a mapper value and its active subscription.
struct Bag {
    let value: Any
    let subscription: AnyObject
}

/// Stores multiple subscriptions keyed by property identity.
final class Bags {
    private var map: [AnyHashable: Bag] = [:]
    
    subscript<K: Hashable>(key: K) -> Bag? {
        get { map[key] }
        set { map[key] = newValue }
    }
}
