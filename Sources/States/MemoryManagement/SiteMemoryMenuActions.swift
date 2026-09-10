// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

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

    static func removalHost(for host: String, includeSubdomains: Bool) -> String {
        includeSubdomains ? SiteMemorySettingsStore.registrableDomain(for: host) ?? host : host
    }

    func makeRemovalConfirmation() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("browser.addressBarMenu.memory.removalConfirmation.title", value: "Remove Site Memories?", comment: "Website memory deletion - Confirmation dialog title")
        alert.informativeText = String(format: NSLocalizedString("browser.addressBarMenu.memory.removalConfirmation.message", value: "Saved memories for %@ will be removed from this browser profile. This can’t be undone.", comment: "Website memory deletion - Confirmation message; %@ is the current page host"), host)
        alert.addButton(withTitle: NSLocalizedString("browser.addressBarMenu.memory.removalConfirmation.removeButton", value: "Remove", comment: "Website memory deletion - Confirm removal button"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("browser.addressBarMenu.memory.removalConfirmation.cancelButton", value: "Cancel", comment: "Website memory deletion - Cancel removal button"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(format: NSLocalizedString("browser.addressBarMenu.memory.removalConfirmation.includeSubdomains", value: "Also include %@ and all its subdomains", comment: "Website memory deletion - Checkbox that expands removal to the parent site; %@ is its registrable domain"), Self.removalHost(for: host, includeSubdomains: true))
        alert.suppressionButton?.state = .off
        return alert
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
                    let alert = makeRemovalConfirmation()
                    let response: NSApplication.ModalResponse
                    if let window {
                        response = await alert.beginSheetModal(for: window)
                    } else {
                        response = alert.runModal()
                    }
                    guard response == .alertFirstButtonReturn else { return }
                    let removalHost = Self.removalHost(
                        for: host, includeSubdomains: alert.suppressionButton?.state == .on)
                    _ = try await service.removeMemories(for: removalHost, profileID: profileID)
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
