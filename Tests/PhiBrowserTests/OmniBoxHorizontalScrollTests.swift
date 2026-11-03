// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class OmniBoxHorizontalScrollTests: XCTestCase {
    private static let longURL = "https://example.com/" + String(repeating: "long-path-component/", count: 30)

    private final class ScrollSpy: NSResponder {
        var events = 0
        let tracker = SpaceSwipeTracker()
        override func scrollWheel(with event: NSEvent) {
            events += 1
            _ = tracker.handle(event)
        }
    }

    private func scrollEvent(x: Int32 = 0, y: Int32 = 0, precise: Bool = true,
                             phase: CGScrollPhase? = .changed,
                             momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                      wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    private func withEditor(text: String = longURL,
                            _ body: (OmniBoxTextField, NSTextView, NSClipView, ScrollSpy) throws -> Void) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let input = OmniBoxTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        window.contentView?.addSubview(input)
        input.layoutSubtreeIfNeeded()
        input.updateDisplayText(text)
        XCTAssertTrue(window.makeFirstResponder(input))
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)
        let clip = try XCTUnwrap(editor.superview as? NSClipView)
        let spy = ScrollSpy()
        let previous = input.textFiled.nextResponder
        input.textFiled.nextResponder = spy
        defer { input.textFiled.nextResponder = previous }
        clip.scroll(to: .zero)
        try body(input, editor, clip, spy)
    }

    func testHorizontalTrackpadEventsScrollTextInBothDirectionsWithoutChangingSelection() throws {
        try withEditor { _, editor, clip, spy in
            let selection = NSRange(location: 4, length: 6)
            editor.setSelectedRange(selection)
            clip.scroll(to: .zero)
            let text = editor.string
            let event = try scrollEvent(x: -40, phase: .began)
            XCTAssertTrue(event.hasPreciseScrollingDeltas)
            XCTAssertEqual(event.phase, .began)
            editor.scrollWheel(with: event)
            XCTAssertEqual(clip.bounds.origin.x, 40, accuracy: 0.01)
            editor.scrollWheel(with: try scrollEvent(x: 25))
            XCTAssertEqual(clip.bounds.origin.x, 15, accuracy: 0.01)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange, selection)
            XCTAssertEqual(spy.events, 0)
        }
    }

    func testBoundariesZeroDeltasAndMomentumStayOwnedByTheInput() throws {
        try withEditor { _, editor, clip, spy in
            editor.scrollWheel(with: try scrollEvent(phase: .mayBegin))
            editor.scrollWheel(with: try scrollEvent(x: 500, phase: .began))
            XCTAssertEqual(clip.bounds.origin.x, 0)
            editor.scrollWheel(with: try scrollEvent(x: -100_000))
            let rightEdge = clip.bounds.origin.x
            XCTAssertGreaterThan(rightEdge, 0)
            XCTAssertLessThanOrEqual(rightEdge, clip.documentRect.width - clip.bounds.width + 0.01)
            editor.scrollWheel(with: try scrollEvent(x: -100_000, phase: .ended))
            let momentum = try scrollEvent(x: -80, phase: nil, momentum: .begin)
            XCTAssertEqual(momentum.momentumPhase, .began)
            editor.scrollWheel(with: momentum)
            editor.scrollWheel(with: try scrollEvent(x: -20, phase: nil, momentum: .continuous))
            editor.scrollWheel(with: try scrollEvent(phase: nil, momentum: .end))
            XCTAssertEqual(clip.bounds.origin.x, rightEdge, accuracy: 0.01)
            XCTAssertEqual(spy.events, 0)
            XCTAssertFalse(spy.tracker.consumesHorizontalGesture)
        }
    }

    func testShortTextAndVerticalEventsDoNotScrollOrReachTheSidebar() throws {
        try withEditor(text: "example.com") { _, editor, clip, spy in
            for event in [try scrollEvent(x: -40, phase: .began), try scrollEvent(x: 40),
                          try scrollEvent(y: -40), try scrollEvent(phase: .cancelled)] {
                editor.scrollWheel(with: event)
            }
            XCTAssertEqual(clip.bounds.origin, .zero)
            XCTAssertEqual(spy.events, 0)
        }
    }

    func testLegacyHorizontalWheelEventsScrollWithoutLeaking() throws {
        try withEditor { _, editor, clip, spy in
            let event = try scrollEvent(x: -3, precise: false, phase: nil)
            XCTAssertFalse(event.hasPreciseScrollingDeltas)
            editor.scrollWheel(with: event)
            XCTAssertGreaterThan(clip.bounds.origin.x, 0)
            XCTAssertEqual(spy.events, 0)
        }
    }

    func testMarkedTextAndCaretArePreservedWhileScrolling() throws {
        try withEditor { _, editor, clip, spy in
            editor.setMarkedText(Self.longURL, selectedRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            let text = editor.string
            let selection = editor.selectedRange
            let marked = editor.markedRange()
            clip.scroll(to: .zero)
            editor.scrollWheel(with: try scrollEvent(x: -40, phase: .began))
            XCTAssertGreaterThan(clip.bounds.origin.x, 0)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange, selection)
            XCTAssertEqual(editor.markedRange(), marked)
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(spy.events, 0)
        }
    }

    func testInactiveInputDoesNotStartEditingOrForwardScrolling() throws {
        let input = OmniBoxTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let spy = ScrollSpy()
        input.textFiled.nextResponder = spy
        input.textFiled.scrollWheel(with: try scrollEvent(x: -40, phase: .began))
        XCTAssertNil(input.textFiled.currentEditor())
        XCTAssertEqual(spy.events, 0)
    }

    func testOverlayBackgroundStopsUnhandledScrollingBeforeTheUnderlyingContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let container = OmniBoxContainerViewController(browserState: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let omnibox = try XCTUnwrap(container.omniBoxController)
        let spy = ScrollSpy()
        container.view.nextResponder = spy
        let background = try XCTUnwrap(omnibox.view.subviews.first)
        background.scrollWheel(with: try scrollEvent(x: -40, phase: .began))
        XCTAssertEqual(spy.events, 0)
        XCTAssertFalse(spy.tracker.consumesHorizontalGesture)
        try await store.closeForAccountDirectoryRemoval()
        try FileManager.default.removeItem(at: directory)
    }
}
