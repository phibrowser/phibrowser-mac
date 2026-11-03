// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class OmniBoxWordSelectionTests: XCTestCase {
    private func withEditor(text: String = "www.google.com",
                            _ body: (OmniBoxTextField, NSTextView, NSWindow) throws -> Void) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let input = OmniBoxTextField(frame: NSRect(x: 0, y: 0, width: 680, height: 30))
        window.contentView?.addSubview(input)
        input.layoutSubtreeIfNeeded()
        input.updateDisplayText(text)
        XCTAssertTrue(window.makeFirstResponder(input))
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)
        try body(input, editor, window)
    }

    private func selectionRange(in view: NSTextView, forProposedRange range: NSRange,
                                granularity: NSSelectionGranularity) -> NSRange {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(content.documentRange.location, offsetBy: NSMaxRange(range)),
              let textRange = NSTextRange(location: start, end: end) else {
            XCTFail("Expected an active TextKit 2 selection context")
            return NSRange(location: NSNotFound, length: 0)
        }
        let selection = NSTextSelection(range: textRange, affinity: .downstream, granularity: .character)
        let target: NSTextSelection.Granularity
        switch granularity {
        case .selectByWord: target = .word
        case .selectByParagraph: target = .paragraph
        default: target = .character
        }
        let expanded = layout.textSelectionNavigation.textSelection(for: target, enclosing: selection)
        guard let result = expanded.textRanges.first else {
            XCTFail("Expected a selection range")
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: content.offset(from: content.documentRange.location, to: result.location),
                       length: content.offset(from: result.location, to: result.endLocation))
    }

    private func drainUpdates() {
        let delivered = expectation(description: "Selection updates delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
    }

    func testURLWordsCanBeSelectedIndependently() throws {
        let text = "https://www.google.com:8443/docs/my-page.html?q=hello+world&user_id=42#section-2"
        try withEditor(text: text) { _, editor, _ in
            let source = text as NSString
            for word in ["https", "www", "google", "com", "8443", "docs", "my", "page", "html",
                         "q", "hello", "world", "user_id", "42", "section", "2"] {
                let expected = source.range(of: word, options: .backwards)
                XCTAssertNotEqual(expected.location, NSNotFound)
                for position in expected.location..<NSMaxRange(expected) {
                    XCTAssertEqual(selectionRange(in: editor, forProposedRange: NSRange(location: position, length: 0),
                                                         granularity: .selectByWord), expected,
                                   "Word \(word), position \(position)")
                }
            }
        }
    }

    func testPartialURLsAndSearchTextUseTheSameWordBoundaries() throws {
        for (text, word) in [("www.google", "google"), ("/docs/my-page", "page"),
                             ("?user_id=hello_world", "hello_world"), ("#/settings/account", "settings"),
                             ("search foo.bar today", "bar"), ("127.0.0.1", "127")] {
            try withEditor(text: text) { _, editor, _ in
                let expected = (text as NSString).range(of: word)
                XCTAssertEqual(selectionRange(in: editor, forProposedRange: NSRange(location: expected.location, length: 0),
                                                     granularity: .selectByWord), expected, text)
            }
        }
    }

    func testDomainDotsDoNotSelectAdjacentWords() throws {
        try withEditor { _, editor, _ in
            for position in [3, 10] {
                XCTAssertEqual(selectionRange(in: editor, forProposedRange: NSRange(location: position, length: 0),
                                                     granularity: .selectByWord),
                               NSRange(location: position, length: 1))
            }
        }
    }

    func testWordExpansionAcrossSeveralComponentsPreservesTheProposedRange() throws {
        let text = "https://www.google.com/docs/my-page?q=hello_world#section"
        try withEditor(text: text) { _, editor, _ in
            let source = text as NSString
            let first = source.range(of: "google")
            let last = source.range(of: "docs")
            let proposed = NSRange(location: first.location + 2,
                                   length: NSMaxRange(last) - 2 - first.location - 2)
            XCTAssertEqual(selectionRange(in: editor, forProposedRange: proposed, granularity: .selectByWord),
                           NSUnionRange(first, last))
        }
    }

    func testNativeUnicodeAndOtherSelectionGranularitiesArePreserved() throws {
        let text = "cafe\u{301} \u{4E2D}\u{6587} \u{1F469}\u{200D}\u{1F4BB} hello_world"
        try withEditor(text: text) { _, editor, _ in
            let native = NSTextView.fieldEditor()
            native.string = text
            for granularity: NSSelectionGranularity in [.selectByCharacter, .selectByWord, .selectByParagraph] {
                for position in 0...(text as NSString).length {
                    let proposed = NSRange(location: position, length: 0)
                    XCTAssertEqual(selectionRange(in: editor, forProposedRange: proposed, granularity: granularity),
                                   selectionRange(in: native, forProposedRange: proposed, granularity: granularity),
                                   "Granularity \(granularity), position \(position)")
                }
            }
        }
    }

    func testEmptyTextAndEndOfURLSelection() throws {
        try withEditor(text: "") { _, editor, _ in
            XCTAssertEqual(selectionRange(in: editor, forProposedRange: NSRange(location: 0, length: 0),
                                                 granularity: .selectByWord), NSRange(location: 0, length: 0))
        }
        try withEditor { _, editor, _ in
            XCTAssertEqual(selectionRange(in: editor, forProposedRange: NSRange(location: 13, length: 0),
                                          granularity: .selectByWord), NSRange(location: 11, length: 3))
            let native = NSTextView.fieldEditor()
            native.string = editor.string
            let end = NSRange(location: 14, length: 0)
            XCTAssertEqual(selectionRange(in: editor, forProposedRange: end, granularity: .selectByWord),
                           selectionRange(in: native, forProposedRange: end, granularity: .selectByWord))
        }
    }

    func testWordNavigationKeepsNativeKeyboardBoundaries() throws {
        try withEditor(text: "www.google.com/docs?q=hello_world#section") { _, editor, _ in
            let native = NSTextView.fieldEditor()
            native.string = editor.string
            for position in 0...(editor.string as NSString).length {
                for moveRight in [false, true] {
                    for view in [editor, native] {
                        view.setSelectedRange(NSRange(location: position, length: 0))
                        if moveRight { view.moveWordRight(nil) } else { view.moveWordLeft(nil) }
                    }
                    XCTAssertEqual(editor.selectedRange, native.selectedRange,
                                   "Position \(position), moveRight \(moveRight)")
                }
            }
        }
    }

    func testMarkedTextUsesNativeWordSelection() throws {
        try withEditor { _, editor, _ in
            let native = NSTextView.fieldEditor()
            native.string = editor.string
            let replacement = NSRange(location: 0, length: (editor.string as NSString).length)
            for view in [editor, native] {
                view.setMarkedText("www.google.com", selectedRange: NSRange(location: 6, length: 0),
                                   replacementRange: replacement)
            }
            XCTAssertTrue(editor.hasMarkedText())
            let proposed = NSRange(location: 6, length: 0)
            XCTAssertEqual(selectionRange(in: editor, forProposedRange: proposed, granularity: .selectByWord),
                           selectionRange(in: native, forProposedRange: proposed, granularity: .selectByWord))
        }
    }

    func testInlineCompletionAndSavedWordSelectionUseTheActiveEditor() throws {
        try withEditor(text: "www.g") { input, editor, _ in
            input.updateSelection(inlineCompletString: "oogle.com", fillString: "www.google.com",
                                  canUseTempString: false, inlineCompletionEnabled: true)
            XCTAssertEqual(editor.string, "www.google.com")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 5, length: 9))
            drainUpdates()

            let word = selectionRange(in: editor, forProposedRange: NSRange(location: 6, length: 0),
                                             granularity: .selectByWord)
            editor.setSelectedRange(word)
            input.updateSelection(inlineCompletString: nil, fillString: nil,
                                  canUseTempString: false, inlineCompletionEnabled: false)
            XCTAssertEqual(editor.string, "www.google.com")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 6))
            input.selectAll()
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 14))
            input.selectToEnd()
            XCTAssertEqual(editor.selectedRange, NSRange(location: 14, length: 0))
        }
    }

    func testTemporarySuggestionUsesTheActiveEditor() throws {
        try withEditor(text: "example") { input, editor, _ in
            input.updateSelection(inlineCompletString: nil, fillString: "https://example.com/docs",
                                  canUseTempString: true, inlineCompletionEnabled: false)
            XCTAssertEqual(editor.string, "https://example.com/docs")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 24, length: 0))
        }
    }

    func testOtherFieldsKeepTheirNativeEditorAndInactiveUpdatesDoNotAffectThem() throws {
        try withEditor { input, editor, window in
            let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 400, height: 30))
            other.stringValue = "www.google.com"
            window.contentView?.addSubview(other)
            XCTAssertTrue(window.makeFirstResponder(other))
            let otherEditor = try XCTUnwrap(other.currentEditor() as? NSTextView)
            XCTAssertFalse(editor === otherEditor)
            XCTAssertNil(input.textFiled.currentEditor())
            let native = NSTextView.fieldEditor()
            native.string = other.stringValue
            let proposed = NSRange(location: 6, length: 0)
            XCTAssertEqual(selectionRange(in: otherEditor, forProposedRange: proposed, granularity: .selectByWord),
                           selectionRange(in: native, forProposedRange: proposed, granularity: .selectByWord))
            otherEditor.setSelectedRange(NSRange(location: 6, length: 0))

            input.selectAll()
            input.selectToEnd()
            input.updateSelection(inlineCompletString: "ignored", fillString: "ignored",
                                  canUseTempString: true, inlineCompletionEnabled: true)
            XCTAssertEqual(otherEditor.string, "www.google.com")
            XCTAssertEqual(otherEditor.selectedRange, NSRange(location: 6, length: 0))
        }
    }
}
