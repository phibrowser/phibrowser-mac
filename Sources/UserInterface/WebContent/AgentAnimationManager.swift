// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

/// Tracks which tabs are currently running agent tasks and should display an overlay animation.
final class AgentAnimationManager {
    static let shared = AgentAnimationManager()

    private var activeTabIds = Set<Int>()

    /// Emits the tabId whenever its agent animation state changes.
    let stateChanged = PassthroughSubject<Int, Never>()

    func setActive(_ active: Bool, for tabId: Int) {
        let changed: Bool
        if active {
            changed = activeTabIds.insert(tabId).inserted
        } else {
            changed = activeTabIds.remove(tabId) != nil
        }
        if changed {
            AppLogDebug("[AgentAnimation] tabId=\(tabId) active=\(active)")
            stateChanged.send(tabId)
        }
    }

    func isActive(for tabId: Int) -> Bool {
        activeTabIds.contains(tabId)
    }

    func removeTab(_ tabId: Int) {
        if activeTabIds.remove(tabId) != nil {
            stateChanged.send(tabId)
        }
    }
}
