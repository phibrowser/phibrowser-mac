// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Card ordering is local to the horizontal strip. Keeping its handle separate
/// leaves row controls and future bookmark pasteboard drags independent.
struct LibrarySpaceDragHandle: NSViewRepresentable {
    let spaceID: String
    let tint: NSColor
    let onBegin: () -> Void
    let onMove: (CGFloat) -> Void
    let onEnd: (Bool) -> Void
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.spaceID = spaceID
        view.symbol.contentTintColor = tint
        view.hoveredColor = ThemedColor.hover.resolve(theme: theme, appearance: appearance)
        view.needsDisplay = true
        view.onBegin = onBegin
        view.onMove = onMove
        view.onEnd = onEnd
        view.toolTip = NSLocalizedString("library.spaces.reorder", value: "Drag to reorder Space", comment: "Library Spaces - card drag handle tooltip")
        view.symbol.setAccessibilityLabel(view.toolTip)
    }

    final class Handle: HoverableView {
        let symbol = NSImageView()
        var spaceID = ""
        var onBegin: () -> Void = {}
        var onMove: (CGFloat) -> Void = { _ in }
        var onEnd: (Bool) -> Void = { _ in }
        private var start: NSPoint?
        private(set) var isDragging = false
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            responseToClickAction = false
            layer?.cornerRadius = 12
            symbol.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)
            symbol.imageScaling = .scaleProportionallyDown
            symbol.autoresizingMask = [.width, .height]
            symbol.frame = bounds
            addSubview(symbol)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) == nil ? nil : self
        }
        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            AppLogInfo("[LibrarySpaces] drag.mouseDown space=\(spaceID) window=\(window?.windowNumber ?? -1) point=\(event.locationInWindow)")
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let delta = event.locationInWindow.x - start.x
            guard isDragging || abs(delta) > 4 else { return }
            if !isDragging {
                isDragging = true
                let focused = window?.makeFirstResponder(self) ?? false
                AppLogInfo("[LibrarySpaces] drag.threshold space=\(spaceID) deltaX=\(delta) focused=\(focused)")
                onBegin()
            }
            onMove(delta)
        }
        override func mouseUp(with event: NSEvent) {
            AppLogInfo("[LibrarySpaces] drag.mouseUp space=\(spaceID) dragging=\(isDragging) point=\(event.locationInWindow)")
            finish(commit: true)
        }
        override func cancelOperation(_ sender: Any?) {
            AppLogInfo("[LibrarySpaces] drag.cancel space=\(spaceID) dragging=\(isDragging)")
            finish(commit: false)
        }
        private func finish(commit: Bool) {
            start = nil
            guard isDragging else { return }
            isDragging = false
            onEnd(commit)
        }
    }
}
