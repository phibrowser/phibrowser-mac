// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// `pageActions.register` parsing, URL-pattern matching and the registry's
/// refusals. Delivering `pageActions.invoked` needs a live `/phi-agent`
/// channel and is not staged here.
final class PageActionRegistryTests: XCTestCase {

    // MARK: - Parsing

    func testParsesTheContractExample() throws {
        let action = try XCTUnwrap(PageAction.parse([
            "id": "folio.save",
            "title": "Save to Folio",
            "menu": "both",
            "contexts": ["page"],
            "shortcut": ["key": "s", "modifiers": ["command", "option"]] as [String: Any],
            "documentUrlPatterns": ["http://*/*", "https://*/*"],
            "incognito": false,
        ]))
        XCTAssertEqual(action.id, "folio.save")
        XCTAssertEqual(action.title, "Save to Folio")
        XCTAssertEqual(action.menu, .both)
        XCTAssertEqual(action.contexts, [.page])
        XCTAssertEqual(action.shortcut, PageAction.Shortcut(key: "s", modifiers: [.command, .option]))
        XCTAssertFalse(action.incognito)
        XCTAssertTrue(action.showsInFileMenu)
    }

    func testDefaults() throws {
        let action = try XCTUnwrap(PageAction.parse(["id": "x", "title": "X"]))
        XCTAssertEqual(action.menu, .both)
        XCTAssertEqual(action.contexts, [.page])
        XCTAssertNil(action.shortcut)
        XCTAssertFalse(action.incognito)
        XCTAssertTrue(action.applies(toDocumentAt: "chrome://newtab/"))
    }

    func testContextOnlyActionsStayOutOfTheFileMenu() throws {
        let action = try XCTUnwrap(PageAction.parse([
            "id": "folio.highlight", "title": "Save Highlight to Folio",
            "menu": "context", "contexts": ["selection"],
        ]))
        XCTAssertFalse(action.showsInFileMenu)
    }

    func testUnusableEntriesAreRejected() {
        XCTAssertNil(PageAction.parse(["title": "No id"]))
        XCTAssertNil(PageAction.parse(["id": "no.title"]))
        XCTAssertNil(PageAction.parse(["id": "x", "title": "  "]))
        XCTAssertNil(PageAction.parse(["id": "x", "title": "X", "menu": "toolbar"]))
        XCTAssertNil(PageAction.parse(["id": "x", "title": "X", "contexts": ["frame"]]))
        XCTAssertNil(PageAction.parse(["id": "x", "title": "X", "documentUrlPatterns": ["not a pattern"]]))
        XCTAssertNil(PageAction.parse(["id": "x", "title": "X", "incognito": "yes"]))
    }

    /// A shortcut without Command would swallow typed text; a malformed one
    /// drops only the shortcut, not the action.
    func testShortcutsNeedCommandAndOneKey() throws {
        XCTAssertNil(PageAction.parseShortcut(["key": "s", "modifiers": ["option"]] as [String: Any]))
        XCTAssertNil(PageAction.parseShortcut(["key": "ss", "modifiers": ["command"]] as [String: Any]))
        XCTAssertNil(PageAction.parseShortcut(["key": " ", "modifiers": ["command"]] as [String: Any]))
        XCTAssertNil(PageAction.parseShortcut(["key": "s", "modifiers": ["command", "hyper"]] as [String: Any]))
        XCTAssertEqual(PageAction.parseShortcut(["key": "S", "modifiers": ["command", "shift"]] as [String: Any]),
                       PageAction.Shortcut(key: "s", modifiers: [.command, .shift]))
        let action = try XCTUnwrap(PageAction.parse([
            "id": "x", "title": "X", "shortcut": ["key": "s", "modifiers": ["option"]] as [String: Any],
        ]))
        XCTAssertNil(action.shortcut)
    }

    // MARK: - documentUrlPatterns

    /// Folio's patterns keep today's `SaveForLaterService.canSave` rule.
    func testHTTPPatternsMatchOnlyWebPages() throws {
        let action = try XCTUnwrap(PageAction.parse([
            "id": "x", "title": "X", "documentUrlPatterns": ["http://*/*", "https://*/*"],
        ]))
        XCTAssertTrue(action.applies(toDocumentAt: "https://example.com/"))
        XCTAssertTrue(action.applies(toDocumentAt: "http://example.com/a/b?c=d#e"))
        XCTAssertFalse(action.applies(toDocumentAt: "chrome://newtab/"))
        XCTAssertFalse(action.applies(toDocumentAt: "chrome-extension://abc/library.html"))
        XCTAssertFalse(action.applies(toDocumentAt: "file:///Users/x/a.html"))
        XCTAssertFalse(action.applies(toDocumentAt: nil))
        XCTAssertFalse(action.applies(toDocumentAt: ""))
    }

