import XCTest
@testable import Phi

/// Covers the three halves of the registry contract: field-level LWW merge
/// (newer wins, equal timestamps converge symmetrically), snapshot-time local
/// change detection through the `<key>.phiSyncTs` / `<key>.phiSyncVal`
/// sidecars, and apply writing back only registered keys while suppressing the
/// echo the next snapshot would otherwise push.
final class SyncableSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SyncableSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func fromMap(_ m: [String: Phi_PhiSettingValue]) -> Phi_PhiSettingEntity {
        var e = Phi_PhiSettingEntity()
        e.values = m
        return e
    }

    private func boolValue(_ b: Bool, at ts: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.updatedAtMs = ts
        v.boolValue = b
        return v
    }

    private func stringValue(_ s: String, at ts: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.updatedAtMs = ts
        v.stringValue = s
        return v
    }

    private func intValue(_ i: Int64, at ts: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.updatedAtMs = ts
        v.intValue = i
        return v
    }

    /// A one-element registry over a key nothing else in the app owns, so the
    /// sidecar/echo tests do not depend on the starter set's contents.
    private let probeKey = "SyncableSettingsTests.probe"

    private var probeRegistry: [SyncableSetting] {
        let key = probeKey
        return [
            SyncableSetting(
                key: key,
                read: { d in
                    var v = Phi_PhiSettingValue()
                    v.boolValue = d.bool(forKey: key, default: false)
                    return v
                },
                write: { v, d in
                    guard case .boolValue(let b) = v.v else { return }
                    d.set(b, forKey: key)
                }
            )
        ]
    }

    private func sidecarTimestamp(_ key: String) -> Int64? {
        (defaults.object(forKey: key + ".phiSyncTs") as? NSNumber)?.int64Value
    }

    // MARK: - merge

    /// The brief's case: per key the larger `updatedAtMs` wins.
    func testFieldLevelLWWPicksTheNewerValue() {
        let older = boolValue(false, at: 10)
        let newer = boolValue(true, at: 20)

        let merged = SyncableSettings.merge(
            local: fromMap(["k": older]),
            remote: fromMap(["k": newer])
        )

        XCTAssertEqual(merged.values["k"]?.boolValue, true)
        XCTAssertEqual(merged.values["k"]?.updatedAtMs, 20)
    }

    /// The local side wins when it is the newer one — the comparison is on the
    /// timestamp, never on which side the value arrived from.
    func testFieldLevelLWWKeepsTheNewerLocalValue() {
        let merged = SyncableSettings.merge(
            local: fromMap(["k": stringValue("local", at: 99)]),
            remote: fromMap(["k": stringValue("remote", at: 98)])
        )

        XCTAssertEqual(merged.values["k"]?.stringValue, "local")
    }

    /// Equal `updatedAtMs` is broken on the serialized bytes, so swapping local
    /// and remote produces the same merged entity on both devices.
    func testEqualTimestampsConvergeSymmetrically() {
        let a = boolValue(true, at: 30)
        let b = boolValue(false, at: 30)

        let mA = SyncableSettings.merge(local: fromMap(["k": a]), remote: fromMap(["k": b]))
        let mB = SyncableSettings.merge(local: fromMap(["k": b]), remote: fromMap(["k": a]))

        XCTAssertEqual(mA, mB)
        XCTAssertEqual(mA.values["k"]?.boolValue, mB.values["k"]?.boolValue)
    }

    /// Same, for a value type whose byte ordering is not a single-byte flip.
    func testEqualTimestampsConvergeSymmetricallyForStrings() {
        let a = stringValue("alpha", at: 30)
        let b = stringValue("beta", at: 30)

        let mA = SyncableSettings.merge(local: fromMap(["k": a]), remote: fromMap(["k": b]))
        let mB = SyncableSettings.merge(local: fromMap(["k": b]), remote: fromMap(["k": a]))

        XCTAssertEqual(mA, mB)
    }

    /// Identical values on both sides survive untouched.
    func testEqualTimestampsAndEqualValuesAreStable() {
        let v = intValue(2, at: 30)

        let merged = SyncableSettings.merge(local: fromMap(["k": v]), remote: fromMap(["k": v]))

        XCTAssertEqual(merged.values["k"], v)
    }

    /// Keys only one side knows about are carried through untouched, in both
    /// directions — forward compatibility with a newer client's registry.
    func testMergeCarriesUnknownKeysThrough() {
        let merged = SyncableSettings.merge(
            local: fromMap(["localOnly": boolValue(true, at: 1)]),
            remote: fromMap(["remoteOnly": stringValue("x", at: 2)])
        )

        XCTAssertEqual(merged.values.count, 2)
        XCTAssertEqual(merged.values["localOnly"]?.boolValue, true)
        XCTAssertEqual(merged.values["remoteOnly"]?.stringValue, "x")
    }

    // MARK: - snapshot

    /// The first snapshot of a key has no sidecar, so it stamps `now` and
    /// records the value it pushed.
    func testSnapshotStampsFirstSeenKeyWithNow() {
        let entity = SyncableSettings.snapshot(defaults, now: 1_000, settings: probeRegistry)

        XCTAssertEqual(entity.values[probeKey]?.updatedAtMs, 1_000)
        XCTAssertEqual(entity.values[probeKey]?.boolValue, false)
        XCTAssertEqual(sidecarTimestamp(probeKey), 1_000)
        XCTAssertNotNil(defaults.data(forKey: probeKey + ".phiSyncVal"))
    }

    /// An unchanged value keeps its previously stamped timestamp instead of
    /// being re-stamped with `now` — otherwise local would always win LWW.
    func testSnapshotReusesTheStoredTimestampWhenNothingChanged() {
        _ = SyncableSettings.snapshot(defaults, now: 1_000, settings: probeRegistry)

        let again = SyncableSettings.snapshot(defaults, now: 2_000, settings: probeRegistry)

        XCTAssertEqual(again.values[probeKey]?.updatedAtMs, 1_000)
        XCTAssertEqual(sidecarTimestamp(probeKey), 1_000)
    }

    /// A local edit between snapshots is detected by value comparison and
    /// re-stamped with `now`.
    func testSnapshotStampsNowWhenTheValueChangedLocally() {
        _ = SyncableSettings.snapshot(defaults, now: 1_000, settings: probeRegistry)

        defaults.set(true, forKey: probeKey)
        let after = SyncableSettings.snapshot(defaults, now: 2_000, settings: probeRegistry)

        XCTAssertEqual(after.values[probeKey]?.boolValue, true)
        XCTAssertEqual(after.values[probeKey]?.updatedAtMs, 2_000)
        XCTAssertEqual(sidecarTimestamp(probeKey), 2_000)
    }

    /// A never-touched key resolves through the preference's own default, so a
    /// fresh suite (no registration domain) and the running app agree.
    func testSnapshotOfTheStarterSetUsesPreferenceDefaults() {
        let entity = SyncableSettings.snapshot(defaults, now: 5)

        let cmdT = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue
        XCTAssertEqual(entity.values[cmdT]?.boolValue, true, "default true must survive an unset key")
        XCTAssertEqual(
            entity.values[PhiPreferences.GeneralSettings.layoutModeKey]?.stringValue,
            LayoutMode.balanced.rawValue,
            "must match what loadLayoutMode() resolves to when nothing is set: navigationAtTop defaults to true"
        )
        XCTAssertEqual(
            entity.values[PhiPreferences.GeneralSettings.autoPictureInPictureModeKey]?.stringValue,
            AutoPictureInPictureMode.normal.rawValue
        )
        XCTAssertEqual(entity.values[PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue]?.intValue, 0)
        XCTAssertEqual(
            entity.values[PhiPreferences.ThemeSettings.currentThemeId.rawValue]?.stringValue,
            "default"
        )
        XCTAssertEqual(entity.values[PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue]?.boolValue, true)
    }

    /// The layout read closure replicates `GeneralSettings.loadLayoutMode()`'s
    /// legacy dual-bool fallback *through the two cases' own defaults*, so a
    /// device that has never opened the layout picker snapshots the layout it
    /// is actually displaying instead of a bogus `.performance` that would be
    /// committed and then applied back over a peer's real choice.
    func testLayoutModeSnapshotFollowsTheLegacyDualBoolFallback() {
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let traditionalKey = PhiPreferences.GeneralSettings.traditionalLayout.rawValue
        let navigationAtTopKey = PhiPreferences.GeneralSettings.navigationAtTop.rawValue

        func snapshotLayout() -> String? {
            SyncableSettings.snapshot(defaults, now: 1).values[layoutKey]?.stringValue
        }

        // Nothing set: navigationAtTop's default is true -> .balanced.
        XCTAssertEqual(snapshotLayout(), LayoutMode.balanced.rawValue)

        // traditionalLayout wins over navigationAtTop -> .comfortable.
        defaults.set(true, forKey: traditionalKey)
        XCTAssertEqual(snapshotLayout(), LayoutMode.comfortable.rawValue)

        // Both legacy bools explicitly off -> .performance.
        defaults.set(false, forKey: traditionalKey)
        defaults.set(false, forKey: navigationAtTopKey)
        XCTAssertEqual(snapshotLayout(), LayoutMode.performance.rawValue)

        // An explicit layoutMode always beats the legacy encoding.
        defaults.set(LayoutMode.balanced.rawValue, forKey: layoutKey)
        XCTAssertEqual(snapshotLayout(), LayoutMode.balanced.rawValue)
    }

    /// An unparseable `layoutMode` string falls back to the legacy encoding
    /// rather than being reported as `.performance`.
    func testLayoutModeSnapshotIgnoresAnUnparseableExplicitValue() {
        defaults.set("hyperspace", forKey: PhiPreferences.GeneralSettings.layoutModeKey)

        let entity = SyncableSettings.snapshot(defaults, now: 1)

        XCTAssertEqual(
            entity.values[PhiPreferences.GeneralSettings.layoutModeKey]?.stringValue,
            LayoutMode.balanced.rawValue
        )
    }

    /// The registry table is pinned: `key` IS the UserDefaults raw key, the
    /// Data-valued theme snapshots are excluded, and the feature gates are not
    /// synced.
    ///
    /// M3-3 adds exactly one member, `PhiPinnedTabScope` — the mirror of a SwiftData row
    /// rather than a preference of its own. It is the only member whose `read` answers nil on
    /// an unset key, because "the account has never published a scope" is not the same
    /// statement as "the scope is `.profile`".
    func testStarterRegistryContents() {
        let keys = SyncableSettings.all.map(\.key)

        XCTAssertEqual(
            Set(keys),
            [
                "openNewTabPageOnCmdT",
                "alwaysShowURLPath",
                "alwaysShowBookmarkBar",
                "showBookmarkBarOnNewTabPage",
                "suppressCloseIncognitoSpaceWarning",
                "layoutMode",
                "autoPictureInPictureMode",
                "PhiUserAppearanceChoice",
                "PhiCurrentThemeId",
                "PhiSelectionTintEnabled",
                "PhiPinnedTabScope",
            ]
        )
        XCTAssertEqual(Set(keys).count, keys.count, "no duplicate keys")
        XCTAssertFalse(keys.contains(PhiPreferences.ThemeSettings.themeSnapshots.rawValue))
        XCTAssertFalse(keys.contains(PhiPreferences.GeneralSettings.spacesFeatureEnabled.rawValue))
    }

    // MARK: - apply

    /// A merged remote value is written to the raw UserDefaults key.
    func testApplyWritesRegisteredKeys() {
        SyncableSettings.apply(
            fromMap([probeKey: boolValue(true, at: 42)]),
            to: defaults,
            settings: probeRegistry
        )

        XCTAssertTrue(defaults.bool(forKey: probeKey))
    }

    /// Echo suppression: applying a remote value records its timestamp and
    /// value in the sidecars, so the very next snapshot reports the remote
    /// timestamp rather than treating the applied value as a local edit.
    func testApplyDoesNotLookLikeALocalChangeToTheNextSnapshot() {
        _ = SyncableSettings.snapshot(defaults, now: 1_000, settings: probeRegistry)

        SyncableSettings.apply(
            fromMap([probeKey: boolValue(true, at: 5_000)]),
            to: defaults,
            settings: probeRegistry
        )
        let after = SyncableSettings.snapshot(defaults, now: 9_999, settings: probeRegistry)

        XCTAssertEqual(after.values[probeKey]?.boolValue, true)
        XCTAssertEqual(after.values[probeKey]?.updatedAtMs, 5_000, "must not be re-stamped with now")
    }

    /// A key absent from the registry is never blind-written into UserDefaults.
    func testApplyIgnoresKeysOutsideTheRegistry() {
        SyncableSettings.apply(
            fromMap(["theme.dark": boolValue(true, at: 42)]),
            to: defaults,
            settings: probeRegistry
        )

        XCTAssertNil(defaults.object(forKey: "theme.dark"))
        XCTAssertNil(defaults.object(forKey: "theme.dark.phiSyncTs"))
    }

    /// A registered key the entity does not carry is left alone.
    func testApplyLeavesAbsentKeysAlone() {
        defaults.set(true, forKey: probeKey)

        SyncableSettings.apply(fromMap([:]), to: defaults, settings: probeRegistry)

        XCTAssertTrue(defaults.bool(forKey: probeKey))
        XCTAssertNil(sidecarTimestamp(probeKey))
    }

    /// A remote value whose oneof case does not match the setting's type is
    /// dropped by the write closure, and apply must then leave the sidecars
    /// untouched so the local value is re-pushed instead of being silently
    /// marked as synced.
    func testApplyIgnoresATypeMismatchedRemoteValue() {
        SyncableSettings.apply(
            fromMap([probeKey: stringValue("not a bool", at: 42)]),
            to: defaults,
            settings: probeRegistry
        )

        XCTAssertNil(defaults.object(forKey: probeKey))
        XCTAssertNil(sidecarTimestamp(probeKey))
    }

    /// The starter set writes through to the real preference keys the settings
    /// panes bind to.
    func testApplyWritesTheStarterSetThroughToRealKeys() {
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let appearanceKey = PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue
        let urlPathKey = PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue

        SyncableSettings.apply(
            fromMap([
                layoutKey: stringValue(LayoutMode.comfortable.rawValue, at: 1),
                appearanceKey: intValue(2, at: 1),
                urlPathKey: boolValue(true, at: 1),
            ]),
            to: defaults
        )

        XCTAssertEqual(defaults.string(forKey: layoutKey), LayoutMode.comfortable.rawValue)
        XCTAssertEqual(defaults.integer(forKey: appearanceKey), 2)
        XCTAssertTrue(defaults.bool(forKey: urlPathKey))
    }

    /// An unparseable enum raw value from a newer (or corrupted) peer is
    /// rejected rather than written through.
    func testApplyRejectsAnUnknownLayoutModeRawValue() {
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey

        SyncableSettings.apply(
            fromMap([layoutKey: stringValue("hyperspace", at: 1)]),
            to: defaults
        )

        XCTAssertNil(defaults.object(forKey: layoutKey))
    }

    // MARK: - applied-keys notification

    /// Writing the preference domain is not the same as applying the preference: the two theme
    /// keys are cached in memory by `ThemeManager`, which re-reads them on this notification.
    /// So `apply` has to announce exactly the keys that landed.
    func testApplyAnnouncesTheKeysThatLanded() {
        let expectation = XCTNSNotificationExpectation(name: .phiSyncedSettingsDidApply)
        var announced: [String]?
        expectation.handler = { notification in
            announced = notification.userInfo?[SyncableSettings.appliedKeysUserInfoKey] as? [String]
            return true
        }

        SyncableSettings.apply(fromMap([probeKey: boolValue(true, at: 42)]),
                               to: defaults, settings: probeRegistry)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(announced, [probeKey])
    }

    /// A refused write leaves the local value standing, so there is nothing for an observer to
    /// re-read and nothing is announced.
    func testApplyAnnouncesNothingWhenNoKeyLanded() {
        let expectation = XCTNSNotificationExpectation(name: .phiSyncedSettingsDidApply)
        expectation.isInverted = true

        SyncableSettings.apply(fromMap([probeKey: stringValue("not a bool", at: 42)]),
                               to: defaults, settings: probeRegistry)

        wait(for: [expectation], timeout: 0.2)
    }

    // MARK: - round trip

    /// snapshot → merge → apply is the loop the engine runs; the newer remote
    /// value must land locally and then stay put.
    func testSnapshotMergeApplyRoundTrip() {
        let local = SyncableSettings.snapshot(defaults, now: 100, settings: probeRegistry)
        let remote = fromMap([probeKey: boolValue(true, at: 200)])

        let merged = SyncableSettings.merge(local: local, remote: remote)
        SyncableSettings.apply(merged, to: defaults, settings: probeRegistry)

        XCTAssertTrue(defaults.bool(forKey: probeKey))
        let next = SyncableSettings.snapshot(defaults, now: 300, settings: probeRegistry)
        XCTAssertEqual(next.values[probeKey]?.updatedAtMs, 200)
        XCTAssertEqual(SyncableSettings.merge(local: next, remote: merged), merged)
    }

    // MARK: - pinned-tab scope mirror (M3-3 §7.1)

    /// CASE 8.1: the mirror key is an ordinary synced setting and round-trips.
    /// Argument order is (value, defaults), with a generated protobuf value using
    /// stringValue/OneOf_V.stringValue, not a handwritten enum. Reversed or custom
    /// forms do not compile; this test fixes the contract.
    func testPinnedTabScopeSettingRoundTripsAndIsRegistered() {
        let setting = PinnedTabScopeMirror.pinnedTabScope

        setting.write(stringValue("space", at: 42), defaults)

        XCTAssertEqual(setting.read(defaults)?.stringValue, "space")
        XCTAssertEqual(setting.key, "PhiPinnedTabScope")
        XCTAssertTrue(SyncableSettings.all.contains { $0.key == "PhiPinnedTabScope" },
                      "the mirror key has to be in the registry the engine walks")
    }

    /// CASE 8.2 — a scope this build does not know is dropped silently, and the drop leaves
    /// both sidecars standing so the local value is re-pushed instead of being marked synced.
    func testPinnedTabScopeSettingDropsAnUnknownScopeAndLeavesTheSidecarsAlone() {
        let setting = PinnedTabScopeMirror.pinnedTabScope
        let registry = [setting]
        SyncableSettings.apply(fromMap([setting.key: stringValue("space", at: 10)]),
                               to: defaults, settings: registry)
        let timestampBefore = sidecarTimestamp(setting.key)
        let valueBefore = defaults.data(forKey: SyncableSettings.valueKey(for: setting.key))

        SyncableSettings.apply(fromMap([setting.key: stringValue("galaxy", at: 20)]),
                               to: defaults, settings: registry)

        XCTAssertEqual(setting.read(defaults)?.stringValue, "space")
        XCTAssertEqual(timestampBefore, 10)
        XCTAssertEqual(sidecarTimestamp(setting.key), timestampBefore)
        XCTAssertEqual(defaults.data(forKey: SyncableSettings.valueKey(for: setting.key)),
                       valueBefore)
    }

    /// CASE 8.3 — reseed, case one: the mirror key is missing, so it is written from the row
    /// together with both sidecars. Writing the sidecars is what makes the seed "already
    /// reconciled" rather than a fresh local edit the next snapshot would stamp with `now`.
    func testReseedSeedsTheMissingMirrorKeyTogetherWithBothSidecars() {
        let key = PinnedTabScopeMirror.pinnedTabScope.key

        let outcome = PinnedTabScopeMirror.reseed(rowValue: .space, into: defaults)

        XCTAssertEqual(outcome, .seeded)
        XCTAssertEqual(defaults.string(forKey: key), "space")
        XCTAssertNotNil(defaults.object(forKey: SyncableSettings.timestampKey(for: key)),
                        "the timestamp sidecar has to be written, not cleared")
        XCTAssertNotNil(defaults.data(forKey: SyncableSettings.valueKey(for: key)),
                        "the value sidecar has to be written, not cleared")
        let entity = SyncableSettings.snapshot(defaults, now: 999,
                                               settings: [PinnedTabScopeMirror.pinnedTabScope])
        XCTAssertNotEqual(entity.values[key]?.updatedAtMs, 999,
                          "a seed must not be read back as a local edit stamped with now")
    }

    /// CASE 8.4 — reseed, case two: the key disagrees with the row. The account's value is
    /// authoritative, so the key is left alone and the caller is told to re-run the local
    /// migration towards the MIRROR value, not the row's.
    func testReseedKeepsTheMirrorKeyAndAsksForAMigrationWhenItDisagreesWithTheRow() {
        let key = PinnedTabScopeMirror.pinnedTabScope.key
        defaults.set("profile", forKey: key)
        defaults.set(NSNumber(value: Int64(42)), forKey: SyncableSettings.timestampKey(for: key))

        let outcome = PinnedTabScopeMirror.reseed(rowValue: .space, into: defaults)

        XCTAssertEqual(outcome, .runLocalMigration(to: .profile))
        XCTAssertEqual(defaults.string(forKey: key), "profile")
        XCTAssertEqual(sidecarTimestamp(key), 42)
    }

    /// CASE 8.5 — reseed, case three: key and row agree, so nothing is written at all and the
    /// sidecars keep the values they had. Clearing them would let a machine that has been
    /// offline for two weeks publish this key stamped `now` and roll the account-level scope
    /// back, dragging every device through a full pin migration.
    func testReseedWritesNothingWhenTheMirrorKeyAlreadyMatchesTheRow() {
        let key = PinnedTabScopeMirror.pinnedTabScope.key
        let markerValue = Data([0xAB, 0xCD])
        defaults.set("space", forKey: key)
        defaults.set(NSNumber(value: Int64(7)), forKey: SyncableSettings.timestampKey(for: key))
        defaults.set(markerValue, forKey: SyncableSettings.valueKey(for: key))

        let outcome = PinnedTabScopeMirror.reseed(rowValue: .space, into: defaults)

        XCTAssertEqual(outcome, .noop)
        XCTAssertEqual(defaults.string(forKey: key), "space")
        XCTAssertEqual(sidecarTimestamp(key), 7)
        XCTAssertEqual(defaults.data(forKey: SyncableSettings.valueKey(for: key)), markerValue)
    }

    /// CASE 8.7 — the local row could not be read, so nothing is written at all.
    ///
    /// `LocalStore.pinnedTabScope()` answers `.profile` whenever the store never opened, and
    /// that failure default must not reach the mirror: on an account that has never published
    /// a scope it would become the account-level value and drag every device through a full
    /// pin migration.
    func testReseedWritesNothingWhenTheRowCannotBeRead() {
        let key = PinnedTabScopeMirror.pinnedTabScope.key

        let outcome = PinnedTabScopeMirror.reseed(rowValue: nil, into: defaults)

        XCTAssertEqual(outcome, .rowUnavailable)
        XCTAssertNil(defaults.string(forKey: key), "an unreadable row must not seed the key")
        XCTAssertNil(defaults.object(forKey: SyncableSettings.timestampKey(for: key)))
        XCTAssertNil(defaults.data(forKey: SyncableSettings.valueKey(for: key)))
    }

    /// CASE 8.8 — an unreadable row does not drive a migration either, even when the mirror
    /// key holds a different scope. There is no row to migrate, and the next mount replays.
    func testReseedAsksForNoMigrationWhenTheRowCannotBeRead() {
        let key = PinnedTabScopeMirror.pinnedTabScope.key
        let markerValue = Data([0xAB, 0xCD])
        defaults.set("profile", forKey: key)
        defaults.set(NSNumber(value: Int64(7)), forKey: SyncableSettings.timestampKey(for: key))
        defaults.set(markerValue, forKey: SyncableSettings.valueKey(for: key))

        let outcome = PinnedTabScopeMirror.reseed(rowValue: nil, into: defaults)

        XCTAssertEqual(outcome, .rowUnavailable)
        XCTAssertEqual(defaults.string(forKey: key), "profile")
        XCTAssertEqual(sidecarTimestamp(key), 7)
        XCTAssertEqual(defaults.data(forKey: SyncableSettings.valueKey(for: key)), markerValue)
    }
}

