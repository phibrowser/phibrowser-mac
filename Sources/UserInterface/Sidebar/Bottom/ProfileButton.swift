// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Shared avatar control for the sidebar and horizontal tab strip.
struct ProfileButton: NSViewRepresentable {
    enum Surface {
        case sidebar
        case tabStrip
    }

    let surface: Surface

    func makeNSView(context: Context) -> AvatarButton {
        let button = AvatarButton(frame: .zero)
        button.surface = surface
        return button
    }

    func updateNSView(_ nsView: AvatarButton, context: Context) {
        nsView.surface = surface
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AvatarButton, context: Context) -> CGSize? {
        CGSize(width: 24, height: 24)
    }

    final class AvatarButton: NSButton {
        var surface: Surface = .sidebar

        // NSButton otherwise derives its minimum size from the full-resolution
        // avatar, which can overflow a fixed SwiftUI frame.
        override var intrinsicContentSize: NSSize {
            NSSize(width: 24, height: 24)
        }

        private var cancellables = Set<AnyCancellable>()
        private var requestedDownloads = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            title = ""
            isBordered = false
            imagePosition = .imageOnly
            imageScaling = .scaleProportionallyUpOrDown
            wantsLayer = true
            layer?.cornerRadius = 12
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(resource: .commonBorder).cgColor
            toolTip = NSLocalizedString("profile.button.accessibilityLabel", value: "Profile menu", comment: "Profile button - Opens the account and browser actions menu")
            setAccessibilityLabel(toolTip)
            setAccessibilityIdentifier("profile.menuButton")
            target = self
            action = #selector(showProfileMenu)
            for name in [AccountController.avatarDidChange, .mainAccountChanged, .browserAccessStateDidChange] {
                NotificationCenter.default.publisher(for: name)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.updateAvatar() }
                    .store(in: &cancellables)
            }
            updateAvatar()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func updateAvatar() {
            // AccountController warms this owner-checked cache from disk before
            // refreshing remotely, and publishes editor saves through the same path.
            let controller = AccountController.shared
            if !ApplicationState.shared.isGuest,
               let account = controller.account,
               let data = controller.avatarPNG(for: account),
               let avatar = NSImage(data: data) {
                image = avatar
            } else {
                image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            }
        }

        @objc private func selectDownloads() {
            requestedDownloads = true
        }

        @objc private func showProfileMenu() {
            // Existing menu actions resolve the active browser window. Activate
            // the clicked surface first, including when it was a background window.
            window?.makeKeyAndOrderFront(nil)
            let menu = NSMenu()
            AppController.shared.populateProfileMenu(menu)
            if let downloads = menu.item(withTag: CommandWrapper.IDC_SHOW_DOWNLOADS.rawValue) {
                downloads.target = self
                downloads.action = #selector(selectDownloads)
            }
            requestedDownloads = false
            // NSButton uses flipped coordinates, and NSMenu anchors its top edge.
            let y = surface == .sidebar ? bounds.minY - menu.size.height - 5 : bounds.maxY + 5
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: y), in: self)
            // Start after native menu tracking ends, so it cannot cover the flight.
            if requestedDownloads {
                requestedDownloads = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window,
                          let owner = SpaceSessionControllersManager.shared.findControllerWith(window: window) else { return }
                    owner.showLibrary(from: self, section: .downloads)
                }
            }
        }
    }
}
