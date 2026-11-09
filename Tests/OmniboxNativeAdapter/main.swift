import Combine
import Foundation

func AppLogDebug(_ message: @autoclosure () -> String) {}
func AppLogInfo(_ message: @autoclosure () -> String) {}
func AppLogWarn(_ message: @autoclosure () -> String) {}
final class Account {
    let userDataStorage = FileManager.default.temporaryDirectory
        .appendingPathComponent("phi-omnibox-adapter-\(UUID().uuidString)")
}
final class AccountController {
    static let shared = AccountController()
    var localDataAccount: Account?
}

@objc protocol PhiChromiumBridgeProtocol: NSObjectProtocol {
    func revokeOmniboxSearchContext(windowId: Int64, expectedBindingToken: String, reason: String) -> Bool
    func refreshOmniboxNativeData(windowId: Int64, expectedBindingToken: String) -> Bool
}
final class ChromiumLauncher {
    static let shared = ChromiumLauncher()
    static func sharedInstance() -> ChromiumLauncher { shared }
    var bridge: PhiChromiumBridgeProtocol?
}
enum OmniboxNativeDispatchEffect: String, Sendable {
    case createdTab = "created_tab", focusedExisting = "focused_existing"
}
final class PhiChromiumCoordinator {}
@MainActor final class SpaceSessionController {
    let browserState: BrowserState
    init(_ state: BrowserState) { browserState = state }
}
@MainActor final class SpaceSessionControllersManager {
    static let shared = SpaceSessionControllersManager()
    var fixture: SpaceSessionController?
    func controller(for id: Int) -> SpaceSessionController? {
        fixture?.browserState.windowId == id ? fixture : nil
    }
}

