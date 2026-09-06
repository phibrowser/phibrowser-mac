import Foundation

/// One synced preference.
///
/// `key` IS the `UserDefaults` raw key, 1:1 — there is no separate sync
/// namespace. The same string is the map key inside `Phi_PhiSettingEntity`, so
/// what the server stores (encrypted) mirrors the local preference domain.
///
/// Both closures take the `UserDefaults` they operate on rather than reaching
/// for `.standard`, so the engine and the unit tests can inject a suite.
struct SyncableSetting {
    /// The `UserDefaults` key, which is also the entity map key.
    let key: String
    /// Resolves the current local value *through the preference's own
    /// default*, never branching on whether the key has ever been set: the app
    /// registers a registration-domain default for most of these keys, so
    /// `object(forKey:) != nil` means something different in the app than in a
    /// fresh test suite. The returned value carries no timestamp;
    /// `snapshot(_:now:settings:)` stamps it.
    let read: (UserDefaults) -> Phi_PhiSettingValue?
    /// Writes a merged value back to the local key. Must silently drop a value
    /// whose oneof case or contents do not fit the preference (a newer or
    /// corrupted peer); `apply` detects the drop and leaves the sidecars alone
    /// so the local value is re-pushed instead of being marked as synced.
    let write: (Phi_PhiSettingValue, UserDefaults) -> Void
}

/// The registry of syncable preferences plus the three operations the phi sync
/// engine drives: `snapshot` (local → entity, with change detection), `merge`
/// (field-level last-writer-wins) and `apply` (entity → local).
///
/// Field-level LWW timestamps live inside the payload, which is encrypted with
/// the account's PhiBrowser domain key before it ever leaves the device — the
/// server sees neither the keys nor the values.
///
/// Local timestamps are kept in two sidecar entries stored next to each
/// registered key in the *same* `UserDefaults`:
///
/// - `<key>.phiSyncTs`  — `Int64` epoch milliseconds of the last local change.
/// - `<key>.phiSyncVal` — the last synced value, serialized with its timestamp
///   zeroed, so a snapshot can tell a real local edit from an unchanged key.
///
/// Nothing else in the app stamps these: `snapshot` is the sole local
/// change-detection point, and `apply` mirrors them so a freshly applied remote
/// value is not mistaken for a local edit and bounced back.
enum SyncableSettings {

    // MARK: - Sidecars

    /// Suffix of the per-key local-change timestamp entry (`Int64` ms).
    static let timestampSuffix = ".phiSyncTs"
    /// Suffix of the per-key last-synced value entry (serialized value bytes).
    static let valueSuffix = ".phiSyncVal"

    static func timestampKey(for key: String) -> String { key + timestampSuffix }
    static func valueKey(for key: String) -> String { key + valueSuffix }

    /// The comparable identity of a value: its bytes with `updatedAtMs` zeroed,
    /// so "did this change locally?" is answered on the value alone.
    private static func signature(of value: Phi_PhiSettingValue) -> Data {
        var stripped = value
        stripped.updatedAtMs = 0
        return (try? stripped.serializedData()) ?? Data()
    }

    private static func storedTimestamp(_ defaults: UserDefaults, _ key: String) -> Int64? {
        (defaults.object(forKey: timestampKey(for: key)) as? NSNumber)?.int64Value
    }

    // MARK: - Registry

    /// The M3-1 starter set: the cross-device Theme / layout / General
    /// preferences that are Bool, String or Int.
    ///
    /// Deliberately excluded:
    /// - `ThemeSettings.themeSnapshots` (`PhiThemeSnapshots`) holds archived
    ///   `Data`, and `Phi_PhiSettingValue`'s oneof has no bytes case. Out of
    ///   scope until the proto gains one.
    /// - `GeneralSettings.spacesFeatureEnabled` and everything under
    ///   `AgentSpaces` / `AISettings` are feature gates or device-local, not
    ///   user preferences to propagate.
    /// - `GeneralSettings.navigationAtTop` / `.traditionalLayout` are the
    ///   superseded dual-bool encoding of `layoutMode`; syncing both encodings
    ///   would let them disagree. They are still *read* as `layoutMode`'s
    ///   fallback, exactly as `loadLayoutMode()` does.
    static let all: [SyncableSetting] = generalBools + [layoutMode, autoPictureInPictureMode] + themeSettings

    // MARK: General (Bool)

    private static let generalBoolCases: [PhiPreferences.GeneralSettings] = [
        .openNewTabPageOnCmdT,
        .alwaysShowURLPath,
        .alwaysShowBookmarkBar,
        .showBookmarkBarOnNewTabPage,
        .suppressCloseIncognitoSpaceWarning,
    ]

