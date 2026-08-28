// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

/// Shares a tab's page URL through the system sharing services. Single owner
/// for every share entry point — the File menu item and keyboard shortcut show
/// the `NSSharingServicePicker`, and the address bar menu lists the same
/// services in a Share submenu.
@MainActor
final class PageSharingPresenter: NSObject {
    /// Menu item target that also travels as the item's `representedObject`,
    /// which keeps it alive for the menu's lifetime (`NSMenuItem.target` is
    /// unretained).
    private final class ServiceMenuTarget: NSObject {
        private let service: NSSharingService
        private let items: [Any]

        init(service: NSSharingService, items: [Any]) {
            self.service = service
            self.items = items
        }

        @objc func performShare(_ sender: NSMenuItem) {
            service.perform(withItems: items)
        }
    }

    /// AppKit does not retain the picker while it is on screen; dropping the
    /// reference before the user chooses a service dismisses the menu. The
    /// active presenter therefore holds itself here until the picker reports
    /// a choice (or dismissal) through its delegate.
    private static var activePresenter: PageSharingPresenter?

    private let picker: NSSharingServicePicker

    private init(items: [Any]) {
        picker = NSSharingServicePicker(items: items)
        super.init()
        picker.delegate = self
    }

    /// The URL a tab shares: Reader pages resolve to their source page, and
    /// the result carries the same branding as Copy URL.
    static func shareableURL(for tab: Tab?) -> URL? {
        guard var urlString = tab?.url, !urlString.isEmpty else { return nil }
        urlString = ReaderExtensionBridge.sourceURLString(fromReaderPageURL: urlString) ?? urlString
        return URL(string: URLProcessor.phiBrandEnsuredUrlString(urlString))
    }

    static func canShare(tab: Tab?) -> Bool {
        shareableURL(for: tab) != nil
    }

    /// Shows the picker below `rect` in `anchorView` (the whole view when
    /// `rect` is omitted).
    static func share(url: URL, anchorView: NSView, relativeTo rect: NSRect = .zero) {
        let presenter = PageSharingPresenter(items: [url])
        activePresenter = presenter
        presenter.picker.show(relativeTo: rect, of: anchorView, preferredEdge: .minY)
    }

    /// A submenu listing the sharing services available for `tab`'s page, for
    /// hosting inside another menu. Falls back to a disabled placeholder row
    /// when the tab has nothing shareable or no service accepts the URL.
    ///
    /// `NSSharingServicePicker.standardShareMenuItem` presents the picker
    /// panel rather than listing services inline, so the services are
    /// enumerated directly here.
    static func shareSubmenu(for tab: Tab?) -> NSMenu {
        let submenu = NSMenu(title: NSLocalizedString("browser.addressBarMenu.shareSubmenu.title", value: "Share", comment: "Address bar menu - Share submenu title"))

        guard let url = shareableURL(for: tab) else {
            submenu.addItem(placeholderItem(
                title: NSLocalizedString("browser.addressBarMenu.shareSubmenu.invalidURLPlaceholder", value: "No share actions available", comment: "Address bar menu - Placeholder when the current URL cannot be shared")
            ))
            return submenu
        }

        let items: [Any] = [url]
        let services = NSSharingService.sharingServices(forItems: items)
            .filter { !isReadingList($0) }
        guard !services.isEmpty else {
            submenu.addItem(placeholderItem(
                title: NSLocalizedString("browser.addressBarMenu.shareSubmenu.noServicesPlaceholder", value: "No share actions available", comment: "Address bar menu - Placeholder when no sharing services are available")
            ))
            return submenu
        }

        for service in services {
            let target = ServiceMenuTarget(service: service, items: items)
            let item = NSMenuItem(
                title: service.title,
                action: #selector(ServiceMenuTarget.performShare(_:)),
                keyEquivalent: ""
            )
            item.image = service.image
            item.target = target
            item.representedObject = target
            submenu.addItem(item)
        }
        return submenu
    }

    private static func placeholderItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Safari's Reading List has no meaning from inside another browser.
    private nonisolated static func isReadingList(_ service: NSSharingService) -> Bool {
        service.title == NSSharingService(named: .addToSafariReadingList)?.title
    }
}

extension PageSharingPresenter: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        proposedServices.filter { !PageSharingPresenter.isReadingList($0) }
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        // `service` is nil when the picker is dismissed without a choice;
        // either way the picker is off screen and can be released.
        MainActor.assumeIsolated {
            PageSharingPresenter.activePresenter = nil
        }
    }
}
