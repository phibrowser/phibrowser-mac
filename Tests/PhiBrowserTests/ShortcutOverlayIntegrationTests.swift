// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Executes the real overlay handlers and BrowserState close paths with native
/// view/responder ownership. Window activation is explicitly controlled here;
/// physical keyboard delivery and Chromium WebContents remain a separate gate.
@MainActor
final class ShortcutOverlayIntegrationTests: XCTestCase {
    private final class TestWindow: NSWindow {
        var ownsKeyboard = true
        override var isKeyWindow: Bool { ownsKeyboard }
        override func makeKey() {} // Never activate a test window on the desktop.
    }

    private final class ContentView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class SurfaceTab: Tab {
        let content = ContentView()
        override var webContentView: NSView? { content }
    }

    private enum Surface: CaseIterable { case peek, reader }

    private struct Fixture {
        let kind: Surface
        let window: TestWindow
        let state: BrowserState
        let origin: SurfaceTab
        let tab: SurfaceTab
        let peek: PeekPanelController?
        let reader: ReaderPanelController?

        var isOpen: Bool {
            switch kind {
            case .peek: return state.peekState.peek(forOpener: origin.guid) === tab
            case .reader: return state.readerOverlayState.reader(forOrigin: origin.guid) === tab
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            peek?.handleKeyEquivalent(event) ?? reader!.handleKeyEquivalent(event)
        }

        func eclipse(_ value: Bool) {
            peek?.setEclipsedByInWindowOverlay(value)
            reader?.setEclipsedByInWindowOverlay(value)
        }

        func hide() {
            peek?.hide()
            reader?.hide()
        }
    }

    private var previousConfiguration: ShortcutConfiguration!
    private var directory: URL!
    private var accountDirectory: URL!
    private var store: LocalStore!

    override func setUp() async throws {
        previousConfiguration = Shortcuts.configuration
        Shortcuts.configuration = ShortcutConfiguration()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "shortcut-overlay-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
    }

    override func tearDown() async throws {
        Shortcuts.configuration = previousConfiguration
        previousConfiguration = nil
        let drained = expectation(description: "Overlay presentation updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func testReboundCloseConsumesOnlyNewKeyAndPreservesOrigin() throws {
        configure([.IDC_CLOSE_TAB: .custom(.init(characters: "k", modifiers: .control))])
        try eachSurface { fixture in
            XCTAssertFalse(fixture.handle(try event("w", modifiers: .command, in: fixture.window)))
            XCTAssertTrue(fixture.isOpen)
            XCTAssertTrue(fixture.handle(try event("k", modifiers: .control, in: fixture.window)))
            assertClosedWithOriginIntact(fixture)
        }
    }

    func testDisabledCloseDoesNotCloseButRestoringDefaultDoes() throws {
        try eachSurface { fixture in
            configure([.IDC_CLOSE_TAB: .disabled])
            let close = try event("w", modifiers: .command, in: fixture.window)
            XCTAssertFalse(fixture.handle(close))
            XCTAssertTrue(fixture.isOpen)
            configure([:])
            XCTAssertTrue(fixture.handle(close))
            assertClosedWithOriginIntact(fixture)
        }
    }

    func testCloseWindowAndAdditionalModifiersAreNotSwallowed() throws {
        try eachSurface { fixture in
            for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control]] {
                XCTAssertFalse(fixture.handle(try event("w", modifiers: flags, in: fixture.window)))
                XCTAssertTrue(fixture.isOpen)
            }
            configure([
                .IDC_CLOSE_TAB: .custom(.init(characters: "w", modifiers: [.command, .shift])),
                .IDC_CLOSE_WINDOW: .custom(.init(characters: "w", modifiers: .command))
            ])
            XCTAssertFalse(fixture.handle(try event("w", modifiers: .command, in: fixture.window)))
            XCTAssertTrue(fixture.isOpen)
            XCTAssertTrue(fixture.handle(try event("w", modifiers: [.command, .shift], in: fixture.window)))
            assertClosedWithOriginIntact(fixture)
            configure([:])
        }
    }

    func testLegacyShiftPunctuationMatchesCloseAndNavigation() throws {
        for command in [CommandWrapper.IDC_CLOSE_TAB, .IDC_BACK, .IDC_FORWARD] {
            configure([command: .custom(.init(characters: "+", modifiers: .command))])
            try eachSurface { fixture in
                XCTAssertTrue(fixture.handle(try event("+", modifiers: [.command, .shift],
                                                       keyCode: 24, in: fixture.window)))
                assertClosedWithOriginIntact(fixture)
            }
        }
        configure([.PHI_TOGGLE_READER: .custom(.init(characters: "+", modifiers: .command))])
        try withSurface(.reader) { fixture in
            XCTAssertTrue(fixture.handle(try event("+", modifiers: [.command, .shift],
                                                   keyCode: 24, in: fixture.window)))
            assertClosedWithOriginIntact(fixture)
        }
    }

