// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

#if DEBUG
/// Development aid: `-phi-auto-reader` opens Reader View on the first content
/// tab shortly after it loads.
///
/// macOS refuses synthesized keystrokes without an Accessibility grant, so
/// without this there is no way to exercise Reader View unattended. Debug
/// builds only.
private enum ReaderAutoTrigger {
    @MainActor static var hasFired = false
    static let launchArgument = "-phi-auto-reader"

    /// Optional `-phi-auto-reader-url <substring>`. Without it the trigger
    /// takes the first content tab, which on a machine with a restored
    /// session is whatever the previous run left open rather than the page
    /// under test.
    static var urlNeedle: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "\(launchArgument)-url"),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

extension BrowserState {
    @MainActor
    func triggerAutoReaderIfRequested(for tab: Tab) {
        guard ProcessInfo.processInfo.arguments
                .contains(ReaderAutoTrigger.launchArgument),
              !ReaderAutoTrigger.hasFired,
              // Restoring a session shows every restored tab, so without this
              // the reader opens on whichever matching tab was restored first
              // and the tab on screen is left showing the live page — which
              // looks exactly like the reader having failed.
              tab.isActive,
              let url = tab.url, !url.isEmpty, !url.isLocalUrlString else {
            return
        }
        if let needle = ReaderAutoTrigger.urlNeedle, !url.contains(needle) {
            return
        }
        ReaderAutoTrigger.hasFired = true
        Task { @MainActor [weak self, weak tab] in
            // Let the page finish its own load before asking for the reader.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let tab else { return }
            self.toggleReaderView(for: tab, from: .automation)
        }
    }
}
#endif

/// Reader View lives in the Phi Reader extension (`phi-ai/ai-extension/
/// reader`): it extracts in-page and navigates the tab to its own reading
/// surface. The app's part is intent — these entry points relay the user's
/// ask over the bridge, and `ReaderExtensionBridge` carries the state and
/// failure reports back.
extension BrowserState {

    /// Right-click "Open in Reading Mode" from the web content's own context
    /// menu, routed through the bridge because that menu is Chromium's.
    ///
    /// Enters rather than toggles: the item is only reachable by right-clicking
    /// the live page, which is what is on screen when the reader is closed, so
    /// a toggle here could only ever mean "open". Saying so keeps that true if
    /// the command ever gains a second entry point.
    @MainActor
    func handleOpenReaderView(tabId: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else {
            AppLogDebug("[Reader] context menu named an unknown tab: \(tabId)")
            return
        }
        guard !tab.extensionReaderActive,
              readerOverlayState.reader(forOrigin: tab.guid) == nil,
              !hasPendingReaderOverlayRequest(forOrigin: tab.guid) else { return }
        ReaderViewAnalytics.noteOpenRequested(for: tab, from: .contextMenu)
        noteReaderOverlayRequested(forOrigin: tab.guid)
        ReaderExtensionBridge.open(tab)
    }

    /// Toggles Reader View for a tab, by relaying the intent to the Phi
    /// Reader extension. The extension answers an open by creating a tab on
    /// its reading surface, which the app hosts as a full-pane overlay over
    /// this tab (see the "Reader View overlay" section in `BrowserState`).
    /// A refused open comes back as a `reader.state` report, which shows
    /// the failure toast — the tab is never left in a half-entered state
    /// because nothing here changes until the extension's surface actually
    /// mounts.
    @MainActor
    func toggleReaderView(for tab: Tab,
                          from entryPoint: ReaderViewAnalytics.EntryPoint) {
        if readerOverlayState.reader(forOrigin: tab.guid) != nil {
            // The overlay is app-hosted: closing its tab directly is the
            // whole close (the extension cleans its cache on tab removal).
            closeReaderOverlay(forOrigin: tab.guid)
        } else if tab.extensionReaderActive {
            // Legacy in-place surface (a reader tab restored from an older
            // session): the extension navigates it back.
            ReaderExtensionBridge.close(tab)
        } else {
            // Swallow a repeat press while an open is still extracting — a
            // second request would spawn a duplicate surface tab.
            guard !hasPendingReaderOverlayRequest(forOrigin: tab.guid) else { return }
            ReaderViewAnalytics.noteOpenRequested(for: tab, from: entryPoint)
            noteReaderOverlayRequested(forOrigin: tab.guid)
            ReaderExtensionBridge.open(tab)
        }
    }
}
