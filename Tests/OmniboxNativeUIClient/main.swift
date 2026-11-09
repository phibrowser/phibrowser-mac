import Foundation

@MainActor
private final class FakeTransport {
    struct Call {
        let operation: String
        let payload: [String: Any]
        let reply: @MainActor ([String: Any]) -> Void
    }
    var calls: [Call] = []
    var pending: [Call] = []
    func send(_ operation: String, _ payload: [String: Any],
              _ reply: @escaping @MainActor ([String: Any]) -> Void) {
        let call = Call(operation: operation, payload: payload, reply: reply)
        calls.append(call)
        if operation == "stop" || operation == "end" { reply([:]) }
        else { pending.append(call) }
    }
    func take(_ operation: String) -> Call {
        guard let index = pending.firstIndex(where: { $0.operation == operation }) else {
            fatalError("Missing operation: \(operation)")
        }
        return pending.remove(at: index)
    }
    func waitFor(_ operation: String) async -> Call {
        for _ in 0..<100 {
            if pending.contains(where: { $0.operation == operation }) { return take(operation) }
            await Task.yield()
        }
        fatalError("Operation never arrived: \(operation)")
    }
    func count(_ operation: String) -> Int { calls.filter { $0.operation == operation }.count }
}

@MainActor
private func caps() -> [String: Any] {
    ["protocolVersion": 2, "identitySelection": true, "finalActionIdentity": true,
     "defaultState": true, "documentBinding": false, "sessionInvalidation": true,
     "nativeQuery": true, "nativeExecute": true, "targetEligibility": true, "command": true,
     "supportedKinds": ["navigation", "bookmark", "pin", "command"],
     "supportedIntents": ["auto", "currentTab", "newForegroundTab", "newBackgroundTab", "switchToTab", "openEntity", "runCommand"]]
}
@MainActor
private func row(_ id: String, native: Bool = false) -> [String: Any] {
    var result: [String: Any] = [
        "resultId": id, "kind": native ? "pin" : "navigation",
        "action": native ? "openEntity" : "navigate",
        "allowedIntents": native ? ["openEntity"] : ["auto", "currentTab", "newForegroundTab"],
        "match": ["contents": id, "description": "", "destinationUrl": "https://example.test/",
                  "fillIntoEdit": id, "allowedToBeDefaultMatch": !native,
                  "hasTabMatch": false, "inlineAutocompletion": ""]]
    if native { result["isOpen"] = false }
    return result
}
@MainActor
private func commandRow(_ id: String) -> [String: Any] {
    ["resultId": id, "kind": "command", "action": "runCommand", "allowedIntents": ["runCommand"],
     "match": ["contents": id, "description": "", "destinationUrl": "", "fillIntoEdit": "",
               "allowedToBeDefaultMatch": false, "hasTabMatch": false, "inlineAutocompletion": "",
               "type": "phi-command", "phiCommandId": id]]
}
@MainActor
private func envelope(_ request: UInt64, revision: UInt64 = 1, rows: [[String: Any]],
                      defaultID: String? = nil, done: Bool = true,
                      state: String? = nil) -> [String: Any] {
    ["status": "snapshot", "snapshot": [
        "session": "session-1", "request": request, "revision": revision,
        "results": rows, "defaultResultId": defaultID.map { $0 as Any } ?? NSNull(),
        "defaultState": state ?? (defaultID == nil ? "pending" : "ready"), "done": done,
        "providerStatus": ["bookmark": "complete", "pin": "complete", "command": "complete"],
        "capabilities": caps()]]
}

@MainActor
private final class Fixture {
    let transport = FakeTransport()
    let client: OmniboxNativeUIClient
    var clock = Date(timeIntervalSince1970: 0)
    var displayed: [[String: Any]] = []
    var displayedText: String?
    var finished: [String] = []
    var closed: [String] = []
    init(connect: Bool = true) {
        let transport = self.transport
        var now: (() -> Date)!
        client = OmniboxNativeUIClient(transport: transport.send, now: { now() })
        now = { [unowned self] in self.clock }
        client.onRows = { [weak self] rows, text in
            self?.displayed = rows
            self?.displayedText = text
        }
        client.onSelectFinished = { [weak self] in self?.finished.append($0) }
        client.onClosed = { [weak self] in self?.closed.append($0) }
        client.begin(targetID: 7)
        if connect { transport.take("begin").reply(["session": "session-1", "capabilities": caps()]) }
    }
    @discardableResult
    func start(_ text: String = "query", rows: [[String: Any]], defaultID: String? = nil, done: Bool = true,
               state: String? = nil) -> UInt64 {
        guard let request = client.query(text: text, preventInline: false) else { fatalError("Query failed") }
        transport.take("start").reply(envelope(request, rows: rows, defaultID: defaultID, done: done, state: state))
        return request
    }
    func token(_ id: String, request: UInt64, revision: UInt64 = 1) -> OmniboxNativeUIClient.Token {
        .init(presentationID: client.presentationID, request: request, revision: revision, resultID: id)
    }
}

