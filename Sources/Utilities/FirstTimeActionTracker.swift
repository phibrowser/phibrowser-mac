// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

enum FirstTimeAction: String, CaseIterable {
    case spaceCreated = "space_created"
    case aiSidebarOpened = "ai_sidebar_opened"
    case importFinished = "import_finished"
    case memoryOpened = "memory_opened"
    case agentTask = "agent_task"
    case connectorConnected = "connector_connected"
    case phiLinkPaired = "phi_link_paired"
}

@MainActor
enum FirstTimeActionTracker {
    static let recordedActionsDefaultsKey =
        "metrics.firstTimeActions.recorded"

    typealias Capture = (_ event: String, _ properties: [String: Any]) -> Void

    static func capture(
        _ action: FirstTimeAction,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        installDate: () -> Date? = {
            AppController.launchContext?.firstLaunchDate
        },
        postHogCapture: Capture = { event, properties in
            PostHogSDK.shared.capture(event, properties: properties)
        }
    ) {
        let recordedActions = Set(
            defaults.stringArray(forKey: recordedActionsDefaultsKey) ?? []
        )
        guard !recordedActions.contains(action.rawValue),
              let firstLaunchDate = installDate() else {
            return
        }

        let secondsSinceInstall = max(
            0,
            Int(now.timeIntervalSince(firstLaunchDate))
        )
        postHogCapture("first_time_action", [
            "action": action.rawValue,
            "seconds_since_install": secondsSinceInstall,
        ])

        defaults.set(
            Array(recordedActions.union([action.rawValue])).sorted(),
            forKey: recordedActionsDefaultsKey
        )
    }
}
