// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

final class ImagePreviewWindowController: NSWindowController, NSWindowDelegate {
    let state: BrowserImagePreviewState
    // Keep the preview alive independently of its originating browser window.
    private var retainedWhileOpen: ImagePreviewWindowController?

    init(items: [ImagePreviewItem], currentIndex: Int, loader: ImagePreviewLoading = ImagePreviewLoader()) {
        state = BrowserImagePreviewState(loader: loader)
        let preview = ImagePreviewViewController(state: state, showsPanelFrame: false)
        let contentSize = NSSize(width: 960, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString(
            "imagePreview.windowTitle",
            value: "Image Preview",
            comment: "Image preview - Title of the separate image viewer window"
        )
        window.contentMinSize = NSSize(width: 360, height: 280)
        window.isReleasedWhenClosed = false
        window.contentViewController = preview
        window.setContentSize(contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        preview.onClose = { [weak self] in self?.close() }
        state.open(items: items, currentIndex: currentIndex)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        super.showWindow(sender)
        // External callers may open a preview while another application is active.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(contentViewController?.view)
    }

    func windowWillClose(_ notification: Notification) {
        state.close()
        retainedWhileOpen = nil
    }
}