@MainActor
private func match(_ row: [String: Any]) -> [String: Any] { row["match"] as! [String: Any] }

@main
private struct NativeClientTests {
    @MainActor
    static func main() async {
        lateBeginEndsOnlyItsHandle()
        rowsCarryIdentityAndOnlyReadyDefault()
        selectionIntentFollowsRowKind()
        staleOrExpiredTokenCannotSelect()
        finishWaitsForInFlightSelection()
        unavailableRowsKeepKeywordHints()
        deleteOnlyOrdinaryRows()
        invalidationClosesSession()
        malformedCapabilityAndEnvelopeFailClosed()
        missingCapabilitiesFallbackOnlyInitially()
        commandCannotBeDefault()
        await lateSnapshotOfOldQueryIsIgnored()
        print("12 native UI client tests passed")
    }

    @MainActor
    static func lateBeginEndsOnlyItsHandle() {
        let fixture = Fixture(connect: false)
        let begin = fixture.transport.take("begin")
        precondition(begin.payload["targetTabId"] as? Int == 7)
        fixture.client.close(reason: "surface_hidden")
        precondition(fixture.client.mode == .closed && fixture.closed == ["surface_hidden"])
        begin.reply(["session": "late-owned", "capabilities": caps()])
        begin.reply(["session": "duplicate", "capabilities": caps()])
        precondition(fixture.transport.count("end") == 1)
        precondition(fixture.transport.calls.last?.payload["session"] as? String == "late-owned")
        precondition(fixture.transport.count("start") == 0)
    }

    @MainActor
    static func rowsCarryIdentityAndOnlyReadyDefault() {
        let fixture = Fixture()
        var first = row("first")
        var display = match(first)
        display["inlineAutocompletion"] = "com"
        first["match"] = display
        let request = fixture.start("Q", rows: [first, row("pin", native: true)], defaultID: "first")
        precondition(fixture.displayedText == "Q" && fixture.displayed.count == 2)
        precondition(fixture.displayed[0]["allowedToBeDefaultMatch"] as? Bool == true)
        precondition(fixture.displayed[0]["inlineAutocompletion"] as? String == "com")
        let metadata = fixture.displayed[1]["phiV2"] as! [String: Any]
        precondition(metadata["resultId"] as? String == "pin" && metadata["kind"] as? String == "pin")
        precondition(metadata["request"] as? UInt64 == request)
        precondition(fixture.displayed[1]["deletable"] as? Bool == false)
        precondition(fixture.client.hasSettledSnapshot && !fixture.client.isAwaitingSnapshot)

        let pending = fixture.start("Qu", rows: [first], done: false, state: "pending")
        precondition(fixture.displayed[0]["allowedToBeDefaultMatch"] as? Bool == false)
        precondition(fixture.displayed[0]["inlineAutocompletion"] as? String == "")
        precondition(!fixture.client.hasSettledSnapshot && fixture.client.isAwaitingSnapshot)
        precondition(fixture.client.canSelect(fixture.token("first", request: pending)))
        fixture.client.close()
    }