// MARK: - valueSignature: Deduplication for debounced push triggers

/// The `UserDefaults.didChangeNotification` subscription in `PhiChromiumCoordinator` cannot
/// see WHICH key changed, and the sync engine writes the very same domain on every round
/// (`phi.sync.marker` / `phi.sync.version` through `writeState`, plus the `<key>.phiSync*`
/// sidecars). `valueSignature` is what keeps the engine's own bookkeeping from re-arming a
/// push: it walks the registry and reads values, so nothing outside the registered
/// preferences can move it.
extension SyncableSettingsTests {

    /// The engine's own state keys move nothing. Without this the owned-item CONFLICT retry's
    /// in-round pull re-enters the push 2 s later, which is the 2.5 s commit loop seen on
    /// Mac B on 2026-09-14.
    func testTheEngineOwnStateKeysDoNotMoveTheValueSignature() {
        defaults.set(true, forKey: probeKey)
        let before = SyncableSettings.valueSignature(defaults, settings: probeRegistry)

        defaults.set(Data("marker-2".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set(NSNumber(value: Int64(42)), forKey: PhiSyncEngine.versionStateKey)
        defaults.set("srv-1", forKey: PhiSyncEngine.entityIdStateKey)

        XCTAssertEqual(SyncableSettings.valueSignature(defaults, settings: probeRegistry), before)
    }

    /// Neither do the sidecars `snapshot` stamps next to each registered key — they are the
    /// engine's change-detection memory, not the preference.
    func testTheSyncSidecarsDoNotMoveTheValueSignature() {
        defaults.set(true, forKey: probeKey)
        let before = SyncableSettings.valueSignature(defaults, settings: probeRegistry)

        defaults.set(NSNumber(value: Int64(9_000)),
                     forKey: SyncableSettings.timestampKey(for: probeKey))
        defaults.set(Data([0x01]), forKey: SyncableSettings.valueKey(for: probeKey))

        XCTAssertEqual(SyncableSettings.valueSignature(defaults, settings: probeRegistry), before)
    }

    /// A real edit to a registered preference does move it — the other half of the contract,
    /// without which the filter would simply switch the push trigger off.
    func testARegisteredPreferenceEditMovesTheValueSignature() {
        defaults.set(false, forKey: probeKey)
        let before = SyncableSettings.valueSignature(defaults, settings: probeRegistry)

        defaults.set(true, forKey: probeKey)

        XCTAssertNotEqual(SyncableSettings.valueSignature(defaults, settings: probeRegistry),
                          before)
    }

    /// Reading it stamps nothing: it rides on a notification, and a signature that wrote
    /// sidecars would itself post one.
    func testReadingTheValueSignatureWritesNothing() {
        defaults.set(true, forKey: probeKey)

        _ = SyncableSettings.valueSignature(defaults, settings: probeRegistry)

        XCTAssertNil(sidecarTimestamp(probeKey))
        XCTAssertNil(defaults.data(forKey: SyncableSettings.valueKey(for: probeKey)))
    }
}
