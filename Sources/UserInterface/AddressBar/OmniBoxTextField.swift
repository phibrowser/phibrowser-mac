// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

/*
 OmniBox Autocompletion Design (following Chromium's model)

 Key concepts:
 - originalText: User's actual input (equivalent to Chromium's user_text_)
 - inlineCompletionString: Text appended to originalText for default suggestion (selected/highlighted)
 - fillString: Complete text for non-default suggestions (temporary text)

 Text display modes:
 1. Default suggestion: originalText + inlineCompletionString (with inline part selected)
 2. Non-default suggestion (via arrow keys): fillString as temporary text
 3. No suggestion: originalText only

 State management:
 - suppressSelectionSave: Prevents saving selection during programmatic changes
 - inlineCompletionSelection: Tracks the selected inline completion range
 - savedSelection: Preserves user's cursor position for restoration

 When user accepts inline completion (e.g., pressing right arrow), originalText is updated
 to the full text. When navigating with arrow keys, fillString is shown temporarily without
 modifying originalText, allowing restoration on cancel.
 */

import Cocoa

protocol OmniBoxTextFieldDelegate: AnyObject {
    func omniBoxTextFieldDidChange(_ textField: OmniBoxTextField, suppressAutoComplete: Bool)
    func omniBoxTextFieldDidBeginEditing(_ textField: OmniBoxTextField)
    func omniBoxTextFieldDidEndEditing(_ textField: OmniBoxTextField)
    func omniBoxTextFieldDidReceiveMoveDownEvent(_ textField: OmniBoxTextField) -> Bool
    func omniBoxTextFieldDidReceiveMoveUpEvent(_ textField: OmniBoxTextField) -> Bool
    func omniBoxTextFieldDidReceiveEnterEvent(_ textField: OmniBoxTextField) -> Bool
}

class OmniBoxTextField: NSView {
    
    weak var omniBoxDelegate: OmniBoxTextFieldDelegate?
    
    let textFiled: NSTextField = NSTextField()
    
    private var originalText = ""
    // Preserve user caret/selection when toggling inline/temp strings
    private var savedSelection: NSRange? = nil
    private var inlineCompletionSelection: NSRange? = nil
    private var suppressSelectionSave = false
    var stringValue: String {
        get { textFiled.stringValue }
        set { textFiled.stringValue = newValue }
    }
    
    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textFiled)
        return true
    }
    
    override func resignFirstResponder() -> Bool {
        return true
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        setupTextField()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextField()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextField()
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    private func setupTextField() {
        textFiled.isBezeled = false
        textFiled.isBordered = false
        textFiled.backgroundColor = NSColor.clear
        textFiled.textColor = NSColor.labelColor
        textFiled.font = NSFont.systemFont(ofSize: 13)
        textFiled.focusRingType = .none
        textFiled.lineBreakMode = .byTruncatingTail
        textFiled.cell?.truncatesLastVisibleLine = true
        textFiled.cell?.wraps = false
        textFiled.delegate = self

        let placeholder = NSMutableAttributedString(string: NSLocalizedString("Search or Enter URL", comment: "Omnibox - Placeholder text prompting user to search or enter URL"))
        placeholder.addAttributes([
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 16)
        ], range: NSRange(location: 0, length: placeholder.length))
        textFiled.placeholderAttributedString = placeholder
        addSubview(textFiled)
        
        textFiled.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(textViewDidChangeSelection(_:)),
                                               name: NSTextView.didChangeSelectionNotification,
                                               object: nil)
    }
    
    
    func updateDisplayText(_ text: String, isURL: Bool = false) {
        self.originalText = text
        self.stringValue = text
    }
    
    func selectAll() {
        if let fieldEditor = window?.fieldEditor(true, for: self) {
            fieldEditor.selectAll(nil)
        }
    }
    
    func selectToEnd() {
        if let fieldEditor = window?.fieldEditor(true, for: self) {
            let length = textFiled.stringValue.count
            fieldEditor.selectedRange = NSRange(location: length, length: 0)
        }
    }
}

// MARK: - Suggestion Handling

extension OmniBoxTextField {
    func updateSelection(inlineCompletString: String?, fillString: String?, canUseTempString: Bool, inlineCompletionEnabled: Bool) {
        guard let fieldEditor = window?.fieldEditor(false, for: self) else {
            return
        }
        
        AppLogDebug("[Omnibox] updateSelection inline:\(String(describing: inlineCompletString)), fill:\(String(describing: fillString)), canUseTmp:\(canUseTempString), inlineEnabled:\(inlineCompletionEnabled), originalText:\(originalText)")
        
        suppressSelectionSave = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressSelectionSave = false
        }
        
        // Non-default suggestions use `fillString` as temporary text. Default suggestions use inline completion.
        if canUseTempString, let fill = fillString, !fill.isEmpty {
            if fieldEditor.string != fill {
                fieldEditor.string = fill
            }
            let fillLen = (fill as NSString).length
            fieldEditor.selectedRange = NSRange(location: fillLen, length: 0)
            inlineCompletionSelection = nil
            return
        }

