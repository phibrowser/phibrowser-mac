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

1. Load the manifest, or create one when the manifest is missing. A clean first
   run uses the current format. An existing store without a manifest is treated
   as a legacy store for the current bundle build: build 585 and newer map to
   format v5, builds 494 through 584 map to format v3, and other builds use the
   current format so no compatibility backup is created.
2. If the active store format is readable, optionally create a backup according
   to the configured `LocalStoreBackupPolicy`.
3. If the active store format is too new, restore the highest readable backup.
4. If no readable backup exists, return `.requiresNewerApp` and leave the active
   store untouched.
5. After SwiftData opens successfully, record the active store as the current
   format. If this launch restored a backup, remove that consumed backup record
   and delete its backup directory.

Backups copy the SQLite main file and its sidecar files:

- `LocalStore.sqlite`
- `LocalStore.sqlite-wal`
- `LocalStore.sqlite-shm`

Multiple backups can exist at the same time. For example, if v4 and v5 both
created backups, a v4 app can restore the v4 backup while a v3 app can restore
the v3 backup.

A backup is skipped when an existing backup of the same format, taken before the
same upgrade, already holds the same bytes. Each record stores a SHA-256
`contentDigest` of `LocalStore.sqlite` and a non-empty `-wal`. Records written
before digests existed are hashed from their files. Without this, a store that
keeps failing to open never advances the manifest, so every launch or Guest
sign-in retry copied it again. With no store file there is nothing to back up,
so none is made.

## Unrecognised Stores

The manifest's format is not proof of the files' schema. A store older than
`TabDataModelSchemaV1`, left by 0.x installs, matches no schema in
`TabDataModelMigrationPlan`, so SwiftData cannot open it on any launch.

When the `ModelContainer` fails to open, `LocalStore` reads the store's Core
Data metadata and compares it with every schema in the plan. The store counts as
unrecognised only when the metadata is readable and matches none of them. In
that case `quarantineUnrecognisedStore(at:)`:

- moves the store files into a backup directory recorded with format 0 and
  `isQuarantinedUnrecognisedStore`. No app reads format 0, so it is never
  restored;
- removes earlier backups holding the same bytes, because they were labelled
  with a readable format the files never had;
- records the current format as active.

`LocalStore` then opens once more, which creates an empty store. Any other open
failure leaves the files in place and the store closed, sets
`compatibilityStatus` to `.failed`, and shows a "Phi Couldn't Open Local Browser
Data" alert once per store directory per launch. The decision is made from the
metadata, not from the SwiftData error, because macOS versions report this case
with different errors.

A restored backup is consumed only after SwiftData/Core Data opens the restored
store successfully. The selected backup remains available between `prepareStore`
and `markStoreOpenedSuccessfully` so a failed open does not delete the last
known readable recovery point.

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

The current store format is 14 (`TabDataModelSchemaV14`), which adds the
optional `TabDataModel.splitPaneGuids` and `splitExtraPanes` columns holding
pinned and bookmarked splits of three or four panes. Neither is backfilled.

The dev rebase preserves the released V10 schema (bookmark icons and split
layouts). V11 adds bookmark/pinned-tab sync columns; V12 adds URL rule and
Profile sync columns and backfills URL rule identities; V13 adds the bookmark
location edit date and backfills nothing; V14 adds the wider-split columns and
backfills nothing. Historical V10 is unchanged, and the
existing before-upgrade backup policy still applies.

This chain follows dev's schema history. Stores created by the pre-rebase sync
prototype have different V10/V11 model checksums and require separate migration
verification before reuse.
