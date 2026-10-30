// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

/// One menu action a `/phi-agent` channel asked Phi to show with
/// `pageActions.register`. Phi renders it and reports clicks back; the work
/// itself stays with the client. See docs/companion-apps.md.
struct PageAction: Equatable {
    enum Menu: String {
        case file, context, both
    }

    enum Context: String {
        case page, selection, link
    }

    /// A key equivalent: one printable character and its modifiers, which
    /// always include Command.
    struct Shortcut: Equatable {
        let key: String
        let modifiers: NSEvent.ModifierFlags

        var shortcutsKey: ShortcutsKey {
            ShortcutsKey(menuKeyEquivalent: key, modifiers: modifiers)
        }
    }

    let id: String
    let title: String
    let menu: Menu
    let contexts: [Context]
    let shortcut: Shortcut?
    /// Empty means every page.
    let documentURLPatterns: [PageActionURLPattern]
    /// Whether the action shows in off-the-record windows.
    let incognito: Bool

    var showsInFileMenu: Bool { menu != .context }

    /// Whether the action applies to a page at `urlString` — the
    /// `documentUrlPatterns` rule of `chrome.contextMenus`.
    func applies(toDocumentAt urlString: String?) -> Bool {
        guard !documentURLPatterns.isEmpty else { return true }
        guard let urlString, let components = URLComponents(string: urlString) else {
            return false
        }
        return documentURLPatterns.contains { $0.matches(components) }
    }

    static let maxIdLength = 128
    static let maxTitleLength = 128
    static let maxPatterns = 32

    /// Parses one entry of `pageActions.register`'s `actions`. Nil when the
    /// entry is unusable: no id or title, an unknown menu or context, or a
    /// URL pattern that does not parse. A malformed shortcut only drops the
    /// shortcut. Internal for unit coverage.
    static func parse(_ object: [String: Any]) -> PageAction? {
        guard let id = (object["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, id.count <= maxIdLength,
              let title = (object["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= maxTitleLength else {
            return nil
        }
        let menu: Menu
        if let raw = object["menu"] {
            guard let name = raw as? String, let parsed = Menu(rawValue: name) else { return nil }
            menu = parsed
        } else {
            menu = .both
        }
        var contexts: [Context] = [.page]
        if let raw = object["contexts"] {
            guard let names = raw as? [String], !names.isEmpty else { return nil }
            var parsed: [Context] = []
            for name in names {
                guard let context = Context(rawValue: name) else { return nil }
                if !parsed.contains(context) { parsed.append(context) }
            }
            contexts = parsed
        }
        var patterns: [PageActionURLPattern] = []
        if let raw = object["documentUrlPatterns"] {
            guard let strings = raw as? [String], strings.count <= maxPatterns else { return nil }
            for string in strings {
                guard let pattern = PageActionURLPattern(string) else { return nil }
                patterns.append(pattern)
            }
        }
        let incognito: Bool
        if let raw = object["incognito"] {
            guard let flag = raw as? Bool else { return nil }
            incognito = flag
        } else {
            incognito = false
        }
        return PageAction(id: id, title: title, menu: menu, contexts: contexts,
                          shortcut: parseShortcut(object["shortcut"]),
                          documentURLPatterns: patterns, incognito: incognito)
    }

    /// `{ "key": "s", "modifiers": ["command", "option"] }`. Command is
    /// required: a menu equivalent without it would swallow typed text.
    static func parseShortcut(_ raw: Any?) -> Shortcut? {
        guard let object = raw as? [String: Any],
              let key = object["key"] as? String, key.count == 1,
              let character = key.lowercased().first,
              !character.isWhitespace, !character.isNewline,
              character.isLetter || character.isNumber
                || character.isPunctuation || character.isSymbol,
              let names = object["modifiers"] as? [String] else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "command": modifiers.insert(.command)
            case "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "control": modifiers.insert(.control)
            default: return nil
            }
        }
        guard modifiers.contains(.command) else { return nil }
        return Shortcut(key: String(character), modifiers: modifiers)
    }
}

/// A `chrome.contextMenus`-style match pattern: `<all_urls>` or
/// `<scheme>://<host><path>`, where the scheme `*` means http and https, the
/// host is `*`, `*.<domain>` or a host name, and the path is a glob over the
/// URL's path and query.
struct PageActionURLPattern: Equatable {
    /// The pattern as registered, for Chromium's right-click menu, which
    /// matches it again itself.
    let source: String
    private let schemes: Set<String>
    private let host: String
    private let path: String