        if let inline = inlineCompletString, !inline.isEmpty, inlineCompletionEnabled {
            let base = originalText

            // Prevent duplicate completion when the user already accepted the same suggestion.
            if let fill = fillString {
                let baseNormalized = base.normalizedForURLComparison()
                let fillNormalized = fill.normalizedForURLComparison()
                if baseNormalized == fillNormalized {
                    if fieldEditor.string != base {
                        fieldEditor.string = base
                    }
                    fieldEditor.selectedRange = NSRange(location: (base as NSString).length, length: 0)
                    inlineCompletionSelection = nil
                    AppLogDebug("[Omnibox] skipping inline, base already matches fill: \(base) (normalized: \(baseNormalized))")
                    return
                }
            }

            let combined = base + inline
            if combined != fieldEditor.string {
                fieldEditor.string = combined
            }
            let baseLen = (base as NSString).length
            let inlineLen = (inline as NSString).length
            let completionRange = NSRange(location: baseLen, length: inlineLen)
            fieldEditor.selectedRange = completionRange
            inlineCompletionSelection = completionRange
            return
        }

        AppLogDebug("[Omnibox] updateSelection restore origin:\(originalText), current:\(fieldEditor.string)")
        if fieldEditor.string != originalText {
            fieldEditor.string = originalText
        }
        let origLen = (originalText as NSString).length
        let target = savedSelection ?? NSRange(location: origLen, length: 0)
        let loc = min(max(0, target.location), origLen)
        let len = min(max(0, target.length), max(0, origLen - loc))
        suppressSelectionSave = true
        fieldEditor.selectedRange = NSRange(location: loc, length: len)
        inlineCompletionSelection = nil
    }
}

extension OmniBoxTextField: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSTextField == self.textFiled else {
            return
        }
        savedSelection = NSRange(location: (stringValue as NSString).length, length: 0)
        omniBoxDelegate?.omniBoxTextFieldDidBeginEditing(self)
    }
    
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField == self.textFiled else {
            return
        }
        AppLogDebug("controlTextDidEndEditing: \(stringValue)")
        originalText = stringValue
        omniBoxDelegate?.omniBoxTextFieldDidEndEditing(self)
    }
    
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField == self.textFiled else {
            return
        }

        if let fieldEditor = window?.fieldEditor(false, for: textFiled) {
            savedSelection = fieldEditor.selectedRange
            suppressSelectionSave = false
        }

        let newText = stringValue
        AppLogDebug("[Omnibox] textDidChange: new:\(newText), old:\(originalText), savedSel:\(String(describing: savedSelection))")

        var suppressAutoComplete = false
        if newText.count < originalText.count || newText == originalText {
            suppressAutoComplete = true
        } else if newText.count > originalText.count {
            suppressAutoComplete = false
        }
        
        originalText = newText
        omniBoxDelegate?.omniBoxTextFieldDidChange(self, suppressAutoComplete: suppressAutoComplete)
    }
    
    @objc func textViewDidChangeSelection(_ noti: Notification) {
        guard let textView = noti.object as? NSTextView,
              let fieldEditor = window?.fieldEditor(false, for: textFiled),
              textView === fieldEditor else {
            return
        }

        let current = textView.selectedRange
        let currentText = textView.string
        
        AppLogDebug("[Omnibox] selectionChanged: \(current) str:\(currentText), suppress:\(suppressSelectionSave)")
        
        if let inlineRange = inlineCompletionSelection,
           inlineRange.length > 0,
           !suppressSelectionSave {
            originalText = currentText
            inlineCompletionSelection = nil
            AppLogDebug("[Omnibox] user modified completion, originalText -> \(currentText)")
        }
        
        if !suppressSelectionSave {
            savedSelection = current
        }
    }
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control as? NSTextField == self.textFiled else {
            return false
        }
        
        let hasInlineCompletion = (inlineCompletionSelection?.length ?? 0) > 0
        
        if commandSelector == #selector(NSTextView.moveUp(_:)) {
            return omniBoxDelegate?.omniBoxTextFieldDidReceiveMoveUpEvent(self) ?? false
        } else if commandSelector == #selector(NSTextView.moveDown(_:)) {
            return omniBoxDelegate?.omniBoxTextFieldDidReceiveMoveDownEvent(self) ?? false
        } else if commandSelector == #selector(NSTextView.insertNewline(_:)) {
            return omniBoxDelegate?.omniBoxTextFieldDidReceiveEnterEvent(self) ?? false
        }
        
        if hasInlineCompletion {
            let modifyingSelectors = [
                #selector(NSTextView.moveRight(_:)),
                #selector(NSTextView.moveLeft(_:)),
                #selector(NSTextView.moveForward(_:)),
                #selector(NSTextView.moveBackward(_:)),
                #selector(NSTextView.deleteBackward(_:)),
                #selector(NSTextView.deleteForward(_:)),
                #selector(NSTextView.moveToBeginningOfLine(_:)),
                #selector(NSTextView.moveToEndOfLine(_:)),
                #selector(NSTextView.moveWordRight(_:)),
                #selector(NSTextView.moveWordLeft(_:))
            ]
            
            if modifyingSelectors.contains(commandSelector) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let fieldEditor = self.window?.fieldEditor(false, for: self) {
                        self.originalText = fieldEditor.string
                        self.inlineCompletionSelection = nil
                        AppLogDebug("[Omnibox] doCommandBy: originalText -> \(self.originalText)")
                    }
                }
            }
        }
        
        return false
    }
    
}
