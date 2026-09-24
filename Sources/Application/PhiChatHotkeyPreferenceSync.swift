// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

struct PhiChatHotkeyPreferenceChannel: Equatable {
    let key: String
    let notificationName: Notification.Name

    static let current = make(browserBundleIdentifier: Bundle.main.bundleIdentifier)

    static func make(browserBundleIdentifier: String?) -> Self {
        let bundleIdentifier = browserBundleIdentifier?.lowercased() ?? ""
        let channel: String
        let notificationPrefix: String
        if bundleIdentifier.contains("canary") {
            channel = "canary"
            notificationPrefix = "com.phibrowser.canary"
        } else if bundleIdentifier.contains("dev") {
            channel = "dev"
            notificationPrefix = "com.phibrowser.dev"
        } else {
            channel = "stable"
            notificationPrefix = "com.phibrowser"
        }

        return Self(
            key: "phiChat.hotkeyEnabled.\(channel)",
            notificationName: Notification.Name(
                "\(notificationPrefix).phiChat.hotkeyPreferenceDidChange"
            )
        )
    }
}

@MainActor
final class PhiChatHotkeyPreferenceSync: NSObject, ObservableObject {
    static let shared = PhiChatHotkeyPreferenceSync()

    nonisolated static let appGroupIdentifier = "group.com.phibrowser.shared"

    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private let channel: PhiChatHotkeyPreferenceChannel

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier),
        channel: PhiChatHotkeyPreferenceChannel = .current
    ) {
        guard let defaults else {
            fatalError("Phi Chat hotkey preference App Group is unavailable")
        }
        defaults.synchronize()
        self.defaults = defaults
        self.channel = channel
        isEnabled = defaults.bool(forKey: channel.key)
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handlePreferenceDidChange(_:)),
            name: channel.notificationName,
            object: nil
        )
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: channel.key)
        defaults.synchronize()
        isEnabled = enabled
        DistributedNotificationCenter.default().postNotificationName(
            channel.notificationName,
            object: nil,
            deliverImmediately: true
        )
    }

    func reload() {
        defaults.synchronize()
        isEnabled = defaults.bool(forKey: channel.key)
    }

    @objc private func handlePreferenceDidChange(_ notification: Notification) {
        reload()
    }
}
