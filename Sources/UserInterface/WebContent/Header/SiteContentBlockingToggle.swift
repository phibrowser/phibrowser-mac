// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// The "Content blocking on this site" row of the address bar menu.
///
/// The row flips a site exception for the current page's registrable domain
/// through `ContentBlockingSettings`; Chromium owns the domain rule and the
/// stored list. Private windows get no row: the bridge addresses a profile by
/// its on-disk name, so an exception set from one would persist in the
/// regular profile instead of staying in the window.
@MainActor
struct SiteContentBlockingToggle {
    let domain: String
    let settings: ContentBlockingSettings

    static var title: String {
        NSLocalizedString("browser.addressBarMenu.contentBlocking.toggle", value: "Content blocking on this site", comment: "Address bar menu - Checkmark item that turns ad, tracker and cookie banner blocking off or on for the current website")
    }

    static func current(browserState: BrowserState?, urlString: String) -> Self? {
        guard let browserState else { return nil }
        return Self(urlString: urlString, profileId: browserState.profileId,
                    isIncognito: browserState.isIncognito,
                    settings: ContentBlockingSettings(profileId: browserState.profileId))
    }

    init?(urlString: String, profileId: String, isIncognito: Bool, settings: ContentBlockingSettings) {
        guard !isIncognito, !profileId.isEmpty,
              let domain = settings.siteExceptionDomain(forURL: urlString) else { return nil }
        self.domain = domain
        self.settings = settings
    }

    /// True when blocking applies to the site, false when it is excepted,
    /// nil while the profile's state has not been read yet.
    var isBlocking: Bool? {
        settings.state.map { !$0.siteExceptions.contains(domain) }
    }

    var menuState: NSControl.StateValue {
        isBlocking.map { $0 ? .on : .off } ?? .mixed
    }

    /// Flips the exception. `completion` reports whether Chromium accepted
    /// the change.
    func toggle(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let isBlocking else {
            completion(false)
            return
        }
        settings.setSiteException(domain, enabled: isBlocking, completion: completion)
    }

    /// Builds the menu item. It starts indeterminate and disabled, asks the
    /// bridge for the profile's state, and updates itself while the menu is
    /// open; `onToggled` runs after Chromium accepts a flip.
    func makeMenuItem(onToggled: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        item.state = menuState
        item.isEnabled = isBlocking != nil
        let target = MenuItemTarget(toggle: self, onToggled: onToggled)
        target.subscription = settings.$state.receive(on: DispatchQueue.main).sink { [weak item] _ in
            guard let item else { return }
            item.state = self.menuState
            item.isEnabled = self.isBlocking != nil
        }
        item.representedObject = target
        item.target = target
        item.action = #selector(MenuItemTarget.toggleSiteBlocking(_:))
        settings.refresh()
        return item
    }

    @MainActor
    private final class MenuItemTarget: NSObject {
        let toggle: SiteContentBlockingToggle
        let onToggled: () -> Void
        var subscription: AnyCancellable?

        init(toggle: SiteContentBlockingToggle, onToggled: @escaping () -> Void) {
            self.toggle = toggle
            self.onToggled = onToggled
        }

        // Not `perform(_:)`: that name is NSObject's `performSelector:`, and
        // `#selector` resolves to it, so the click would never arrive here.
        @objc func toggleSiteBlocking(_ sender: NSMenuItem) {
            toggle.toggle { accepted in
                // The facade completes on the main queue.
                MainActor.assumeIsolated {
                    if accepted { self.onToggled() }
                }
            }
        }
    }
}
