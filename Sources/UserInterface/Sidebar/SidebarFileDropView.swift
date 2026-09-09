// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

final class SidebarFileDropView: ColoredVisualEffectView {
    var onOpenFiles: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        operation(for: sender) == .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy),
              let onOpenFiles else { return false }
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onOpenFiles(urls)
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard onOpenFiles != nil,
              sender.draggingSourceOperationMask.contains(.copy),
              !Self.fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        return .copy
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        // Keep MIME detection and preview/download decisions in Chromium, just
        // like a file navigation from WebContents. Only consume real file URLs,
        // leaving internal tab/bookmark drags to their existing destinations.
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter(\.isFileURL)
    }
}
