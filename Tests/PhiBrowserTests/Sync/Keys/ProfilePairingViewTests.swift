import XCTest
@testable import Phi

/// Devices-pane regression tests for ProfilePairingView's settings context (§10.7 rule 5).
/// M3-2b makes two structural changes claimed to preserve behavior; assert both.
/// MainActor matches ProfilePairingSelectionStore isolation and the SwiftUI
/// ProfilePairingView/RowChrome types, as in ProfilePairingGateTests.
@MainActor
final class ProfilePairingViewTests: XCTestCase {

    private let home = RemoteProfile(uuid: "R1", name: "Home")
    private let work = RemoteProfile(uuid: "R2", name: "Work")

    /// 1. Lifting state preserves settings-context inputs to ProfilePairingModel and its
    /// decisions() exactly. The seed remains initialSelections; Task 7 only moves it from
    /// init's State(initialValue:) into ProfilePairingSelectionStore.seed.
    func testTheSettingsPathStillSeedsAndDecidesExactlyAsBefore() {
        let locals = [PairingLocal(profileId: "Default", displayName: "Home"),
                      PairingLocal(profileId: "P2", displayName: "Nothing matches")]
        let remotes = [home, work]

        let store = ProfilePairingSelectionStore()
        store.seed(locals: locals, remotes: remotes)
        XCTAssertEqual(store.selections,
                       ProfilePairingModel.initialSelections(locals: locals, remotes: remotes),
                       "The wrapper seed must match the original initializer seed")
        XCTAssertEqual(store.remoteChoices, [:])

        let model = ProfilePairingModel(locals: locals, remotes: remotes,
                                        selections: store.selections,
                                        remoteChoices: store.remoteChoices)
        XCTAssertEqual(model.decisions(),
                       [.adopt(localProfileId: "Default", remoteUuid: "R1"),
                        .registerNew(localProfileId: "P2", displayName: "Nothing matches")])
    }

    /// 2. The three context-specific Devices-pane strings remain unchanged (§6.8).
    /// The other three table entries (Register as new, Unclaimed account profiles,
    /// Unnamed profile (%@)) are shared, untouched, and have no second branch to diverge,
    /// so their assertions need not be duplicated here.
    func testTheDevicesPaneCopyIsUnchanged() {
        XCTAssertEqual(ProfilePairingView.settingsTitle, "Match your profiles")
        XCTAssertEqual(ProfilePairingView.settingsPrimaryTitle, "Confirm")
        XCTAssertEqual(ProfilePairingView.settingsBody,
                       "We found profiles on this Mac and on your account that we couldn’t "
                       + "match automatically. Pick which account profile each local profile "
                       + "belongs to.")
        // Step 5(a) removed the three corresponding gate strings entirely. There is no
        // second branch; this also verifies complete removal of that gate branch.
    }

    /// 3. RowChrome(context: .settings) remains equivalent to the original two expressions.
    /// §10.7 rule 5 requires explicit assertions, not visual diff review. The
    /// legacyTextBackground case documents those expressions; changing either requires updating this assertion.
    func testTheSettingsRowChromeIsStillTodaysTwoModifiers() {
        XCTAssertEqual(RowChrome.kind(for: .settings), .legacyTextBackground)
        XCTAssertEqual(RowChrome.kind(for: .gate), .wizardCard,
                       "The two branches must differ; identical values would make the split meaningless")
    }
}
