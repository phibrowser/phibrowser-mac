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
}
