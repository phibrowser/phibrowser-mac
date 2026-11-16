// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// The in-place name editor shared by the Settings rename flows (Spaces,
/// profiles, the account name). It takes focus and selects the whole name as
/// soon as it lands in a window. Enter asks `onSubmit`, which returns false to
/// keep the field open on an invalid name; Escape, a click anywhere outside the
/// field, or the field losing focus cancels. Validation, the inline error
/// message and saving stay with the caller, which owns the rules for its name.
///
/// Every edit ends exactly once: after `onSubmit` accepts or `onCancel` runs,
/// the field ignores further input until the caller removes it. A field taken
/// out of its window mid-edit cancels on the next main-queue turn, so a SwiftUI
/// caller is never mutated during a view update.
final class InlineRenameTextField: NSTextField, NSTextFieldDelegate {
    var onSubmit: ((String) -> Bool)?
    var onCancel: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    private var mouseMonitor: Any?
    private var hasBegun = false
    private var isFinished = false

    init(text: String, font: NSFont) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = .labelColor
        isEditable = true
        isSelectable = true
        isBezeled = false
        isBordered = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeMouseMonitor()
            if hasBegun && !isFinished {
                isFinished = true
                DispatchQueue.main.async { [onCancel] in onCancel?() }
            }
            return
        }
        guard !hasBegun else { return }
        hasBegun = true
        installMouseMonitor()
        // Wait one turn: SwiftUI and Auto Layout place the field after it is
        // attached, and taking focus before that selects nothing.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isFinished, self.window?.makeFirstResponder(self) == true else { return }
            // Select through the field editor: `selectText(_:)` on a field
            // that is already editing ends that edit first, which would read
            // as a cancel.
            self.currentEditor()?.selectAll(nil)
        }
    }

    // MARK: Ending the edit

    private func submit() {
        guard !isFinished else { return }
        // Finished before asking: a caller that removes the field while saving
        // must not see that removal as a cancel.
        isFinished = true
        guard onSubmit?(stringValue) ?? true else {
            isFinished = false
            return
        }
        removeMouseMonitor()
    }

    private func cancel() {
        guard !isFinished else { return }
        isFinished = true
        removeMouseMonitor()
        onCancel?()
    }

    // MARK: Click outside

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.isFinished else { return event }
            if event.window === self.window,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                return event
            }
            // Cancel, then let the click through: clicking another row cancels
            // the edit and selects that row in one go.
            self.cancel()
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isFinished else { return }
        onTextChange?(stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus moved away (Tab, or another control took it).
        cancel()
    }
}

/// SwiftUI host for `InlineRenameTextField`. `initialText` seeds the field once;
/// later renders only refresh the callbacks, so typing is never overwritten.
struct InlineRenameField: NSViewRepresentable {
    let initialText: String
    var font: NSFont = .systemFont(ofSize: 13)
    let onTextChange: (String) -> Void
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void

    func makeNSView(context: Context) -> InlineRenameTextField {
        let field = InlineRenameTextField(text: initialText, font: font)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(field)
        return field
    }

    func updateNSView(_ field: InlineRenameTextField, context: Context) {
        update(field)
    }

    private func update(_ field: InlineRenameTextField) {
        field.onTextChange = onTextChange
        field.onSubmit = onSubmit
        field.onCancel = onCancel
    }
}
