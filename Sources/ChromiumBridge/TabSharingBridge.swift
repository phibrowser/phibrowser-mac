// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The screen-share session Phi's quick switch addresses, as one window sees
/// it. Parsed from the dictionary documented next to
/// `-getTabSharingSnapshotWithWindowId:` in PhiChromiumBridgeHeader.h.
struct TabSharingSnapshot: Equatable {
    struct Session: Equatable {
        enum SurfaceType: String {
            case tab
            case window
            case screen
        }

        let sessionId: String
        /// The tab presenting (e.g. the meeting tab).
        let capturerTabId: Int
        let capturerWindowId: Int?
        let surfaceType: SurfaceType
        /// The tab currently being shown to others; tab surfaces only.
        let sharedTabId: Int?
        let sharedWindowId: Int?
        let isSwitching: Bool
        let canSwitch: Bool
    }

    let revision: UInt64
    let selectedSession: Session?

    static let empty = TabSharingSnapshot(revision: 0, selectedSession: nil)

    init(revision: UInt64, selectedSession: Session?) {
        self.revision = revision
        self.selectedSession = selectedSession
    }

    init(dictionary: [String: Any]) {
        revision = (dictionary["revision"] as? NSNumber)?.uint64Value ?? 0
        selectedSession = (dictionary["selectedSession"] as? [String: Any])
            .flatMap(Session.init(dictionary:))
    }
}

private extension TabSharingSnapshot.Session {
    init?(dictionary: [String: Any]) {
        guard let sessionId = dictionary["sessionId"] as? String,
              !sessionId.isEmpty,
              let capturerTabId = (dictionary["capturerTabId"] as? NSNumber)?.intValue,
              let surface = (dictionary["surfaceType"] as? String)
                .flatMap(SurfaceType.init(rawValue:)) else {
            return nil
        }
        self.init(
            sessionId: sessionId,
            capturerTabId: capturerTabId,
            capturerWindowId: (dictionary["capturerWindowId"] as? NSNumber)?.intValue,
            surfaceType: surface,
            sharedTabId: (dictionary["sharedTabId"] as? NSNumber)?.intValue,
            sharedWindowId: (dictionary["sharedWindowId"] as? NSNumber)?.intValue,
            isSwitching: (dictionary["state"] as? String) == "switching",
            canSwitch: (dictionary["canSwitch"] as? NSNumber)?.boolValue ?? false
        )
    }
}

struct TabSharingSwitchResult: Equatable {
    enum Status: String {
        case success
        /// The session ended or is no longer the latest started share.
        case stale
        /// Rejected before anything was sent to the capture engine.
        case notAllowed
        /// The capture engine kept the previous tab.
        case failed
    }

    let status: Status
    let reason: String?

    var isSuccess: Bool { status == .success }

    /// What an older framework without the tab sharing API answers.
    static let unsupported = TabSharingSwitchResult(status: .notAllowed,
                                                    reason: "switchingUnsupported")

    init(status: Status, reason: String?) {
        self.status = status
        self.reason = reason
    }

    init(dictionary: [String: Any]) {
        status = (dictionary["status"] as? String).flatMap(Status.init(rawValue:)) ?? .failed
        reason = dictionary["reason"] as? String
    }
}

/// Bridge calls behind the tab sharing quick switch. Value-typed so window
/// state can be exercised in tests without a running framework.
struct TabSharingClient {
    var snapshot: (_ windowId: Int) -> TabSharingSnapshot?
    var availability: (_ sessionId: String, _ windowId: Int, _ tabId: Int) -> TabSharingSwitchResult
    var switchSharedTab: (_ sessionId: String,
                          _ windowId: Int,
                          _ tabId: Int,
                          _ completion: @escaping (TabSharingSwitchResult) -> Void) -> Void

    /// Talks to Phi Framework. Every call degrades to "no session" or
    /// `unsupported` when the framework predates the API.
    static let live = TabSharingClient(
        snapshot: { windowId in
            let bridge = ChromiumLauncher.sharedInstance().bridge
            guard let dictionary = bridge?.getTabSharingSnapshot?(withWindowId: Int64(windowId)) else {
                return nil
            }
            return TabSharingSnapshot(dictionary: dictionary)
        },
        availability: { sessionId, windowId, tabId in
            let bridge = ChromiumLauncher.sharedInstance().bridge
            guard let dictionary = bridge?.getTabSharingSwitchAvailability?(
                forSessionId: sessionId,
                targetWindowId: Int64(windowId),
                targetTabId: Int64(tabId)
            ) else {
                return .unsupported
            }
            return TabSharingSwitchResult(dictionary: dictionary)
        },
        switchSharedTab: { sessionId, windowId, tabId, completion in
            let bridge = ChromiumLauncher.sharedInstance().bridge
            let dispatched: Void? = bridge?.switchSharedTab?(
                withExpectedSessionId: sessionId,
                targetWindowId: Int64(windowId),
                targetTabId: Int64(tabId)
            ) { dictionary in
                completion(TabSharingSwitchResult(dictionary: dictionary))
            }
            if dispatched == nil {
                completion(.unsupported)
            }
        }
    )
}
