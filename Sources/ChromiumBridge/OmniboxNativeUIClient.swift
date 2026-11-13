// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.
import Foundation
import CoreFoundation

/// Transport for one native omnibox presentation's V2 session: it validates
/// snapshots, hands their rows to the omnibox as Chromium match dictionaries,
/// and selects or deletes a row by its result identity. Selection, inline
/// completion and temporary text stay with the omnibox. A new presentation
/// creates a new instance; this object never reconnects.
@MainActor
final class OmniboxNativeUIClient {
    enum Mode { case legacy, connecting, active, closed }
    struct Token: Equatable {
        let presentationID: String
        let request: UInt64
        let revision: UInt64
        let resultID: String
    }
    typealias Transport = @MainActor (
        _ operation: String, _ payload: [String: Any],
        _ completion: @escaping @MainActor ([String: Any]) -> Void
    ) -> Void

    let presentationID = UUID().uuidString
    private(set) var mode: Mode = .connecting
    private(set) var request: UInt64 = 0
    private(set) var defaultState = "pending"
    var onMode: (Mode) -> Void = { _ in }
    /// Rows of the current request's latest snapshot, for the query text.
    var onRows: (_ rows: [[String: Any]], _ text: String) -> Void = { _, _ in }
    var onClosed: (_ reason: String) -> Void = { _ in }
    var onSelectFinished: (_ status: String) -> Void = { _ in }

    private struct Query {
        let request: UInt64
        let text: String
        let preventInline: Bool
    }
    private struct Row {
        let id: String
        let kind: String
        let action: String
        let intents: Set<String>
        var display: [String: Any]
    }
    private final class CompletionGate { var called = false }
    private let transport: Transport
    private let now: () -> Date
    private var started = false
    private var generation: UInt64 = 1
    private var session: String?
    private var ended = Set<String>()
    private var readyToStart = false
    private var currentQuery: Query?
    private var revision: UInt64 = 0
    private var rows: [Row] = []
    private var snapshotDate: Date?
    private var consumed = false
    private var queryStopped = false
    private var snapshotDone = false
    private var selecting = false
    private var finishPending = false
    private static let maxCounter: UInt64 = 9_007_199_254_740_991
    // Chromium retains a snapshot for 30 seconds.
    private static let snapshotLifetime: TimeInterval = 25
    private static let intents: Set<String> = ["auto", "currentTab", "newForegroundTab", "newBackgroundTab", "switchToTab", "openEntity", "runCommand"]
    private static let entityKinds: Set<String> = ["bookmark", "pin"]