    private static let allURLsSchemes: Set<String> = ["http", "https", "file", "ftp", "ws", "wss"]

    init?(_ pattern: String) {
        source = pattern
        if pattern == "<all_urls>" {
            schemes = Self.allURLsSchemes
            host = "*"
            path = "/*"
            return
        }
        guard let separator = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<separator.lowerBound].lowercased()
        let rest = pattern[separator.upperBound...]
        if scheme == "*" {
            schemes = ["http", "https"]
        } else {
            guard let first = scheme.first, first.isLetter,
                  scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
                return nil
            }
            schemes = [scheme]
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let hostPart = rest[..<slash].lowercased()
        if scheme == "file" {
            guard hostPart.isEmpty || hostPart == "*" else { return nil }
        } else {
            guard !hostPart.isEmpty else { return nil }
        }
        if hostPart != "*" {
            let bare = hostPart.hasPrefix("*.") ? String(hostPart.dropFirst(2)) : hostPart
            guard !bare.contains("*"), !bare.contains(":"),
                  scheme == "file" || !bare.isEmpty else { return nil }
        }
        host = hostPart.isEmpty ? "*" : hostPart
        path = String(rest[slash...])
    }

    func matches(_ url: URLComponents) -> Bool {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return false }
        let urlHost = (url.host ?? "").lowercased()
        if host.hasPrefix("*.") {
            let domain = String(host.dropFirst(2))
            guard urlHost == domain || urlHost.hasSuffix("." + domain) else { return false }
        } else if host != "*" {
            guard urlHost == host else { return false }
        }
        var target = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { target += "?" + query }
        return Self.glob(path, matches: target)
    }

    /// `*` matches any run of characters, including none; everything else
    /// matches itself.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0
        var star: Int?, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if let s = star {
                pi = s + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Owns the page actions registered over `/phi-agent` channels, per channel.
///
/// A channel's set is replaced whole by each `pageActions.register` and
/// dropped when the channel closes (`AgentDirectConnection.teardown`), so a
/// client's rows disappear with it. The File menu reads the set when it is
/// rebuilt (`AppController.installOrUpdateFileMenuItems`); the web-content
/// right-click menu is Chromium's, so the `context` rows are pushed down to it
/// on every change (`setPageActionContextMenu:`). A click in either is sent
/// back as `pageActions.invoked` to the registering channel only.
///
/// Thread-safe: registration arrives on the main thread, removal on a
/// channel's own queue.
final class PageActionRegistry {
    static let shared = PageActionRegistry()

    struct Entry {
        let channelId: String
        let action: PageAction
    }

    static let invokedEventType = "pageActions.invoked"
    static let maxActionsPerChannel = 32

    private let lock = NSLock()
    private var actionsByChannel: [String: [PageAction]] = [:]
    /// Channels in first-registration order, so menu rows keep their place.
    private var channelOrder: [String] = []

    private init() {}

    // MARK: - Messages

    /// `pageActions.register { actions: [...] }` → `{ registered: [ids] }`.
    /// Entries that do not parse, repeat an id or exceed the per-channel cap
    /// are skipped; the reply names the ones that took.
    func handleRegister(_ context: ExtensionMessageContext) -> String {
        guard let channelId = context.directChannelId else {
            return #"{"ok":false,"error":"direct_channel_required"}"#
        }
        // Rows in Phi's own menus are offered to verified companion apps
        // only: a consented third-party agent can drive the browser, but it
        // does not get to add items that read as Phi's.
        guard context.isCompanion else {
            return #"{"ok":false,"error":"companion_required"}"#
        }
        guard let data = context.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["actions"] as? [[String: Any]] else {
            return #"{"ok":false,"error":"invalid_params"}"#
        }
        var actions: [PageAction] = []
        for entry in entries {
            guard let action = PageAction.parse(entry) else {
                AppLogWarn("[PageActions] skipped an unusable action \(entry["id"] ?? "?")")
                continue
            }
            guard !actions.contains(where: { $0.id == action.id }),
                  actions.count < Self.maxActionsPerChannel else { continue }
            actions.append(action)
        }
        guard register(actions, channelId: channelId) else {
            return #"{"ok":false,"error":"channel_closed"}"#
        }
        let reply = ["registered": actions.map(\.id)]
        guard let json = try? JSONSerialization.data(withJSONObject: reply),
              let text = String(data: json, encoding: .utf8) else {
            return #"{"ok":false,"error":"encode_failed"}"#
        }
        return text
    }

    // MARK: - Registrations

    /// Replaces `channelId`'s whole set. False when the channel has already
    /// closed, so a registration racing the close cannot outlive it.
    @discardableResult
    func register(_ actions: [PageAction], channelId: String) -> Bool {
        lock.lock()
        guard AgentDirectChannelRegistry.shared.isLive(connectionId: channelId) else {
            lock.unlock()
            return false
        }
        let previous = actionsByChannel[channelId] ?? []
        if actions.isEmpty {
            actionsByChannel[channelId] = nil
            channelOrder.removeAll { $0 == channelId }
        } else {
            if actionsByChannel[channelId] == nil { channelOrder.append(channelId) }
            actionsByChannel[channelId] = actions
        }
        lock.unlock()
        if previous != actions { Self.scheduleMenuRefresh() }
        return true
    }

    /// Drops everything `channelId` registered. A channel that registered
    /// nothing changes nothing.
    func removeAll(channelId: String) {
        lock.lock()
        let removed = actionsByChannel.removeValue(forKey: channelId) != nil
        if removed { channelOrder.removeAll { $0 == channelId } }
        lock.unlock()
        if removed { Self.scheduleMenuRefresh() }
    }

    /// The rows the File menu shows, in registration order.
    var fileMenuEntries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return channelOrder.flatMap { channelId in
            (actionsByChannel[channelId] ?? [])
                .filter(\.showsInFileMenu)
                .map { Entry(channelId: channelId, action: $0) }
        }
    }

    /// The rows the web-content right-click menu shows, in registration order.
    var contextMenuEntries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return channelOrder.flatMap { channelId in
            (actionsByChannel[channelId] ?? [])
                .filter { $0.menu != .file }
                .map { Entry(channelId: channelId, action: $0) }
        }
    }

    /// The live registration behind a menu row, or nil once it is gone.
    func action(id: String, channelId: String) -> PageAction? {
        lock.lock(); defer { lock.unlock() }
        return actionsByChannel[channelId]?.first { $0.id == id }
    }

    // MARK: - Invocation

    /// Sends `pageActions.invoked` to the channel that registered `actionId`,
    /// and to no other. `payload` carries the page fields; `id` is added
    /// here. False when the registration or its channel is gone.
    @discardableResult
    func invoke(actionId: String, channelId: String, payload: [String: Any]) -> Bool {
        guard action(id: actionId, channelId: channelId) != nil else { return false }
        var event = payload
        event["id"] = actionId
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return false }
        return AgentDirectChannelRegistry.shared.send(
            type: Self.invokedEventType, payloadJson: json, connectionId: channelId)
    }

    private static func scheduleMenuRefresh() {
        DispatchQueue.main.async {
            AppController.shared?.refreshPrefGatedMenuItems()
            pushContextMenuToChromium()
        }
    }

    /// Replaces the right-click rows Chromium shows with the current set.
    /// A framework without the hook keeps none.
    static func pushContextMenuToChromium() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              (bridge as AnyObject).responds(to: #selector(PhiChromiumBridgeProtocol.setPageActionContextMenu(_:)))
        else {
            AppLogWarn("[PageActions] right-click rows not pushed: the framework has no hook")
            return
        }
        let payload: [[String: Any]] = shared.contextMenuEntries.map { entry in
            [
                "channelId": entry.channelId,
                "actionId": entry.action.id,
                "title": entry.action.title,
                "contexts": entry.action.contexts.map(\.rawValue),
                "documentUrlPatterns": entry.action.documentURLPatterns.map(\.source),
                "incognito": NSNumber(value: entry.action.incognito),
            ]
        }
        bridge.setPageActionContextMenu(payload)
        AppLogDebug("[PageActions] pushed \(payload.count) right-click row(s) to Chromium")
    }
}
