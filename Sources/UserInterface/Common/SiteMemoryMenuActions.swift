// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Network

/// A page-scoped snapshot shared by the native menu and extension popover.
@MainActor
struct SiteMemoryMenuActions {
    enum Action {
        case toggleCollection
        case removeMemories
    }

    let host: String
    let profileID: String
    let collectionEnabled: Bool?
    private let service: SiteMemoryService?

    var canRemoveMemories: Bool { service != nil }
    var collectionState: NSControl.StateValue {
        collectionEnabled.map { $0 ? .on : .off } ?? .mixed
    }

    static var collectionTitle: String {
        NSLocalizedString("browser.addressBarMenu.memory.collectionToggle", value: "Collection Site Memories", comment: "Website menus - Toggle memory collection for the current website in this browser profile")
    }

    static var removalTitle: String {
        NSLocalizedString("browser.addressBarMenu.memory.removeAction", value: "Remove Site Memories", comment: "Website menus - Delete saved memories for the current website and its subdomains in this browser profile")
    }

    static func current(browserState: BrowserState?, urlString: String) -> Self? {
        guard let browserState else { return nil }
        return Self(
            urlString: urlString,
            profileID: browserState.profileId,
            isIncognito: browserState.isIncognito,
            isPhiAIEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue(),
            service: try? SiteMemoryService.currentAccount()
        )
    }

    init?(urlString: String, profileID: String, isIncognito: Bool,
          isPhiAIEnabled: Bool, service: SiteMemoryService?) {
        guard isPhiAIEnabled, !isIncognito,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let rawHost = url.host,
              let host = try? SiteMemorySettingsStore.normalizedHost(rawHost),
              (try? SiteMemorySettingsStore.validateProfileID(profileID)) != nil else {
            return nil
        }
        self.host = host
        self.profileID = profileID
        self.service = service
        collectionEnabled = try? service?.collectionEnabled(for: host, profileID: profileID)
    }

    static func removalHost(for host: String) -> String {
        guard IPv4Address(host) == nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.isSameSite(forURL:url:))) else {
            return host
        }
        // Chromium's public/private suffix rules keep co.uk and github.io tenants separate.
        // Older frameworks retain the exact host rather than guessing a broader scope.
        var labels = host.split(separator: ".")
        while labels.count > 2 {
            let parent = labels.dropFirst().joined(separator: ".")
            guard bridge.isSameSite(forURL: "https://\(host)", url: "https://\(parent)") else { break }
            labels.removeFirst()
        }
        return labels.joined(separator: ".")
    }

    func perform(_ action: Action, window: NSWindow?) {
        guard let service else { return }
        // The task retains the captured account, host and profile after dismissal.
        Task { @MainActor in
            do {
                switch action {
                case .toggleCollection:
                    guard let collectionEnabled else { return }
                    try service.setCollectionEnabled(!collectionEnabled, for: host, profileID: profileID)
                case .removeMemories:
                    _ = try await service.removeMemories(for: Self.removalHost(for: host), profileID: profileID)
                }
            } catch {
                let title: String
                switch action {
                case .toggleCollection:
                    title = NSLocalizedString("browser.addressBarMenu.memory.updateFailed", value: "Couldn’t Change Memory Collection", comment: "Website menus - Error title when saving the website memory collection setting fails")
                case .removeMemories:
                    title = NSLocalizedString("browser.addressBarMenu.memory.removeFailed", value: "Couldn’t Remove Site Memories", comment: "Website menus - Error title when deleting the website memories fails")
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = title
                alert.informativeText = NSLocalizedString("browser.addressBarMenu.memory.errorDetail", value: "Please try again.", comment: "Website menus - Recovery suggestion after a website memory operation fails")
                if let window {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}
