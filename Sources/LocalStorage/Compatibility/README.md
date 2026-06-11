# Local Store Compatibility

## Background

SwiftData and Core Data are designed around forward migration. They can help a
newer app open an older store, but they do not provide a general-purpose
downgrade path for an older app to open a store that has already been migrated
by a newer app.

Phi is not distributed exclusively through the App Store, so users can manually
replace the app with an older build. When that happens, the older app may see a
local SwiftData store whose schema was already changed by a newer build. The
safe behavior is:

- Open the active store when its format is known to be readable.
- Restore the newest readable backup when the active store is too new.
- Stop before creating the SwiftData `ModelContainer` when no readable backup
  exists, then ask the user to install a newer app.

This module implements that preflight layer before SwiftData/Core Data touches
the SQLite store.

## Design

The module stores a small JSON manifest next to the SQLite files:

- `activeStoreFormatVersion`: the format version of the active store files.
- `backups`: a catalog of backup directories and their store format versions.

The app declares its compatibility through `LocalStoreCompatibilityConfiguration`:

- `currentStoreFormatVersion`: the format the current app writes after opening.
- `readableStoreFormatVersions`: the store formats this app is allowed to open.
- `backupPolicy`: the rule that decides whether a backup should be made before
  opening the store.

There is intentionally no `minimumReadableStoreFormatVersion`. Schema changes
are explicit product decisions, so each app build should declare exactly which
store format range it can read.

## Opening Flow

`LocalStore` calls `LocalStoreCompatibilityController.prepareStore(at:)` before
creating the SwiftData `ModelContainer`.

The controller performs this flow:

1. Load the manifest, or create one for the current format on first run.
2. If the active store format is readable, optionally create a backup according
   to the configured `LocalStoreBackupPolicy`.
3. If the active store format is too new, restore the highest readable backup.
4. If no readable backup exists, return `.requiresNewerApp` and leave the active
   store untouched.
5. After SwiftData opens successfully, record the active store as the current
   format.

Backups copy the SQLite main file and its sidecar files:

- `LocalStore.sqlite`
- `LocalStore.sqlite-wal`
- `LocalStore.sqlite-shm`

Multiple backups can exist at the same time. For example, if v4 and v5 both
created backups, a v4 app can restore the v4 backup while a v3 app can restore
the v3 backup.

## Development Rules

When changing the local SwiftData/Core Data schema:

1. Increment `currentStoreFormatVersion` in `LocalStore.compatibilityConfiguration`.
2. Update `readableStoreFormatVersions` to match the formats the new app can
   safely open.
3. Decide whether the release must create a backup before opening an older
   store. Use `LocalStoreBackupPolicy.beforeSchemaUpgrade` for normal schema
   upgrades, or provide a custom policy when only specific transitions need a
   backup.
4. Add or update tests in `LocalStoreCompatibilityTests` for the upgrade and
   downgrade behavior.
5. Treat added, removed, renamed, or relationship-changing model fields as a
   store format change unless there is a verified reason not to.

Do not bypass this module by creating a `ModelContainer` directly for the local
store. The compatibility check must run before SwiftData/Core Data opens the
SQLite files.

Do not delete old backups as part of a schema change unless a separate retention
policy is intentionally designed and tested. Older app builds may still need a
lower-version backup to recover from a manual downgrade.