    @MainActor
    static func selectionIntentFollowsRowKind() {
        let entity = Fixture()
        let request = entity.start(rows: [row("default"), row("pin", native: true)], defaultID: "default")
        precondition(entity.client.select(entity.token("pin", request: request), ordinaryIntent: "newForegroundTab") == "submitted")
        let selected = entity.transport.take("select")
        precondition(selected.payload["intent"] as? String == "openEntity")
        precondition(selected.payload["revision"] as? UInt64 == 1)
        precondition(entity.client.select(entity.token("default", request: request), ordinaryIntent: "currentTab") == "stale")
        precondition(entity.transport.count("select") == 1)
        selected.reply(["status": "accepted", "actionId": "a", "dispatchEffect": "focusedExisting"])
        precondition(entity.finished == ["accepted"])

        let command = Fixture()
        let commandRequest = command.start("split", rows: [row("default"), commandRow("newSplitView")], defaultID: "default")
        precondition(command.client.select(command.token("newSplitView", request: commandRequest), ordinaryIntent: "currentTab") == "submitted")
        precondition(command.transport.take("select").payload["intent"] as? String == "runCommand")

        let ordinary = Fixture()
        var action = row("share")
        action["action"] = "action"
        action["allowedIntents"] = ["auto"]
        let ordinaryRequest = ordinary.start("share", rows: [row("default"), action], defaultID: "default")
        precondition(ordinary.client.select(ordinary.token("share", request: ordinaryRequest), ordinaryIntent: "newForegroundTab") == "submitted")
        precondition(ordinary.transport.take("select").payload["intent"] as? String == "auto")

        let navigation = Fixture()
        let navigationRequest = navigation.start(rows: [row("default")], defaultID: "default")
        precondition(navigation.client.select(navigation.token("default", request: navigationRequest), ordinaryIntent: "switchToTab") == "unsupported_intent")
        precondition(navigation.client.select(navigation.token("default", request: navigationRequest), ordinaryIntent: "currentTab") == "submitted")
        precondition(navigation.transport.take("select").payload["intent"] as? String == "currentTab")
    }

    @MainActor
    static func staleOrExpiredTokenCannotSelect() {
        let fixture = Fixture()
        let first = fixture.start(rows: [row("default")], defaultID: "default")
        let old = fixture.token("default", request: first)
        let second = fixture.client.query(text: "query2", preventInline: false)!
        precondition(!fixture.client.canSelect(old) && fixture.client.isAwaitingSnapshot)
        precondition(fixture.client.select(old, ordinaryIntent: "currentTab") == "stale")
        fixture.transport.take("start").reply(envelope(second, rows: [row("default")], defaultID: "default"))
        let current = fixture.token("default", request: second)
        precondition(fixture.client.canSelect(current))
        fixture.clock = fixture.clock.addingTimeInterval(26)
        precondition(!fixture.client.canSelect(current) && !fixture.client.hasSettledSnapshot)
        precondition(!fixture.client.isAwaitingSnapshot)
        precondition(fixture.client.select(current, ordinaryIntent: "currentTab") == "stale")
        precondition(fixture.transport.count("select") == 0)
        fixture.client.close()
    }

    @MainActor
    static func finishWaitsForInFlightSelection() {
        let fixture = Fixture()
        let request = fixture.start(rows: [row("pin", native: true)])
        precondition(fixture.client.select(fixture.token("pin", request: request), ordinaryIntent: "currentTab") == "submitted")
        fixture.client.finish()
        precondition(fixture.transport.count("end") == 0 && fixture.client.mode == .active)
        fixture.transport.take("select").reply(["status": "accepted", "actionId": "a", "dispatchEffect": "newTab"])
        precondition(fixture.finished == ["accepted"])
        precondition(fixture.transport.count("end") == 1 && fixture.client.mode == .closed)

        let receipt = Fixture()
        let next = receipt.start(rows: [row("default")], defaultID: "default")
        receipt.client.select(receipt.token("default", request: next), ordinaryIntent: "currentTab")
        receipt.transport.take("select").reply(["status": "accepted", "dispatchEffect": "newTab"])
        precondition(receipt.finished == ["invalid_receipt"])
        receipt.client.finish()
        precondition(receipt.transport.count("end") == 1)
    }

    @MainActor
    static func unavailableRowsKeepKeywordHints() {
        let fixture = Fixture()
        func unavailable(_ id: String, reason: String) -> [String: Any] {
            var result = row(id)
            result["allowedIntents"] = [String]()
            result["unavailableReason"] = reason
            var display = match(result)
            display["allowedToBeDefaultMatch"] = false
            display["description"] = "Search YouTube"
            result["match"] = display
            return result
        }
        let request = fixture.start("you", rows: [row("default"), unavailable("hint", reason: "keyword_hint"),
                                                  unavailable("broken", reason: "unsupported_action")],
                                    defaultID: "default")
        precondition(fixture.displayed[1]["description"] as? String == "Search YouTube")
        precondition(fixture.displayed[2]["description"] as? String != "Search YouTube")
        precondition(fixture.client.select(fixture.token("hint", request: request), ordinaryIntent: "currentTab") == "unavailable")
        precondition(fixture.transport.count("select") == 0)
        fixture.client.close()
    }

