// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

protocol SearchTabsTextFieldKeyDelegate: AnyObject {
    func searchTabsTextFieldDidMoveDown(_ textField: SearchTabsTextField) -> Bool
    func searchTabsTextFieldDidMoveUp(_ textField: SearchTabsTextField) -> Bool
    func searchTabsTextFieldDidConfirm(_ textField: SearchTabsTextField) -> Bool
    func searchTabsTextFieldDidCancel(_ textField: SearchTabsTextField) -> Bool
}

final class SearchTabsTextField: NSTextField {
    weak var keyDelegate: SearchTabsTextFieldKeyDelegate?

    private let shortcutHintLabel: NSTextField = {
        let label = PassthroughTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .placeholderTextColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    override var stringValue: String {
        didSet {
            updateShortcutHint()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 18, weight: .regular)
        textColor = .labelColor
        placeholderString = NSLocalizedString(
            "Search Tabs",
            comment: "Search Tabs - Placeholder text for the native tab search field"
        )
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        setupShortcutHintLabel()
        updateShortcutHint()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextDidChange(_:)),
            name: NSControl.textDidChangeNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            if keyDelegate?.searchTabsTextFieldDidMoveDown(self) == true { return }
        case 126:
            if keyDelegate?.searchTabsTextFieldDidMoveUp(self) == true { return }
        case 36, 76:
            if keyDelegate?.searchTabsTextFieldDidConfirm(self) == true { return }
        case 53:
            if keyDelegate?.searchTabsTextFieldDidCancel(self) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func setupShortcutHintLabel() {
        addSubview(shortcutHintLabel)
        NSLayoutConstraint.activate([
            shortcutHintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            shortcutHintLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func updateShortcutHint() {
        guard stringValue.isEmpty,
              let shortcut = Shortcuts.key(for: .IDC_TAB_SEARCH)?.displayString,
              !shortcut.isEmpty else {
            shortcutHintLabel.isHidden = true
            return
        }

        shortcutHintLabel.stringValue = shortcut
        shortcutHintLabel.isHidden = false
    }

    @objc private func handleTextDidChange(_ notification: Notification) {
        updateShortcutHint()
    }
}

private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
