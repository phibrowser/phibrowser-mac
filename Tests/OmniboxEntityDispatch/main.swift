import Foundation

func AppLogDebug(_ message: @autoclosure () -> String) {}
func AppLogInfo(_ message: @autoclosure () -> String) {}
func AppLogWarn(_ message: @autoclosure () -> String) {}

// Hostless collaborators for the actual BrowserState+Omnibox implementation.
// They record effects and model identity; they do not reimplement its policy.
@objc protocol PhiChromiumBridgeProtocol: NSObjectProtocol {
    func createOmniboxEntityTab(url: String, windowId: Int64, customGuid: String?) -> Bool
    func activateOmniboxEntityTab(tabId: Int64, windowId: Int64, expectedCustomGuid: String) -> Bool
}
final class Bridge: NSObject, PhiChromiumBridgeProtocol {
    var calls: [String] = []
    var accepts = true
    var reenter: (() -> Void)?
    func createOmniboxEntityTab(url: String, windowId: Int64, customGuid: String?) -> Bool {
        calls.append("create|\(url)|\(windowId)|\(customGuid ?? "nil")")
        reenter?()
        return accepts
    }
    func activateOmniboxEntityTab(tabId: Int64, windowId: Int64, expectedCustomGuid: String) -> Bool {
        calls.append("focus|\(tabId)|\(windowId)|\(expectedCustomGuid)")
        reenter?()
        return accepts
    }
}
final class ChromiumLauncher {
    static let shared = ChromiumLauncher()
    static func sharedInstance() -> ChromiumLauncher { shared }
    var bridge: PhiChromiumBridgeProtocol?
}
enum BrowserAccessState { case guest, signedIn, loginRequired }
final class ApplicationState {
    static let shared = ApplicationState()
    var canUseBrowser = true
    var isOmniboxAuthorityTransitioning = false
    var browserAccessState: BrowserAccessState = .signedIn
}
final class Account {
    let userID = "account"
    let userDataStorage = FileManager.default.temporaryDirectory
        .appendingPathComponent("phi-omnibox-dispatch-\(UUID().uuidString)")
}
final class AccountController {
    static let shared = AccountController()
    var localDataAccount: Account?
}
final class SpaceSessionControllersManager {
    static let shared = SpaceSessionControllersManager()
    var isGuestTransitionInteractionBlocked = false
}
final class PhiChromiumCoordinator {
    static let shared = PhiChromiumCoordinator()
    var isBackupImportInProgress = false
}
final class SpaceManager {
    static let shared = SpaceManager()
    func acceptsStoreAction(from: UUID?) -> Bool { true }
}
final class LocalStore {
    let identifier = UUID()
    let account: Account
    var container: Bool? = true
    var isClosedForAccountDirectoryRemoval = false
    var lastSeen: [String] = []
    init(_ account: Account) { self.account = account }
    func updateLastSeen(_ id: String) { lastSeen.append(id) }
}
final class Controller {
    weak var browserState: BrowserState?
    var isDormant = false
    var isPresentedOrLegacy = true
    var lifecycleWindow: NSObject? = NSObject()
}
final class Tab {
    var guid = -1
    var guidInLocalDB: String? = "entity"
    var url: String?
    var webContentWrapper: NSObject?
    var isOpenned = false
    var isPinned = true
    var windowId = 1
    var groupToken: String?
    var splitPartnerGuid: String?
    var splitPaneGuids: [String] = []
}
final class Bookmark {
    var guid = "entity"
    var chromiumTabGuid = -1
    var webContentWrapper: NSObject?
    var isOpened = false
    var isFolder = false
    var secondaryUrl: String?
}
final class BookmarkManager {
    var entries: [Bookmark] = []
    func getAllBookmarks() -> [Bookmark] { entries }
}
struct Pending {
    var partnerTabId = -1
    var boundBookmarkGuid: String?
    func partnerTabIds(in state: BrowserState) -> [Int] { [partnerTabId] }
}
struct Layout { var isTraditional = false }
struct SplitGroup { var id: String }
final class BrowserState {
    let windowId = 1
    let profileId = "profile"
    let spaceId = "space"
    let localStore: LocalStore
    var windowController: Controller?
    var isIncognito = false
    var isKioskWindow = false
    var isAgentSpace = false
    var groupOverviewState: Bool?
    var pendingSplitPreview: Bool?
    var peekVisible = false
    var focusingTab: Tab?
    var tabs: [Tab] = []
    var pinnedTabs: [Tab] = []
    var tabsAwaitingSplit = Set<Int>()
    var splitTabs = Set<Int>()
    var pendingSplitPartnerByCustomGuid: [String: Pending] = [:]
    var pendingPrimarySplitTargetByGuid: [String: Pending] = [:]
    var pendingPinnedSplitRecreateGuids = Set<String>()
    var pendingSplitAfterPinnedOpen = Set<String>()
    var splitBookmarkBindings: [String: String] = [:]
    var layoutMode = Layout()
    var manager = BookmarkManager()
    var bookmarkReads = 0
    var bookmarkManager: BookmarkManager { bookmarkReads += 1; return manager }
    var clearedSelection = 0
    var splits: [SplitGroup] = []
    var pinnedSplitMembers: [String]?
    var opened: [String] = []
    init(_ store: LocalStore) { localStore = store }
    func visiblePeek(focusingTab: Tab?) -> Bool? { peekVisible ? true : nil }
    func splitGroup(forTabId id: Int) -> Bool? { splitTabs.contains(id) ? true : nil }
    func pinnedSplitDBGuids(forPinnedTab tab: Tab) -> [String]? { pinnedSplitMembers }
    func openPinnedSplit(dbGuids: [String], focusGuid: String?) {
        opened.append("pinnedSplit|\(dbGuids.joined(separator: ","))|\(focusGuid ?? "nil")")
    }
    func openBookmark(_ bookmark: Bookmark) { opened.append("bookmark|\(bookmark.guid)") }
    func duplicateOmniboxSplit(_ entity: OmniboxNativeEntity) { opened.append("copy|\(entity.entityID)") }
    func omniboxCommandCatalog() -> OmniboxNativeCommandSnapshot { .init(status: .complete, entities: []) }
    static func isPeekTabGuid(_ value: String?) -> Bool { value?.hasPrefix("phi-peek:") == true }
    func clearMultiSelection() { clearedSelection += 1 }
    func focuseTab(_ tab: Tab) { focusingTab = tab }
}