    init(transport: @escaping Transport, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    /// The enclosing bridge binds window/presentation authority; this target is
    /// an actual trusted native target identity, never a renderer parameter.
    func begin(targetID: Int?) {
        guard !started, mode == .connecting else { return }
        started = true
        let epoch = generation
        let operation = transport
        let gate = CompletionGate()
        var payload: [String: Any] = ["presentationID": presentationID]
        if let targetID { payload["targetTabId"] = targetID }
        operation("begin", payload) { [weak self] reply in
            guard !gate.called else { return }
            gate.called = true
            let handle = Self.nonemptyString(reply["session"])
            guard let self, self.generation == epoch, self.mode == .connecting else {
                if let handle { operation("end", ["session": handle]) { _ in } }
                return
            }
            guard let capabilities = reply["capabilities"] as? [String: Any] else {
                // Only the transport's explicit initial missing-API result is
                // a compatibility fallback. Malformed/error replies are not.
                if let handle { self.end(handle) }
                if reply["status"] as? String == "missing_api" {
                    self.fallBackToLegacy()
                } else {
                    self.close(reason: "invalid_session")
                }
                return
            }
            if Self.counter(capabilities["protocolVersion"], allowZero: true) == 0 {
                if let handle { self.end(handle) }
                self.fallBackToLegacy()
                return
            }
            guard Self.validCapabilities(capabilities), let handle else {
                if let handle { self.end(handle) }
                self.close(reason: "unsupported_context")
                return
            }
            self.session = handle
            self.mode = .active
            self.onMode(.active)
            guard self.generation == epoch, self.mode == .active, self.session == handle else { return }
            self.issue("invalidation", ["session": handle]) { [weak self] response in
                guard let self, self.generation == epoch, self.mode == .active, self.session == handle else { return }
                self.close(reason: Self.nonemptyString(response["reason"]) ?? "invalid_session")
            }
            guard self.generation == epoch, self.mode == .active, self.session == handle else { return }
            self.readyToStart = true
            if let query = self.currentQuery { self.start(query, handle: handle, epoch: epoch) }
        }
    }

    @discardableResult
    func query(text: String, preventInline: Bool) -> UInt64? {
        guard mode == .connecting || mode == .active, !selecting else { return nil }
        guard text.utf16.count <= 1024, request < Self.maxCounter else {
            close(reason: "invalid_session")
            return nil
        }
        request += 1
        let query = Query(request: request, text: text, preventInline: preventInline)
        currentQuery = query
        consumed = false
        queryStopped = false
        resetRows()
        if let handle = session, readyToStart, isCurrent(query, handle, generation) {
            start(query, handle: handle, epoch: generation)
        }
        return query.request
    }

    func stop() {
        guard mode == .connecting || mode == .active else { return }
        let old = currentQuery
        let handle = session
        currentQuery = nil
        queryStopped = true
        resetRows()
        if let old, let handle {
            issue("stop", ["session": handle, "request": old.request]) { _ in }
        }
    }

    /// Invalidates all locally executable state before any callback/bridge call.
    func close(reason: String = "ended") {
        guard mode != .closed else { return }
        let oldHandle = session
        generation += 1
        mode = .closed
        session = nil
        currentQuery = nil
        readyToStart = false
        consumed = true
        queryStopped = true
        finishPending = false
        resetRows()
        onClosed(reason)
        onMode(.closed)
        if let oldHandle { end(oldHandle) }
    }

    /// Ends the session once an in-flight selection settles: ending it earlier
    /// would cancel the chosen pin or bookmark before Phi opens it.
    func finish() {
        if selecting {
            finishPending = true
        } else {
            close()
        }
    }

    /// Whether `token` names a row of the current request's latest snapshot
    /// that Chromium still retains.
    func canSelect(_ token: Token) -> Bool {
        guard mode == .active, !consumed, !queryStopped, let query = currentQuery,
              token.presentationID == presentationID, token.request == query.request,
              let snapshotDate, now().timeIntervalSince(snapshotDate) < Self.snapshotLifetime else { return false }
        return rows.contains { $0.id == token.resultID }
    }

    /// Whether the current request has a retained snapshot with a settled default.
    var hasSettledSnapshot: Bool {
        guard mode == .active, !consumed, !queryStopped, currentQuery != nil,
              let snapshotDate, now().timeIntervalSince(snapshotDate) < Self.snapshotLifetime else { return false }
        return defaultState != "pending"
    }

    /// Whether the current request is still waiting for a snapshot that has
    /// not been superseded by a settled one.
    var isAwaitingSnapshot: Bool {
        guard mode == .connecting || mode == .active, !consumed, !queryStopped,
              currentQuery != nil else { return false }
        return snapshotDate == nil || defaultState == "pending"
    }

    /// Returns "submitted", or why the row cannot be selected: "stale",
    /// "unavailable" or "unsupported_intent".
    @discardableResult
    func select(_ token: Token, ordinaryIntent: String) -> String {
        guard canSelect(token), let query = currentQuery, let handle = session,
              let row = rows.first(where: { $0.id == token.resultID }) else { return "stale" }
        guard !row.intents.isEmpty else { return "unavailable" }
        // A pin or bookmark opens its entity for a switch; otherwise a single
        // page opens like an ordinary row. A split only opens the entity.
        let intent = row.kind == "command" ? "runCommand" :
            Self.entityKinds.contains(row.kind) ?
                (ordinaryIntent == "switchToTab" || row.intents == ["openEntity"] ? "openEntity" : ordinaryIntent) :
            row.action == "action" && row.intents == ["auto"] ? "auto" : ordinaryIntent
        guard row.intents.contains(intent) else { return "unsupported_intent" }
        consumed = true
        selecting = true
        // Holds this client until the reply, so `finish` can end the session afterwards.
        issue("select", ["session": handle, "request": query.request, "revision": revision,
                         "resultId": row.id, "intent": intent]) { response in
            self.selecting = false
            var status = response["status"] as? String ?? "transport_error"
            if status == "accepted" {
                let effects: Set<String> = ["originReplaced", "newTab", "focusedExisting", "handedOff"]
                if Self.nonemptyString(response["actionId"]) == nil ||
                    !effects.contains(response["dispatchEffect"] as? String ?? "") {
                    status = "invalid_receipt"
                }
            }
            self.onSelectFinished(status)
            if self.finishPending { self.close() }
        }
        return "submitted"
    }

    func delete(_ token: Token, completion: @escaping @MainActor (Bool) -> Void) {
        guard canSelect(token), let query = currentQuery, let handle = session else {
            completion(false)
            return
        }
        issue("delete", ["session": handle, "request": query.request, "revision": revision,
                         "resultId": token.resultID]) { reply in
            completion(reply["status"] as? String == "deleted")
        }
    }

    private func fallBackToLegacy() {
        mode = .legacy
        currentQuery = nil
        resetRows()
        onMode(.legacy)
    }

    private func start(_ query: Query, handle: String, epoch: UInt64) {
        guard isCurrent(query, handle, epoch), !consumed, !queryStopped else { return }
        issue("start", ["session": handle, "request": query.request,
                        "text": query.text, "preventInline": query.preventInline]) { [weak self] reply in
            guard let self, self.isCurrent(query, handle, epoch), !self.consumed, !self.queryStopped else { return }
            guard reply["status"] as? String != "no_change" else {
                self.close(reason: "invalid_session")
                return
            }
            self.receive(reply, query: query, handle: handle, epoch: epoch)
            self.scheduleWatch(query, handle: handle, epoch: epoch)
        }
    }

    private func scheduleWatch(_ query: Query, handle: String, epoch: UInt64) {
        guard isCurrent(query, handle, epoch), !consumed, !queryStopped,
              revision > 0, !snapshotDone else { return }
        let after = revision
        // A synchronous fake/bridge reply must not recursively grow the stack.
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(query, handle, epoch), !self.consumed,
                  !self.queryStopped, !self.snapshotDone, self.revision == after else { return }
            self.issue("watch", ["session": handle, "request": query.request,
                                 "afterRevision": after]) { [weak self] reply in
                guard let self, self.isCurrent(query, handle, epoch), !self.consumed, !self.queryStopped else { return }
                self.receive(reply, query: query, handle: handle, epoch: epoch)
                self.scheduleWatch(query, handle: handle, epoch: epoch)
            }
        }
    }