    private static let generalBools: [SyncableSetting] = generalBoolCases.map { setting in
        boolSetting(key: setting.rawValue, default: setting.defaultValue)
    }

    private static func boolSetting(key: String, default defaultValue: Bool) -> SyncableSetting {
        SyncableSetting(
            key: key,
            read: { defaults in
                var value = Phi_PhiSettingValue()
                value.boolValue = defaults.bool(forKey: key, default: defaultValue)
                return value
            },
            write: { value, defaults in
                guard case .boolValue(let flag) = value.v else { return }
                defaults.set(flag, forKey: key)
            }
        )
    }

    // MARK: Layout (String)

    /// Mirrors `GeneralSettings.loadLayoutMode()`, which is the single source
    /// of truth for the layout the window actually uses: the explicit
    /// `layoutMode` key first, then the superseded dual-bool encoding.
    ///
    /// The fallback is expressed through `traditionalLayout` /
    /// `navigationAtTop`'s **own** `defaultValue`s (via
    /// `UserDefaults.bool(forKey:default:)`), never through key presence, so a
    /// fresh `UserDefaults(suiteName:)` and the app's registration domain agree
    /// — `navigationAtTop` defaults to `true`, so a device whose user never
    /// opened the layout picker is on `.balanced`, and that is what it must
    /// push. Reading only the explicit key would emit `.performance` for every
    /// such device and, once committed, apply it back over the user's (and
    /// every peer's) real layout.
    ///
    /// `write` sets only the explicit key: `loadLayoutMode()` prefers it, so
    /// the stale legacy bools are unreachable afterwards.
    private static let layoutMode = SyncableSetting(
        key: PhiPreferences.GeneralSettings.layoutModeKey,
        read: { defaults in
            let raw = defaults.string(forKey: PhiPreferences.GeneralSettings.layoutModeKey) ?? ""
            let mode: LayoutMode
            if let explicit = LayoutMode(rawValue: raw) {
                mode = explicit
            } else if defaults.bool(
                forKey: PhiPreferences.GeneralSettings.traditionalLayout.rawValue,
                default: PhiPreferences.GeneralSettings.traditionalLayout.defaultValue
            ) {
                mode = .comfortable
            } else if defaults.bool(
                forKey: PhiPreferences.GeneralSettings.navigationAtTop.rawValue,
                default: PhiPreferences.GeneralSettings.navigationAtTop.defaultValue
            ) {
                mode = .balanced
            } else {
                mode = .performance
            }
            var value = Phi_PhiSettingValue()
            value.stringValue = mode.rawValue
            return value
        },
        write: { value, defaults in
            guard case .stringValue(let raw) = value.v, LayoutMode(rawValue: raw) != nil else { return }
            defaults.set(raw, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
    )

    /// The one preference pair whose existing accessors already thread an
    /// injected `UserDefaults`, so they are reused verbatim.
    private static let autoPictureInPictureMode = SyncableSetting(
        key: PhiPreferences.GeneralSettings.autoPictureInPictureModeKey,
        read: { defaults in
            var value = Phi_PhiSettingValue()
            value.stringValue = PhiPreferences.GeneralSettings
                .loadAutoPictureInPictureMode(from: defaults).rawValue
            return value
        },
        write: { value, defaults in
            guard case .stringValue(let raw) = value.v,
                  let mode = AutoPictureInPictureMode(rawValue: raw) else { return }
            PhiPreferences.GeneralSettings.saveAutoPictureInPictureMode(mode, to: defaults)
        }
    )

    // MARK: Theme

    private static let themeSettings: [SyncableSetting] = [
        // 0 = system, 1 = light, 2 = dark.
        SyncableSetting(
            key: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue,
            read: { defaults in
                var value = Phi_PhiSettingValue()
                value.intValue = Int64(defaults.integer(
                    forKey: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue
                ))
                return value
            },
            write: { value, defaults in
                guard case .intValue(let choice) = value.v, (0...2).contains(choice) else { return }
                defaults.set(Int(choice), forKey: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue)
            }
        ),
        SyncableSetting(
            key: PhiPreferences.ThemeSettings.currentThemeId.rawValue,
            read: { defaults in
                var value = Phi_PhiSettingValue()
                value.stringValue = defaults.string(
                    forKey: PhiPreferences.ThemeSettings.currentThemeId.rawValue
                ) ?? "default"
                return value
            },
            write: { value, defaults in
                guard case .stringValue(let themeId) = value.v, !themeId.isEmpty else { return }
                defaults.set(themeId, forKey: PhiPreferences.ThemeSettings.currentThemeId.rawValue)
            }
        ),
        boolSetting(key: PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue, default: true),
    ]

    // MARK: - Snapshot

    /// Reads the registered preferences into an entity, detecting local changes
    /// on the way.
    ///
    /// For each registered key: if the current value differs from
    /// `<key>.phiSyncVal` (or no sidecar exists yet) the key is treated as
    /// locally changed — `<key>.phiSyncTs` becomes `now` and `<key>.phiSyncVal`
    /// is refreshed. Otherwise the stored timestamp is reused, so an untouched
    /// key does not keep winning last-writer-wins against a remote edit.
    ///
    /// - Parameters:
    ///   - defaults: the preference domain to read (and stamp sidecars in).
    ///   - now: epoch milliseconds to stamp on keys detected as locally changed.
    ///   - settings: the registry to walk; defaults to ``all``.
    static func snapshot(
        _ defaults: UserDefaults,
        now: Int64,
        settings: [SyncableSetting] = SyncableSettings.all
    ) -> Phi_PhiSettingEntity {
        var entity = Phi_PhiSettingEntity()
        for setting in settings {
            guard var value = setting.read(defaults) else { continue }
            let current = signature(of: value)
            let timestamp: Int64
            if defaults.data(forKey: valueKey(for: setting.key)) == current,
               let stored = storedTimestamp(defaults, setting.key) {
                timestamp = stored
            } else {
                timestamp = now
                defaults.set(NSNumber(value: now), forKey: timestampKey(for: setting.key))
                defaults.set(current, forKey: valueKey(for: setting.key))
            }
            value.updatedAtMs = timestamp
            entity.values[setting.key] = value
        }
        return entity
    }

    // MARK: - Merge

    /// Field-level last-writer-wins over the union of both sides' keys.
    ///
    /// Per key the larger `updatedAtMs` wins; on an exact tie the value whose
    /// serialized bytes are lexicographically greater wins. That rule depends
    /// only on the two values, never on which side they arrived from, so two
    /// devices merging the same pair converge on the same result.
    ///
    /// Keys absent from the registry are carried through untouched (forward
    /// compatibility with a newer client); ``apply(_:to:settings:)`` is what
    /// refuses to write them locally.
    static func merge(
        local: Phi_PhiSettingEntity,
        remote: Phi_PhiSettingEntity
    ) -> Phi_PhiSettingEntity {
        var merged = local
        for (key, remoteValue) in remote.values {
            guard let localValue = merged.values[key] else {
                merged.values[key] = remoteValue
                continue
            }
            merged.values[key] = winner(localValue, remoteValue)
        }
        return merged
    }

    private static func winner(
        _ lhs: Phi_PhiSettingValue,
        _ rhs: Phi_PhiSettingValue
    ) -> Phi_PhiSettingValue {
        if lhs.updatedAtMs != rhs.updatedAtMs {
            return lhs.updatedAtMs > rhs.updatedAtMs ? lhs : rhs
        }
        // `merge` is non-throwing; a value that cannot serialize degrades to
        // empty bytes rather than propagating.
        let lhsBytes = (try? lhs.serializedData()) ?? Data()
        let rhsBytes = (try? rhs.serializedData()) ?? Data()
        return lhsBytes.lexicographicallyPrecedes(rhsBytes) ? rhs : lhs
    }

    // MARK: - Apply

    /// Writes the merged entity back to local preferences.
    ///
    /// Only keys present in `settings` are written — an unknown key from a
    /// newer client is never blind-written into `UserDefaults`. Each key that
    /// lands also refreshes its sidecars (`<key>.phiSyncTs` = the value's own
    /// `updatedAtMs`, `<key>.phiSyncVal` = the value), so the next snapshot
    /// does not read the applied value back as a local edit and echo it.
    ///
    /// If a write is refused (a type-mismatched or unparseable value), the
    /// sidecars are left untouched so the local value is re-pushed instead.
    static func apply(
        _ entity: Phi_PhiSettingEntity,
        to defaults: UserDefaults,
        settings: [SyncableSetting] = SyncableSettings.all
    ) {
        for setting in settings {
            guard let value = entity.values[setting.key] else { continue }
            setting.write(value, defaults)
            let expected = signature(of: value)
            guard let stored = setting.read(defaults), signature(of: stored) == expected else { continue }
            defaults.set(NSNumber(value: value.updatedAtMs), forKey: timestampKey(for: setting.key))
            defaults.set(expected, forKey: valueKey(for: setting.key))
        }
    }
}