    func testModifiedEscapePassesThroughUnlessExplicitlyBound() throws {
        try eachSurface { fixture in
            for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
                XCTAssertFalse(fixture.handle(try event("\u{1b}", modifiers: flags,
                                                        keyCode: 53, in: fixture.window)))
                XCTAssertTrue(fixture.isOpen)
            }
            configure([.IDC_CLOSE_TAB: .custom(.init(characters: "\u{1b}", modifiers: .control))])
            XCTAssertTrue(fixture.handle(try event("\u{1b}", modifiers: .control,
                                                   keyCode: 53, in: fixture.window)))
            assertClosedWithOriginIntact(fixture)
            configure([:])
        }
        try eachSurface { fixture in
            XCTAssertTrue(fixture.handle(try event("\u{1b}", modifiers: [], keyCode: 53, in: fixture.window)))
            assertClosedWithOriginIntact(fixture)
        }
    }

    func testOwnershipRequiresWindowFocusAndVisibleUnobscuredSurface() throws {
        try eachSurface { fixture in
            let close = try event("w", modifiers: .command, in: fixture.window)
            let other = makeWindow()
            defer { other.close() }
            XCTAssertFalse(fixture.handle(try event("w", modifiers: .command, in: other)))
            fixture.window.ownsKeyboard = false
            XCTAssertFalse(fixture.handle(close))
            fixture.window.ownsKeyboard = true
            let outside = ContentView()
            fixture.window.contentView!.addSubview(outside)
            XCTAssertTrue(fixture.window.makeFirstResponder(outside))
            XCTAssertFalse(fixture.handle(close))
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.tab.content))
            fixture.eclipse(true)
            XCTAssertFalse(fixture.handle(close))
            fixture.eclipse(false)
            fixture.hide()
            XCTAssertFalse(fixture.handle(close))
            XCTAssertTrue(fixture.isOpen)
            XCTAssertEqual(fixture.state.tabs.map(\.guid), [fixture.origin.guid])
        }
    }

    func testDevToolsKeepsEscapeAndNavigationButCloseStillProtectsOrigin() throws {
        try eachSurface { fixture in
            let devTools = ContentView()
            let host = try XCTUnwrap(fixture.peek?.devToolsHost(for: fixture.tab)
                                    ?? fixture.reader?.devToolsHost(for: fixture.tab))
            PageOverlayDevToolsDock.attach(devTools, to: fixture.tab, in: host)
            XCTAssertTrue(fixture.window.makeFirstResponder(devTools))
            XCTAssertTrue(PageOverlayDevToolsDock.hasFocus(fixture.tab))
            XCTAssertFalse(fixture.handle(try event("\u{1b}", modifiers: [], keyCode: 53, in: fixture.window)))
            XCTAssertFalse(fixture.handle(try event("[", modifiers: .command, keyCode: 33, in: fixture.window)))
            XCTAssertTrue(fixture.isOpen)
            configure([.IDC_CLOSE_TAB: .custom(.init(characters: "k", modifiers: .control))])
            XCTAssertTrue(fixture.handle(try event("k", modifiers: .control, in: fixture.window)))
            assertClosedWithOriginIntact(fixture)
            configure([:])
        }
    }

    private func configure(_ overrides: [CommandWrapper: ShortcutOverride]) {
        Shortcuts.configuration = ShortcutConfiguration(
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }))
    }

    private func assertClosedWithOriginIntact(_ fixture: Fixture,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.isOpen, file: file, line: line)
        XCTAssertEqual(fixture.state.tabs.map(\.guid), [fixture.origin.guid], file: file, line: line)
        XCTAssertTrue(fixture.state.focusingTab === fixture.origin, file: file, line: line)
    }

    private func eachSurface(_ body: (Fixture) throws -> Void) throws {
        for kind in Surface.allCases { try withSurface(kind, body) }
    }

    private func withSurface(_ kind: Surface, _ body: (Fixture) throws -> Void) throws {
        let window = makeWindow()
        let state = BrowserState(windowId: 987654321, localStore: store,
                                 profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString)
        let session = SpaceSessionController(window: window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: store.account,
            browserState: state, dormant: true)
        window.contentViewController = session.mainSplitViewController
        window.contentView?.layoutSubtreeIfNeeded()
        let anchor = session.mainSplitViewController.webContentContainerViewController.view
        let origin = SurfaceTab(guid: 1001, url: "https://example.test/origin", isActive: true, index: 0)
        let tab = SurfaceTab(guid: 1002, url: "https://example.test/overlay", isActive: false, index: 1)
        state.tabs = [origin]
        state.focusingTab = origin
        let peek: PeekPanelController?
        let reader: ReaderPanelController?
        switch kind {
        case .peek:
            state.peekState.present(tab, openerTabId: origin.guid)
            peek = PeekPanelController(browserState: state, parentWindow: window, anchorView: anchor,
                                       cardViewProvider: { anchor }, headerViewProvider: { nil },
                                       originTracker: nil)
            reader = nil
            peek!.present(tab: tab, flyIn: false)
        case .reader:
            state.readerOverlayState.present(tab, originTabId: origin.guid)
            peek = nil
            reader = ReaderPanelController(browserState: state, parentWindow: window, anchorView: anchor,
                                           cardViewProvider: { _ in .init(view: anchor, cornerRadius: 0) })
            reader!.present(tab: tab)
        }
        defer {
            peek?.dismiss()
            reader?.dismiss()
            state.peekState.clear()
            state.readerOverlayState.clear()
            session.discardDormant()
            window.contentViewController = nil
            window.close()
        }
        XCTAssertTrue(tab.content.window === window)
        XCTAssertTrue(window.makeFirstResponder(tab.content))
        try body(Fixture(kind: kind, window: window, state: state, origin: origin, tab: tab,
                         peek: peek, reader: reader))
    }

    private func makeWindow() -> TestWindow {
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(_ characters: String, modifiers: NSEvent.ModifierFlags,
                       keyCode: UInt16 = 13, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }
}