    private func receive(_ reply: [String: Any], query: Query, handle: String, epoch: UInt64) {
        switch reply["status"] as? String {
        case "no_change": return
        case "closed": close(reason: reply["reason"] as? String ?? "invalid_session"); return
        case "stopped":
            queryStopped = true
            return
        case "snapshot": break
        default: close(reason: "invalid_session"); return
        }
        guard let envelope = reply["snapshot"] as? [String: Any],
              JSONSerialization.isValidJSONObject(envelope),
              let bytes = try? JSONSerialization.data(withJSONObject: envelope), bytes.count <= 128 * 1024,
              envelope["session"] as? String == handle,
              Self.counter(envelope["request"]) == query.request,
              let nextRevision = Self.counter(envelope["revision"]), nextRevision > revision,
              let items = envelope["results"] as? [[String: Any]], items.count <= 8,
              let done = Self.boolean(envelope["done"]),
              let capabilities = envelope["capabilities"] as? [String: Any], Self.validCapabilities(capabilities),
              let nextDefault = envelope["defaultState"] as? String,
              ["ready", "pending", "unavailable"].contains(nextDefault),
              let providers = envelope["providerStatus"] as? [String: String],
              providers.count == 3, let bookmarkStatus = providers["bookmark"],
              let pinStatus = providers["pin"], let commandStatus = providers["command"],
              Self.providerStatuses.contains(bookmarkStatus), Self.providerStatuses.contains(pinStatus),
              Self.providerStatuses.contains(commandStatus) else {
            close(reason: "invalid_session")
            return
        }
        var parsed: [Row] = []
        var seen = Set<String>()
        let defaultID = Self.nonemptyString(envelope["defaultResultId"])
        for item in items {
            guard let id = Self.nonemptyString(item["resultId"]), seen.insert(id).inserted,
                  let kind = item["kind"] as? String, ["navigation", "bookmark", "pin", "command"].contains(kind),
                  let action = item["action"] as? String,
                  let intents = item["allowedIntents"] as? [String],
                  Set(intents).count == intents.count, Set(intents).isSubset(of: Self.intents),
                  var display = item["match"] as? [String: Any] else {
                close(reason: "invalid_session"); return
            }
            let native = kind != "navigation"
            let entity = Self.entityKinds.contains(kind)
            if let unavailable = item["unavailableReason"] {
                guard let reason = Self.nonemptyString(unavailable), !native, intents.isEmpty,
                      Self.boolean(display["allowedToBeDefaultMatch"]) == false,
                      (display["inlineAutocompletion"] as? String ?? "").isEmpty else {
                    close(reason: "invalid_session"); return
                }
                if reason != "keyword_hint" {
                    display["description"] = NSLocalizedString("omnibox.result.actionUnavailable",
                        value: "This action is unavailable.",
                        comment: "Omnibox results - A retained action cannot currently be executed")
                }
            } else if intents.isEmpty {
                close(reason: "invalid_session"); return
            }
            let validAction: Bool
            switch kind {
            case "command": validAction = action == "runCommand" && intents == ["runCommand"]
            case "navigation":
                validAction = ["navigate", "action"].contains(action) &&
                    !intents.contains("openEntity") && !intents.contains("runCommand")
            default:
                // A single page may also open as an ordinary row; a split only
                // opens the entity.
                validAction = action == "openEntity" && intents.contains("openEntity") &&
                    !intents.contains("runCommand") && !intents.contains("switchToTab") &&
                    (item["panes"] == nil || intents == ["openEntity"])
            }
            guard validAction else {
                close(reason: "invalid_session"); return
            }
            if kind == "command" {
                // Commands are never the default or inline text.
                guard Self.boolean(display["allowedToBeDefaultMatch"]) == false,
                      (display["inlineAutocompletion"] as? String ?? "").isEmpty,
                      Self.boolean(display["hasTabMatch"]) == false else {
                    close(reason: "invalid_session"); return
                }
            }
            if entity {
                // Only the first row, as the service default, may be default or inline.
                let isDefault = parsed.isEmpty && nextDefault == "ready" && defaultID == id
                guard isDefault || (Self.boolean(display["allowedToBeDefaultMatch"]) == false &&
                                    (display["inlineAutocompletion"] as? String ?? "").isEmpty),
                      Self.boolean(display["hasTabMatch"]) == false,
                      let isOpen = Self.boolean(item["isOpen"]) else {
                    close(reason: "invalid_session"); return
                }
                display["isOpen"] = isOpen
                if let currentURL = item["currentURL"] {
                    guard currentURL is String else { close(reason: "invalid_session"); return }
                    display["currentURL"] = currentURL
                }
                if let value = item["panes"] {
                    // A split is never inline: its text would name one pane only.
                    guard let panes = Self.panes(value),
                          (display["inlineAutocompletion"] as? String ?? "").isEmpty else {
                        close(reason: "invalid_session"); return
                    }
                    display["phiPanes"] = panes
                }
            } else if item["panes"] != nil {
                close(reason: "invalid_session"); return
            }
            if parsed.isEmpty, !(nextDefault == "ready" && defaultID == id) {
                // Only a ready service default may be the omnibox default.
                display["allowedToBeDefaultMatch"] = false
                display["inlineAutocompletion"] = ""
            }
            if kind != "navigation" || item["unavailableReason"] != nil {
                display["deletable"] = false
            }
            var metadata: [String: Any] = ["presentationID": presentationID, "request": query.request,
                                           "revision": nextRevision, "resultId": id, "kind": kind]
            if let rowKey = Self.nonemptyString(item["rowKey"]) { metadata["rowKey"] = rowKey }
            display["phiV2"] = metadata
            parsed.append(Row(id: id, kind: kind, action: action, intents: Set(intents), display: display))
        }
        if nextDefault == "ready" {
            let navigate = parsed.first?.kind == "navigation" && parsed.first?.action == "navigate"
            let openEntity = parsed.first.map { Self.entityKinds.contains($0.kind) } == true &&
                parsed.first?.action == "openEntity"
            guard let defaultID, parsed.first?.id == defaultID, navigate || openEntity,
                  parsed.first?.intents.isEmpty == false,
                  Self.boolean(parsed.first?.display["allowedToBeDefaultMatch"]) == true else {
                close(reason: "invalid_session"); return
            }
        } else {
            guard envelope["defaultResultId"] is NSNull else { close(reason: "invalid_session"); return }
        }
        guard isCurrent(query, handle, epoch), !consumed, !queryStopped else { return }
        rows = parsed
        revision = nextRevision
        snapshotDate = now()
        snapshotDone = done
        defaultState = nextDefault
        onRows(rows.map(\.display), query.text)
    }