@main
enum OmniboxEntityDispatchTests {
    @MainActor
    static func main() {
        let account = Account()
        AccountController.shared.localDataAccount = account
        let store = LocalStore(account)
        let state = BrowserState(store)
        let controller = Controller()
        controller.browserState = state
        state.windowController = controller
        let bridge = Bridge()
        ChromiumLauncher.shared.bridge = bridge
        let authority = OmniboxNativeContextAuthority()
        guard let scope = state.currentOmniboxNativeScope(), let binding = authority.finishBinding(scope) else {
            fatalError("Fixture must have an eligible context")
        }
        let entity = OmniboxNativeEntity(kind: .pin, entityID: "entity", title: "Saved", url: "https://saved.test/")
        let ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds: .max)
        let cache = Tab()
        state.pinnedTabs = [cache]
        func dispatch(_ value: OmniboxNativeEntity = entity) -> OmniboxNativeDispatchEffect? {
            state.dispatchOmniboxEntity(value, binding: binding, ticket: ticket,
                                       isBindingCurrent: { authority.binding == binding })
        }

        for isolate in 0..<3 {
            state.isIncognito = isolate == 0
            state.isAgentSpace = isolate == 1
            state.isKioskWindow = isolate == 2
            precondition(dispatch() == nil && bridge.calls.isEmpty && state.bookmarkReads == 0)
        }
        state.isIncognito = false; state.isAgentSpace = false; state.isKioskWindow = false
        controller.isDormant = true
        precondition(dispatch() == nil && bridge.calls.isEmpty)
        controller.isDormant = false
        state.pendingSplitPreview = true
        precondition(dispatch() == nil && bridge.calls.isEmpty)
        state.pendingSplitPreview = nil
        state.pendingSplitAfterPinnedOpen.insert("entity")
        precondition(dispatch() == nil && bridge.calls.isEmpty)
        state.pendingSplitAfterPinnedOpen.removeAll()
        bridge.accepts = false
        precondition(dispatch() == nil && store.lastSeen.isEmpty && state.clearedSelection == 0)
        bridge.calls.removeAll()
        bridge.accepts = true
        precondition(dispatch() == .createdTab)
        precondition(bridge.calls == ["create|https://saved.test/|1|entity"] && store.lastSeen == ["entity"])
        bridge.calls.removeAll()

        let live = Tab()
        live.guid = 7; live.isOpenned = true; live.isPinned = false
        live.webContentWrapper = NSObject()
        cache.guid = 7; cache.isOpenned = true; cache.webContentWrapper = live.webContentWrapper
        state.tabs = [live]
        precondition(dispatch() == .focusedExisting, "Reattached live pin flag is intentionally false")
        precondition(bridge.calls == ["focus|7|1|entity"])
        state.focusingTab = nil
        bridge.calls.removeAll()
        cache.webContentWrapper = NSObject()
        precondition(dispatch() == nil && bridge.calls.isEmpty)
        cache.webContentWrapper = live.webContentWrapper
        state.pendingSplitPartnerByCustomGuid["pending"] = Pending(partnerTabId: 7)
        precondition(dispatch() == nil && bridge.calls.isEmpty)
        state.pendingSplitPartnerByCustomGuid.removeAll()
        state.tabs = []; state.pinnedTabs = []