@MainActor final class Tab {
    let guid: Int
    @Published var groupToken: String?
    init(_ guid: Int) { self.guid = guid }
}
@MainActor final class PeekState {
    @Published var peeksByOpener: [Int: Tab] = [:]
}
@MainActor final class LocalStore {
    static let willCloseNotification = Notification.Name("FixtureStoreWillClose")
    static let omniboxNativeDataWillChangeNotification = Notification.Name("FixtureOmniboxDataWillChange")
    let identifier = UUID()
    let admission = OmniboxReadAdmission()
    var jobs: [@Sendable () async -> Void] = []
    var selections: [() -> Void] = []
    var reads = 0
    func makeOmniboxQueryCoordinator<Value: Sendable>() -> OmniboxNativeQueryCoordinator<Value> {
        OmniboxNativeQueryCoordinator(admission: admission) { [weak self] job in
            self?.jobs.append(job)
            return self != nil
        }
    }
    func readOmniboxSnapshot(profileID: String, spaceID: String, ticket: OmniboxQueryTicket) async throws -> OmniboxNativeSearchSnapshot {
        reads += 1
        return .init(mutationEpoch: "0", pinScope: "space",
            bookmarks: .init(status: .complete, entities: []),
            pins: .init(status: .complete, entities: []))
    }
    func performOmniboxEntitySelection<Value: Sendable>(
        _ entity: OmniboxNativeEntity, expectedEpoch: String, expectedPinScope: String,
        profileID: String, spaceID: String, ticket: OmniboxQueryTicket,
        dispatch: @escaping @MainActor @Sendable (OmniboxNativeEntity) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            selections.append {
                do {
                    if let error = ticket.failure(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) { throw error }
                    continuation.resume(returning: try dispatch(entity))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
@MainActor final class BrowserState {
    let windowId = 1
    let localStore = LocalStore()
    var omniboxNativeSearchAdapter: OmniboxNativeSearchAdapter?
    @Published var focusingTab: Tab?
    @Published var groupOverviewState: Bool?
    @Published var pendingSplitPreview: Bool?
    @Published var tabsAwaitingSplit: Set<Int> = []
    @Published var splits: [Int] = []
    let peekState = PeekState()
    var dispatches = 0
    var scheduledCommands: [String] = []
    var learned: [String] = []
    func recordOmniboxSelection(_ entity: OmniboxNativeEntity, learningText: String) {
        learned.append("\(entity.kind.rawValue):\(entity.entityID):\(learningText)")
    }
    func recordOmniboxOrdinaryChoice(learningText: String) {
        learned.append("ordinary:\(learningText)")
    }
    func scheduleOmniboxCommand(_ commandID: String) -> Bool {
        guard commandID == "newSplitView" else { return false }
        scheduledCommands.append(commandID)
        return true
    }
    func currentOmniboxNativeScope() -> OmniboxNativeContextAuthority.Scope? {
        .init(windowID: 1, accountID: "account", storeID: localStore.identifier,
              profileID: "profile", spaceID: "space", access: .signedIn,
              targetID: focusingTab?.guid, stateIdentity: ObjectIdentifier(self))
    }
    func decorateOmniboxSnapshot(_ snapshot: OmniboxNativeSearchSnapshot, ticket: OmniboxQueryTicket) throws -> OmniboxNativeSearchSnapshot {
        try snapshot.withRuntimeMetadata(ticket: ticket) { _ in (false, nil) }
    }
    func dispatchOmniboxEntity(_ entity: OmniboxNativeEntity, binding: OmniboxNativeContextAuthority.Binding,
                              ticket: OmniboxQueryTicket, isBindingCurrent: () -> Bool) -> OmniboxNativeDispatchEffect? {
        guard isBindingCurrent(), ticket.isValid(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) else { return nil }
        dispatches += 1
        return .createdTab
    }
}

@main enum OmniboxNativeAdapterTests {
    @MainActor static func main() async {
        let state = BrowserState()
        let a = Tab(10), b = Tab(11)
        state.focusingTab = a
        var events: [String] = []
        let adapter = OmniboxNativeSearchAdapter(state: state) { _, _, _ in events.append("revoke"); return true }
        let first = adapter.beginSession("one", profileID: "profile", targetID: 10)!
        adapter.query(sessionID: "one", token: first.token, request: 1) { result in
            if case .failure(.cancelled) = result { events.append("cancelled") }
            else { fatalError("Old query must be cancelled") }
        }
        state.focusingTab = b
        state.focusingTab = a
        precondition(events == ["revoke", "cancelled"], "C revoke must precede query callbacks")
        precondition(adapter.beginSession("two", profileID: "profile", targetID: 10) == nil,
                     "Will-change cannot rebind the not-yet-committed old scope")
        for _ in 0..<10 { await Task.yield() }
        let second = adapter.beginSession("two", profileID: "profile", targetID: 10)!
        precondition(second.token != first.token)
        let oldRead = state.localStore.jobs.removeFirst()
        await oldRead()
        for _ in 0..<10 { await Task.yield() }
        precondition(state.localStore.reads == 0)

        var received = false
        adapter.query(sessionID: "two", token: second.token, request: 1) { result in
            if case .success = result { received = true }
        }
        await state.localStore.jobs.removeFirst()()
        for _ in 0..<10 { await Task.yield() }
        precondition(received && state.localStore.reads == 1)
        let entity = OmniboxNativeEntity(kind: .pin, entityID: "pin", title: "Saved", url: "https://saved.test/")
        let pending = Task { @MainActor in
            await adapter.execute(sessionID: "two", token: second.token, request: 1,
                entity: entity, expectedEpoch: "0", expectedPinScope: "space", learningText: "sav")
        }
        for _ in 0..<10 { await Task.yield() }
        precondition(state.localStore.selections.count == 1)
        adapter.query(sessionID: "two", token: second.token, request: 2) { _ in }
        let duplicate = await adapter.execute(sessionID: "two", token: second.token, request: 2,
            entity: entity, expectedEpoch: "0", expectedPinScope: "space", learningText: "sav")
        precondition(duplicate == nil && state.localStore.selections.count == 1)
        state.localStore.selections.removeFirst()()
        let cancelled = await pending.value
        precondition(cancelled == nil && state.dispatches == 0 && state.learned.isEmpty,
                     "A selection that did not dispatch is not learned")
        adapter.query(sessionID: "two", token: second.token, request: 3) { result in
            if case .failure(.cancelled) = result {
                // The replacement deadline starts before this external callback.
                Thread.sleep(forTimeInterval: 0.32)
            }
        }
        var expiredImmediately = false
        adapter.query(sessionID: "two", token: second.token, request: 4) { result in
            if case .failure(.expired) = result { expiredImmediately = true }
        }
        precondition(expiredImmediately, "An old callback must not restart the new deadline")
        state.omniboxNativeSearchAdapter = adapter
        SpaceSessionControllersManager.shared.fixture = SpaceSessionController(state)
        let bridge = PhiChromiumCoordinator()
        var rejected = false
        bridge.queryNativeOmniboxSession("two", bindingToken: "wrong", request: 5, windowId: 1) { json, status in
            rejected = json == nil && status == "unavailable"
        }
        precondition(rejected)
        var badActionRejected = false
        bridge.executeNativeOmniboxSession("two", bindingToken: second.token, request: 4,
            windowId: 1, frozenEntityJSON: "{}", mutationEpoch: "0", pinScope: "space",
            learningText: "sav") { status, effect in
            badActionRejected = status == "stale" && effect == nil
        }
        precondition(badActionRejected && state.dispatches == 0)
        var commandStatuses: [String] = []
        for (token, request, id) in [("wrong", UInt64(4), "newSplitView"), (second.token, 3, "newSplitView"),
                                     (second.token, 4, "unknown"), (second.token, 4, "newSplitView")] {
            bridge.executeNativeOmniboxCommand("two", bindingToken: token, request: request,
                windowId: 1, commandId: id) { commandStatuses.append($0) }
        }
        precondition(commandStatuses == ["stale", "stale", "rejected", "accepted"] &&
                     state.scheduledCommands == ["newSplitView"])
        adapter.query(sessionID: "two", token: second.token, request: 5) { _ in }
        let accepted = Task { @MainActor in
            await adapter.execute(sessionID: "two", token: second.token, request: 5,
                entity: entity, expectedEpoch: "0", expectedPinScope: "space", learningText: "sav")
        }
        for _ in 0..<10 { await Task.yield() }
        state.localStore.selections.removeFirst()()
        let acceptedEffect = await accepted.value
        precondition(acceptedEffect == .createdTab && state.learned == ["pin:pin:sav"],
                     "An accepted selection records its frozen input once")
        bridge.recordOrdinaryOmniboxChoice("two", bindingToken: "wrong", request: 5, windowId: 1, learningText: "sa")
        bridge.recordOrdinaryOmniboxChoice("two", bindingToken: second.token, request: 4, windowId: 1, learningText: "sa")
        bridge.recordOrdinaryOmniboxChoice("two", bindingToken: second.token, request: 5, windowId: 1, learningText: "sa")
        precondition(state.learned == ["pin:pin:sav", "ordinary:sa"],
                     "Only the current request of the bound session records an ordinary choice")
        bridge.endNativeOmniboxSession("two", windowId: 1)
        adapter.close(reason: "window_closed")
        print("OmniboxNativeAdapter: actual context/FIFO cancellation and action occupancy passed")
    }
}
