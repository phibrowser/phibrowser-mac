import XCTest
@testable import Phi

@MainActor
final class SiteMemoryMenuActionsTests: XCTestCase {
    private func temporaryService() -> SiteMemoryService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SiteMemoryService(accountID: UUID().uuidString, settings: SiteMemorySettingsStore(
            fileURL: directory.appendingPathComponent("settings.json")))
    }

    private func actions(
        url: String = "https://EXAMPLE.COM./page?query=1",
        profileID: String = "Profile 2",
        isIncognito: Bool = false,
        isPhiAIEnabled: Bool = true,
        service: SiteMemoryService? = nil
    ) -> SiteMemoryMenuActions? {
        SiteMemoryMenuActions(urlString: url, profileID: profileID, isIncognito: isIncognito,
                              isPhiAIEnabled: isPhiAIEnabled, service: service)
    }

    func testBothMenusExcludePrivateDisabledAndUnsupportedPageContexts() {
        XCTAssertNil(actions(isIncognito: true))
        XCTAssertNil(actions(isPhiAIEnabled: false))
        XCTAssertNil(actions(profileID: ""))
        for url in ["", "phi://settings", "chrome://newtab", "file:///tmp/example.html", "about:blank", "https://[::1]/"] {
            XCTAssertNil(actions(url: url), url)
        }
        XCTAssertNotNil(actions(url: "http://example.com/path"))
        XCTAssertNotNil(actions(url: "https://example.com/path"))
    }

    func testStandaloneMenuContainsOnlyMemoryActionsWithCurrentState() throws {
        let service = temporaryService()
        for enabled in [true, false] {
            try service.setCollectionEnabled(enabled, for: "example.com", profileID: "Profile 2")
            let snapshot = try XCTUnwrap(actions(service: service))
            let menu = WebContentAddressBarMenuPresenter.makeMemoryMenu(actions: snapshot, window: nil)
            XCTAssertEqual(menu.items.map(\.title), [SiteMemoryMenuActions.collectionTitle, SiteMemoryMenuActions.removalTitle])
            XCTAssertFalse(menu.autoenablesItems)
            XCTAssertEqual(menu.items[0].state, enabled ? .on : .off)
            XCTAssertTrue(menu.items.allSatisfy { $0.isEnabled && $0.target != nil && $0.action != nil })
        }
        let unavailable = WebContentAddressBarMenuPresenter.makeMemoryMenu(actions: try XCTUnwrap(actions()), window: nil)
        XCTAssertEqual(unavailable.items[0].state, .mixed)
        XCTAssertTrue(unavailable.items.allSatisfy { !$0.isEnabled })
    }

    func testSidebarMovesPinnedExtensionsOutWhenMemoryButtonNeedsSpace() {
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 220, isMemoryButtonVisible: false))
        XCTAssertTrue(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 220, isMemoryButtonVisible: true))
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 300, isMemoryButtonVisible: true))
    }

    func testCollectionStateUsesExactHostProfileAndAccount() throws {
        let service = temporaryService()
        try service.setCollectionEnabled(false, for: "example.com", profileID: "Profile 2")
        let snapshot = try XCTUnwrap(actions(service: service))
        XCTAssertEqual(snapshot.host, "example.com")
        XCTAssertEqual(snapshot.profileID, "Profile 2")
        XCTAssertEqual(snapshot.collectionState, .off)
        XCTAssertTrue(snapshot.canRemoveMemories)
        XCTAssertEqual(actions(profileID: "Default", service: service)?.collectionState, .on)
        XCTAssertEqual(actions(url: "https://www.example.com", service: service)?.collectionState, .off)
        XCTAssertEqual(actions(url: "https://gov.example.com", service: service)?.collectionState, .on)
        XCTAssertEqual(actions(service: temporaryService())?.collectionState, .on)
    }

    func testMissingAccountAndUnreadableSettingsNeverAppearEnabled() throws {
        let unavailable = try XCTUnwrap(actions())
        XCTAssertNil(unavailable.collectionEnabled)
        XCTAssertEqual(unavailable.collectionState, .mixed)
        XCTAssertFalse(unavailable.canRemoveMemories)

        let service = temporaryService()
        try service.setCollectionEnabled(false, for: "example.com", profileID: "Profile 2")
        try Data("invalid JSON".utf8).write(to: service.settings.fileURL)
        let corrupt = try XCTUnwrap(actions(service: service))
        XCTAssertNil(corrupt.collectionEnabled)
        XCTAssertEqual(corrupt.collectionState, .mixed)
        XCTAssertTrue(corrupt.canRemoveMemories)
    }

    func testReopeningReadsUpdatedCollectionState() throws {
        let service = temporaryService()
        let first = try XCTUnwrap(actions(service: service))
        XCTAssertEqual(first.collectionState, .on)
        try service.setCollectionEnabled(false, for: first.host, profileID: first.profileID)
        XCTAssertEqual(actions(service: service)?.collectionState, .off)
        XCTAssertEqual(first.collectionState, .on)
    }

    func testRemovalExpandsToRegistrableDomainOnlyWhenCheckboxIsSelected() throws {
        for (host, expected) in [
            ("www.163.com", "163.com"),
            ("gov.163.com", "163.com"),
            ("163.com", "163.com"),
            ("news.example.co.uk", "example.co.uk"),
            ("docs.alice.github.io", "alice.github.io"),
            ("alice.github.io", "alice.github.io"),
            ("localhost", "localhost"),
            ("127.0.0.1", "127.0.0.1"),
            ("0.0.0.1", "0.0.0.1")
        ] {
            XCTAssertEqual(SiteMemoryMenuActions.removalHost(for: host, includeSubdomains: false), host)
            XCTAssertEqual(SiteMemoryMenuActions.removalHost(for: host, includeSubdomains: true), expected, host)
            for includeSubdomains in [false, true] {
                let target = SiteMemoryMenuActions.removalHost(for: host, includeSubdomains: includeSubdomains)
                let scope = SiteMemoryRemovalScope(host: target, includeSubdomains: includeSubdomains)
                XCTAssertEqual(scope.kind, includeSubdomains ? .site : .host)
                XCTAssertEqual(scope.host, includeSubdomains ? nil : host)
                XCTAssertEqual(scope.site, includeSubdomains ? expected : nil)
            }
        }

        let service = temporaryService()
        try service.setCollectionEnabled(false, for: "www.163.com", profileID: "Profile 2")
        let snapshot = try XCTUnwrap(actions(url: "https://www.163.com", service: service))
        XCTAssertEqual(snapshot.host, "www.163.com")
        XCTAssertEqual(snapshot.collectionEnabled, false)
        XCTAssertEqual(actions(url: "https://163.com", service: service)?.collectionEnabled, false)
        XCTAssertEqual(actions(url: "https://gov.163.com", service: service)?.collectionEnabled, true)
    }

    func testRemovalConfirmationShowsBothScopesAndStartsUnchecked() throws {
        let snapshot = try XCTUnwrap(actions(url: "https://gov.163.com", service: temporaryService()))
        let alert = snapshot.makeRemovalConfirmation()
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.buttons.count, 2)
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertTrue(alert.informativeText.contains("gov.163.com"))
        XCTAssertTrue(alert.showsSuppressionButton)
        let checkbox = try XCTUnwrap(alert.suppressionButton)
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertTrue(checkbox.title.contains("163.com"))
        XCTAssertFalse(checkbox.title.contains("gov.163.com"))
    }
}