    private func resetRows() {
        rows = []
        revision = 0
        snapshotDate = nil
        snapshotDone = false
        defaultState = "pending"
    }

    private func isCurrent(_ query: Query, _ handle: String, _ epoch: UInt64) -> Bool {
        generation == epoch && mode == .active && session == handle && currentQuery?.request == query.request
    }
    private func issue(_ operation: String, _ payload: [String: Any],
                       completion: @escaping @MainActor ([String: Any]) -> Void) {
        let gate = CompletionGate()
        transport(operation, payload) { reply in
            guard !gate.called else { return }
            gate.called = true
            completion(reply)
        }
    }
    private func end(_ handle: String) {
        guard ended.insert(handle).inserted else { return }
        issue("end", ["session": handle]) { _ in }
    }
    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    /// Two to four `{title, url}` panes of a split row.
    private static func panes(_ value: Any) -> [[String: String]]? {
        guard let items = value as? [[String: Any]], (2...4).contains(items.count) else { return nil }
        var panes: [[String: String]] = []
        for item in items {
            guard let title = item["title"] as? String, let url = nonemptyString(item["url"]) else { return nil }
            panes.append(["title": title, "url": url])
        }
        return panes
    }
    private static func counter(_ value: Any?, allowZero: Bool = false) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= (allowZero ? 0 : 1),
              value <= Double(maxCounter), value.rounded(.towardZero) == value else { return nil }
        return UInt64(value)
    }
    private static let providerStatuses: Set<String> = ["pending", "complete", "disabled", "unavailable", "timeout", "busy", "cancelled", "resource_exhausted", "limit_exceeded"]

    private static func validCapabilities(_ value: [String: Any]) -> Bool {
        guard counter(value["protocolVersion"]) == 2,
              boolean(value["identitySelection"]) == true,
              boolean(value["finalActionIdentity"]) == true,
              boolean(value["defaultState"]) == true,
              boolean(value["sessionInvalidation"]) == true,
              boolean(value["nativeQuery"]) == true,
              boolean(value["nativeExecute"]) == true,
              boolean(value["targetEligibility"]) == true,
              boolean(value["command"]) == true,
              boolean(value["documentBinding"]) == false,
              let kinds = value["supportedKinds"] as? [String],
              Set(kinds) == Set(["navigation", "bookmark", "pin", "command"]),
              let intents = value["supportedIntents"] as? [String],
              Set(intents) == Self.intents else { return false }
        return true
    }
}