    @MainActor
    static func deleteOnlyOrdinaryRows() {
        let fixture = Fixture()
        var history = row("history")
        var display = match(history)
        display["deletable"] = true
        history["match"] = display
        var pin = row("pin", native: true)
        var pinDisplay = match(pin)
        pinDisplay["deletable"] = true
        pin["match"] = pinDisplay
        let request = fixture.start(rows: [row("default"), history, pin], defaultID: "default")
        precondition(fixture.displayed[1]["deletable"] as? Bool == true)
        precondition(fixture.displayed[2]["deletable"] as? Bool == false)
        var deleted: Bool?
        fixture.client.delete(fixture.token("history", request: request)) { deleted = $0 }
        let call = fixture.transport.take("delete")
        precondition(call.payload["resultId"] as? String == "history" && call.payload["revision"] as? UInt64 == 1)
        call.reply(["status": "deleted"])
        precondition(deleted == true)
        fixture.client.delete(fixture.token("history", request: request + 1)) { deleted = $0 }
        precondition(deleted == false && fixture.transport.count("delete") == 1)
        fixture.client.close()
    }

    @MainActor
    static func invalidationClosesSession() {
        let fixture = Fixture()
        fixture.start(rows: [row("default")], defaultID: "default")
        precondition(fixture.transport.count("watch") == 0)
        fixture.transport.take("invalidation").reply(["status": "closed", "reason": "idle_expired"])
        precondition(fixture.client.mode == .closed && fixture.closed == ["idle_expired"])
        precondition(fixture.transport.count("end") == 1)
        precondition(fixture.client.query(text: "again", preventInline: false) == nil)
    }

    @MainActor
    static func malformedCapabilityAndEnvelopeFailClosed() {
        let fixture = Fixture(connect: false)
        var invalid = caps()
        invalid["targetEligibility"] = false
        fixture.transport.take("begin").reply(["session": "bad-context", "capabilities": invalid])
        precondition(fixture.client.mode == .closed && fixture.transport.count("start") == 0)

        let limits = Fixture()
        let request = limits.client.query(text: "query", preventInline: false)!
        limits.transport.take("start").reply(envelope(request, rows: (0..<9).map { row("r\($0)") }, defaultID: "r0"))
        precondition(limits.client.mode == .closed)

        let badDefault = Fixture()
        let next = badDefault.client.query(text: "query", preventInline: false)!
        var notDefault = row("default")
        var display = match(notDefault)
        display["allowedToBeDefaultMatch"] = false
        notDefault["match"] = display
        badDefault.transport.take("start").reply(envelope(next, rows: [notDefault], defaultID: "default"))
        precondition(badDefault.client.mode == .closed)
    }

    @MainActor
    static func missingCapabilitiesFallbackOnlyInitially() {
        let missing = Fixture(connect: false)
        missing.transport.take("begin").reply(["status": "missing_api"])
        precondition(missing.client.mode == .legacy)
        let disabled = Fixture(connect: false)
        var disabledCaps = caps()
        disabledCaps["protocolVersion"] = 0
        disabled.transport.take("begin").reply(["capabilities": disabledCaps])
        precondition(disabled.client.mode == .legacy)
        let malformed = Fixture(connect: false)
        malformed.transport.take("begin").reply(["error": "unavailable"])
        precondition(malformed.client.mode == .closed)
    }

    @MainActor
    static func commandCannotBeDefault() {
        let armed = Fixture()
        var command = commandRow("manageExtensions")
        var display = match(command)
        display["allowedToBeDefaultMatch"] = true
        command["match"] = display
        let request = armed.client.query(text: "ext", preventInline: false)!
        armed.transport.take("start").reply(envelope(request, rows: [command], defaultID: "manageExtensions"))
        precondition(armed.client.mode == .closed)

        let wrongIntent = Fixture()
        var entity = commandRow("manageExtensions")
        entity["allowedIntents"] = ["openEntity"]
        let next = wrongIntent.client.query(text: "ext", preventInline: false)!
        wrongIntent.transport.take("start").reply(envelope(next, rows: [entity]))
        precondition(wrongIntent.client.mode == .closed)
    }

    @MainActor
    static func lateSnapshotOfOldQueryIsIgnored() async {
        let fixture = Fixture()
        let first = fixture.start(rows: [row("first")], defaultID: "first", done: false)
        let watch = await fixture.transport.waitFor("watch")
        let second = fixture.start("second", rows: [row("second")], defaultID: "second")
        watch.reply(envelope(first, revision: 2, rows: [row("stale")], defaultID: "stale"))
        precondition(fixture.displayedText == "second" && fixture.client.request == second)
        precondition((fixture.displayed[0]["phiV2"] as! [String: Any])["resultId"] as? String == "second")
        fixture.client.stop()
        precondition(!fixture.client.canSelect(fixture.token("second", request: second)))
        fixture.client.close()
    }
}
