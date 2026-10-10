import XCTest
@testable import Phi

/// The shared delete confirmations (R8): the synced-devices sentence appears only for a
/// paired Mac and an object with a sync identity, and sits before the not-drained warning.
/// Text assertions compare the assembled paragraphs structurally so they hold in any app language.
@MainActor
final class SyncedDeletionConfirmationTests: XCTestCase {
    func testNoticeRequiresPairingAndASyncIdentity() {
        let mapped: (String) -> String? = { $0 == "local-1" ? "uuid-1" : nil }
        XCTAssertTrue(SyncedDeletionNotice.applies(isPaired: true, syncIdentity: mapped, localId: "local-1"))
        XCTAssertFalse(SyncedDeletionNotice.applies(isPaired: false, syncIdentity: mapped, localId: "local-1"),
                       "An unpaired Mac publishes nothing, so nothing reaches other devices")
        XCTAssertFalse(SyncedDeletionNotice.applies(isPaired: true, syncIdentity: mapped, localId: "local-2"),
                       "An object without a sync identity stays local")
        XCTAssertFalse(SyncedDeletionNotice.applies(isPaired: true, syncIdentity: nil, localId: "local-1"),
                       "No installed lookup means no sync engine")
    }

    func testSharedPredicatesAreFalseWithoutInstalledLookups() {
        let state = PhiSpaceSyncState.shared
        let savedSpaceLookup = state.syncUuidLookup
        let savedProfileLookup = state.globalUuidLookup
        defer {
            state.syncUuidLookup = savedSpaceLookup
            state.globalUuidLookup = savedProfileLookup
        }
        state.syncUuidLookup = nil
        state.globalUuidLookup = nil
        XCTAssertFalse(SyncedDeletionNotice.appliesToSpace("space-1"))
        XCTAssertFalse(SyncedDeletionNotice.appliesToProfile("profile-1"))
    }

    func testSpaceNoteIsAppendedAsItsOwnParagraph() {
        for scope in [PinnedTabScope.space, .profile, .app] {
            let base = SpaceDeletionConfirmation.informativeText(pinnedTabScope: scope, showsSyncedDevicesNote: false)
            let withNote = SpaceDeletionConfirmation.informativeText(pinnedTabScope: scope, showsSyncedDevicesNote: true)
            XCTAssertTrue(withNote.hasPrefix(base + "\n\n"))
            XCTAssertGreaterThan(withNote.count, base.count + 2)
        }
        XCTAssertNotEqual(
            SpaceDeletionConfirmation.informativeText(pinnedTabScope: .space, showsSyncedDevicesNote: false),
            SpaceDeletionConfirmation.informativeText(pinnedTabScope: .profile, showsSyncedDevicesNote: false),
            "Space-scoped pinned tabs are named in the body")
    }

    func testProfileNoteComesBeforeTheNotDrainedWarning() {
        let base = ProfileDeletionFlow.informativeText(showsSyncedDevicesNote: false, showsNotDrainedWarning: false)
        let noteOnly = ProfileDeletionFlow.informativeText(showsSyncedDevicesNote: true, showsNotDrainedWarning: false)
        let warningOnly = ProfileDeletionFlow.informativeText(showsSyncedDevicesNote: false, showsNotDrainedWarning: true)
        let both = ProfileDeletionFlow.informativeText(showsSyncedDevicesNote: true, showsNotDrainedWarning: true)
        XCTAssertTrue(noteOnly.hasPrefix(base + "\n\n"))
        XCTAssertTrue(warningOnly.hasPrefix(base + "\n\n"))
        let note = String(noteOnly.dropFirst(base.count))
        let warning = String(warningOnly.dropFirst(base.count))
        XCTAssertNotEqual(note, warning)
        XCTAssertEqual(both, base + note + warning)
    }

    func testCatalogCarriesTheNewEnglishOnlyKeysAndDropsTheDuplicatedFamilies() throws {
        let root = Self.repositoryRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let expected = [
            "settings.spaces.deleteConfirmation.syncedDevicesNote": "This Space will also be deleted from your other synced devices.",
            "settings.profiles.deleteConfirmation.syncedDevicesNote": "This profile will also be deleted from your other synced devices.",
            "profiles.delete.syncRecordFailed": "Could not save the sync deletion record. Please try again.",
        ]
        for (key, english) in expected {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog entry \(key)")
            XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, "\(key) needs a translator comment")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let value = ((localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertEqual(value, english, key)
        }

        let removedPrefixes = ["sidebar.deleteSpaceConfirmation.", "app.deleteSpaceConfirmation.",
                               "app.deleteProfileConfirmation.", "app.deleteProfileFailure."]
        let leftovers = strings.keys.filter { key in removedPrefixes.contains { key.hasPrefix($0) } }
        XCTAssertTrue(leftovers.isEmpty, "Duplicated delete-confirmation keys remain: \(leftovers.sorted())")
    }

    /// Three deletingLastPathComponent() calls reach the repository root from
    /// Tests/PhiBrowserTests/SyncedDeletionConfirmationTests.swift.
    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url = url.deletingLastPathComponent() }
        return url
    }
}
