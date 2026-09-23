// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import Combine

/// Keeps Library navigation and storage attached to its originating browser.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private(set) weak var browserOwner: SpaceSessionController?
    private let module: LibraryViewModule
    private var themeSubscription: AnyCancellable?

    init(parent: NSWindow, browserState: BrowserState) {
        browserOwner = SpaceSessionControllersManager.shared.findControllerWith(window: parent)
        module = LibraryViewModule(browserState: browserState, presentation: .standalone)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
//        window.title = LibraryViewModule.title
        window.minSize = NSSize(width: 840, height: 560)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("Library")
        super.init(window: window)
        window.delegate = self
        window.appearance = browserState.themeContext.windowAppearance
        themeSubscription = browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browserState] _ in
                self?.window?.appearance = browserState?.themeContext.windowAppearance
            }
        module.onDismiss = { [weak parent] in parent?.makeKeyAndOrderFront(nil) }

        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(section: LibraryViewModule.Section? = nil) {
        if let section { module.navigationState.selection = section }
        window?.contentViewController = module
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Detach the host so SwiftUI stops refreshing hidden Library content.
        window?.contentViewController = nil
    }
}