        let bookmark = Bookmark()
        state.manager.entries = [bookmark]
        state.layoutMode.isTraditional = true
        let saved = OmniboxNativeEntity(kind: .bookmark, entityID: "entity", title: "Saved", url: "https://saved.test/")
        precondition(dispatch(saved) == .createdTab)
        precondition(bridge.calls == ["create|https://saved.test/|1|nil"])
        bridge.calls.removeAll()
        let before = store.lastSeen.count
        bridge.reenter = { authority.close() }
        precondition(dispatch(saved) == .createdTab, "Submitted effect survives synchronous teardown")
        precondition(store.lastSeen.count == before, "Old state gets no housekeeping after reentrant close")
        precondition(dispatch(saved) == nil)
        bridge.reenter = nil

        // A fresh authority: the previous one was closed above.
        let splitAuthority = OmniboxNativeContextAuthority()
        guard let splitScope = state.currentOmniboxNativeScope(),
              let splitBinding = splitAuthority.finishBinding(splitScope) else {
            fatalError("Fixture must have an eligible context")
        }
        func dispatchSplit(_ value: OmniboxNativeEntity, copy: Bool = false) -> OmniboxNativeDispatchEffect? {
            state.dispatchOmniboxEntity(value, binding: splitBinding, ticket: ticket, duplicatesSplit: copy,
                                       isBindingCurrent: { splitAuthority.binding == splitBinding })
        }
        let panes = [OmniboxNativePane(title: "One", url: "https://one.test/"),
                     OmniboxNativePane(title: "Two", url: "https://two.test/")]
        bridge.calls.removeAll()
        state.manager.entries = []

        let pinSplit = OmniboxNativeEntity(kind: .pin, entityID: "a", title: "One | Two",
                                           url: "https://one.test/", panes: panes)
        let lead = Tab()
        lead.guidInLocalDB = "a"
        state.pinnedTabs = [lead]
        precondition(dispatchSplit(pinSplit) == nil, "No persisted split membership")
        state.pinnedSplitMembers = ["a", "b"]
        state.pendingPinnedSplitRecreateGuids = ["b"]
        precondition(dispatchSplit(pinSplit) == nil, "A split being recreated is refused")
        state.pendingPinnedSplitRecreateGuids = []
        let grouped = Tab()
        grouped.guid = 9; grouped.guidInLocalDB = "b"; grouped.groupToken = "group"
        state.tabs = [grouped]
        precondition(dispatchSplit(pinSplit) == nil, "A grouped member is refused")
        state.tabs = []
        store.lastSeen.removeAll()
        precondition(dispatchSplit(pinSplit) == .openedSplit)
        precondition(state.opened == ["pinnedSplit|a,b|nil"] && bridge.calls.isEmpty)
        precondition(store.lastSeen == ["a", "b"])
        state.opened.removeAll()

        // A copy needs no free membership and leaves the pin unvisited.
        store.lastSeen.removeAll()
        state.pendingPinnedSplitRecreateGuids = ["b"]
        precondition(dispatchSplit(pinSplit, copy: true) == .openedSplit)
        precondition(state.opened == ["copy|a"] && store.lastSeen.isEmpty && bridge.calls.isEmpty)
        state.pendingPinnedSplitRecreateGuids = []
        let solo = OmniboxNativeEntity(kind: .pin, entityID: "a", title: "One", url: "https://one.test/")
        precondition(dispatchSplit(solo, copy: true) == nil, "Only a split has a copy")
        state.opened.removeAll()

        let bookmarkSplit = OmniboxNativeEntity(kind: .bookmark, entityID: "s", title: "One | Two",
                                                url: "https://one.test/", panes: panes)
        precondition(dispatchSplit(bookmarkSplit) == nil, "Unknown bookmark")
        let splitBookmark = Bookmark()
        splitBookmark.guid = "s"; splitBookmark.secondaryUrl = "https://two.test/"
        state.manager.entries = [splitBookmark]
        state.pendingPrimarySplitTargetByGuid["pending"] = Pending(boundBookmarkGuid: "s")
        precondition(dispatchSplit(bookmarkSplit) == nil, "A split being opened is refused")
        state.pendingPrimarySplitTargetByGuid.removeAll()
        precondition(dispatchSplit(bookmarkSplit) == .openedSplit)
        precondition(state.opened == ["bookmark|s"] && bridge.calls.isEmpty)
        print("OmniboxEntityDispatch: actual helper scope/binding/submission checks passed")
    }
}
