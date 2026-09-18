// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Owned by its originating browser window, keeping navigation and storage in
/// that window's Profile even while another browser window is frontmost.
@MainActor
final class FolioLibraryWindowController: NSWindowController, NSWindowDelegate {
    private weak var browserOwner: MainBrowserWindowController?
    private let model: FolioLibraryModel
    private var refreshTask: Task<Void, Never>?
    private var themeSubscription: AnyCancellable?

    init(owner: MainBrowserWindowController) {
        self.browserOwner = owner
        model = FolioLibraryModel(profileId: owner.browserState.profileId)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = FolioStrings.title
        window.minSize = NSSize(width: 780, height: 560)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FolioLibrary")
        super.init(window: window)
        window.delegate = self
        window.appearance = owner.browserState.themeContext.windowAppearance
        themeSubscription = owner.browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.window?.appearance = self.browserOwner?.browserState.themeContext.windowAppearance
            }
        window.contentViewController = NSHostingController(rootView: FolioLibraryView(
            model: model,
            openURL: { [weak self] in self?.open($0) },
            openArchive: { [weak self] in self?.openArchive($0) },
            reveal: { [weak self] in self?.reveal($0) }))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startRefreshing()
    }

    func windowDidBecomeKey(_ notification: Notification) { startRefreshing() }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
        model.clear()
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.window?.isVisible == true else { return }
                guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else {
                    self.close()
                    return
                }
                await self.model.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func open(_ url: URL) {
        guard FolioLibrary.webURL(url.absoluteString) != nil,
              SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest,
              let owner = browserOwner else { return }
        owner.browserState.createTab(url.absoluteString, customGuid: nil, focusAfterCreate: true)
        owner.window?.makeKeyAndOrderFront(nil)
    }

    private func openArchive(_ item: FolioItem) {
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest, let owner = browserOwner else { return }
        do {
            let url = try FolioLibrary.fileURL(basename: item.basename, ext: "mhtml", folder: model.folder)
            owner.browserState.createTab(url.absoluteString, customGuid: nil, focusAfterCreate: true)
            owner.window?.makeKeyAndOrderFront(nil)
        } catch { model.error = error.localizedDescription }
    }

    private func reveal(_ item: FolioItem?) {
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
        do {
            if let item {
                let url = try FolioLibrary.fileURL(basename: item.basename, ext: "md", folder: model.folder)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                try FileManager.default.createDirectory(at: model.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(model.folder)
            }
        } catch { model.error = error.localizedDescription }
    }
}