    func testHostAndPathPatterns() throws {
        let pattern = try XCTUnwrap(PageActionURLPattern("*://*.example.com/docs/*"))
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URLComponents(string: "https://example.com/docs/a"))))
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URLComponents(string: "http://a.b.example.com/docs/"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URLComponents(string: "https://notexample.com/docs/a"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URLComponents(string: "https://example.com/blog"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URLComponents(string: "ftp://example.com/docs/a"))))
    }

    func testAllURLsAndFilePatterns() throws {
        let all = try XCTUnwrap(PageActionURLPattern("<all_urls>"))
        XCTAssertTrue(all.matches(try XCTUnwrap(URLComponents(string: "file:///tmp/a.pdf"))))
        XCTAssertFalse(all.matches(try XCTUnwrap(URLComponents(string: "chrome://settings/"))))
        let file = try XCTUnwrap(PageActionURLPattern("file:///*"))
        XCTAssertTrue(file.matches(try XCTUnwrap(URLComponents(string: "file:///tmp/a.pdf"))))
    }

    func testMalformedPatternsDoNotParse() {
        for pattern in ["https://", "https://example.com", "://x/", "https://exa*mple.com/",
                        "https://*./", "https://example.com:8080/*", "1http://x/"] {
            XCTAssertNil(PageActionURLPattern(pattern), pattern)
        }
    }

    func testGlob() {
        XCTAssertTrue(PageActionURLPattern.glob("/*", matches: "/"))
        XCTAssertTrue(PageActionURLPattern.glob("/a*c", matches: "/abbbc"))
        XCTAssertTrue(PageActionURLPattern.glob("/*/x", matches: "/a/b/x"))
        XCTAssertFalse(PageActionURLPattern.glob("/a*c", matches: "/abd"))
        XCTAssertFalse(PageActionURLPattern.glob("/a", matches: "/ab"))
    }

    // MARK: - Registry

    func testRegisterNeedsADirectChannel() {
        let context = ExtensionMessageContext(
            type: "pageActions.register",
            payload: #"{"actions":[{"id":"x","title":"X"}]}"#,
            requestId: "r1", senderId: "cdp")
        XCTAssertEqual(PageActionRegistry.shared.handleRegister(context),
                       #"{"ok":false,"error":"direct_channel_required"}"#)
    }

    /// Rows in Phi's menus are for verified companion apps only; a consented
    /// agent's channel is refused before anything is parsed.
    func testRegisterNeedsACompanion() {
        let context = ExtensionMessageContext(
            type: "pageActions.register",
            payload: #"{"actions":[{"id":"x","title":"X"}]}"#,
            requestId: "r4", senderId: "cdp", directChannelId: "channel")
        XCTAssertEqual(PageActionRegistry.shared.handleRegister(context),
                       #"{"ok":false,"error":"companion_required"}"#)
    }

    func testRegisterRejectsAMalformedPayload() {
        let context = ExtensionMessageContext(
            type: "pageActions.register", payload: #"{"actions":"x"}"#,
            requestId: "r2", senderId: "cdp", directChannelId: "channel",
            isCompanion: true)
        XCTAssertEqual(PageActionRegistry.shared.handleRegister(context),
                       #"{"ok":false,"error":"invalid_params"}"#)
    }

    /// A registration for a channel that has already closed must not outlive
    /// it: nothing would ever remove it.
    func testRegisterForAClosedChannelIsRefused() {
        let channelId = "closed-\(UUID().uuidString)"
        let context = ExtensionMessageContext(
            type: "pageActions.register", payload: #"{"actions":[{"id":"x","title":"X"}]}"#,
            requestId: "r3", senderId: "cdp", directChannelId: channelId,
            isCompanion: true)
        XCTAssertEqual(PageActionRegistry.shared.handleRegister(context),
                       #"{"ok":false,"error":"channel_closed"}"#)
        XCTAssertNil(PageActionRegistry.shared.action(id: "x", channelId: channelId))
        XCTAssertFalse(PageActionRegistry.shared.invoke(actionId: "x", channelId: channelId, payload: [:]))
    }
}
