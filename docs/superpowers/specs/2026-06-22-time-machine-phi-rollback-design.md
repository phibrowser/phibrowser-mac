# Phi Time Machine Rollback Design

## Context

Phi 2.0 will introduce larger profile and spec changes. Users who upgrade from a
known 1.x build to the risky 2.0 build need a local rollback point that can
restore Phi's local data and reinstall the matching 1.x app package.

This design covers the Phi side only. Sentinel data is intentionally out of
scope for the first implementation. Time Machine restores Phi data by replacing
the selected file-system scope as a whole, including LocalStore files. Phi's
existing LocalStore compatibility logic remains available as its own startup
schema preflight, but it is not the Time Machine restore path.

## Goals

- Create a completed backup only when the running build exactly matches a
  configured trigger build.
- Bind each backup to the exact rollback app package URL and SHA-256 that should
  be used to restore it.
- Back up Phi and Chromium data by default, with a code-level feature flag that
  can switch the data scope to Phi-only.
- Use APFS clone/copy-on-write first and fall back to regular copy.
- Let users view completed backups from the Help menu and choose one to restore.
- Restore by launching an embedded installer process so the running Phi app does
  not replace itself.
- Keep the first package verification simple: downloaded zip SHA-256 must match
  the backup manifest.

## Non-Goals

- Restore Sentinel data.
- Replace LocalStore compatibility behavior or call it from Time Machine.
- Support build ranges. The trigger is an exact build number.
- Support dmg rollback packages.
- Add codesign, notarization, or Sparkle signature validation in the first
  version.
- Add a privileged helper or administrator escalation.
- Guarantee recovery from power loss during every rename. The first version must
  have emergency backups and best-effort rollback, but not a transactional file
  system journal.

## Rollback Policy

The app loads a bundled policy from:

```text
Phi.app/Contents/Resources/TimeMachineRollbackPolicy.json
```

The policy is intentionally exact-build based:

```swift
struct TimeMachineRollbackPolicy: Codable, Equatable {
    let backupTriggerBuild: Int
    let rollbackVersion: String
    let rollbackBuild: Int
    let rollbackPackageURL: URL
    let rollbackPackageSHA256: String
    let includeChromiumData: Bool
    let rollbackAppBundleName: String?
}
```

Example:

```json
{
  "backupTriggerBuild": 600,
  "rollbackVersion": "1.6",
  "rollbackBuild": 590,
  "rollbackPackageURL": "https://example.com/Phi-1.6-590.zip",
  "rollbackPackageSHA256": "012345...",
  "includeChromiumData": true
}
```

Stable rollback packages can omit `rollbackAppBundleName`; the default is
`Phi.app`. Phi Canary and other channel packages must set it explicitly when the
zip contains a differently named top-level app bundle:

```json
{
  "backupTriggerBuild": 600,
  "rollbackVersion": "1.6",
  "rollbackBuild": 590,
  "rollbackPackageURL": "https://example.com/Phi-Canary-1.6-590.zip",
  "rollbackPackageSHA256": "012345...",
  "includeChromiumData": true,
  "rollbackAppBundleName": "Phi Canary.app"
}
```

`rollbackAppBundleName` must be a single top-level `.app` directory name. It
must not contain path separators.

The backup trigger condition is:

```text
current CFBundleVersion == backupTriggerBuild
and no completed backup already exists for backupTriggerBuild
```

`backupTriggerBuild` is not a lower bound. Build 601 does not create a backup
from a build-600 policy unless its own policy says `backupTriggerBuild = 601`.
Failed attempts are not cataloged as completed backups, so the same exact build
can retry snapshot creation on the next launch.

## Backup Timing

Full Chromium backup requires the restore point to be created before Chromium
starts and mutates the profile. Today `Sources/Other/main.m` creates
`ChromiumLauncher` and calls `launchChromiumWithArgc` before AppController's
launch callbacks. Therefore Time Machine needs a small pre-Chromium bootstrap
hook in `main.m`:

```text
main.m
  install logging
  TimeMachineBootstrap.recoverPendingRestoreIfNeeded()
  TimeMachineBootstrap.prepareBackupIfNeeded()
  ChromiumLauncher.sharedInstance()
  launchChromiumWithArgc(...)
```

The bootstrap should be synchronous. It should only read the policy, inspect the
catalog, and create the local restore point. It must not download rollback
packages during launch.

The recovery gate must run before backup creation and before Chromium launch. If
an incomplete restore operation exists, Phi must either resume the installer or
revert the operation before Chromium can open and mutate the profile.

If a future 2.0 migration is destructive or non-downgradeable, that migration
must check the bootstrap result before running. The migration should not proceed
when the required exact-build backup failed.

## Storage Layout

Time Machine stores its own data outside the Phi application-support directory
so full-data snapshots do not recursively include restore points:

```text
~/Library/Application Support/com.phibrowser.TimeMachine/
  <bundle-id>/
    catalog.json
    Snapshots/
      <snapshot-id>/
        manifest.json
        ApplicationSupport/
          <bundle-id>/
        Preferences/
          <bundle-id>.plist
    Pending/
      <operation-id>/
        install-plan.json
        package.zip
        Package/
          <rollbackAppBundleName>
        result.json
    Emergency/
      <operation-id>/
        App/
        Data/
```

Stable Phi uses `com.phibrowser.Mac` as the bucket. Phi Canary uses
`com.phibrowser.canary.Mac`, so stable and nightly backups do not appear in each
other's restore menus. The Time Machine root should be created with user-only
permissions where possible.

## Completed Backup Catalog

`catalog.json` is the menu and deduplication source of truth. Only completed
snapshots appear in the catalog.

```swift
struct TimeMachineCatalog: Codable, Equatable {
    var backups: [TimeMachineBackupRecord]
}

struct TimeMachineBackupRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let creatingVersion: String
    let creatingBuild: Int
    let backupTriggerBuild: Int
    let rollbackVersion: String
    let rollbackBuild: Int
    let rollbackPackageURL: URL
    let rollbackPackageSHA256: String
    let includeChromiumData: Bool
    let snapshotRelativePath: String
    let status: Status
    let rollbackAppBundleName: String?

    enum Status: String, Codable {
        case completed
    }
}
```

`creatingVersion` and `creatingBuild` describe the app that created the
snapshot, such as build 600. `rollbackVersion` and `rollbackBuild` describe the
older app that should be installed when restoring that snapshot, such as build
590. The restore menu uses the rollback target fields.

Menu labels should be derived from completed records, for example:

```text
Time Machine Backups
  Phi 1.6 build 590 on 2026.6.11
```

The label describes the rollback target, not the current app build that created
the backup.

## Backup Scope

When `includeChromiumData = true`, the snapshot includes the entire Phi
application-support directory:

```text
~/Library/Application Support/com.phibrowser.Mac
```

This includes both:

- Phi-owned data under `Phi/`
- Chromium profile data such as `Default`, `Local State`, and related browser
  storage

When `includeChromiumData = false`, the snapshot includes only:

```text
~/Library/Application Support/com.phibrowser.Mac/Phi
```

In both modes the snapshot also includes:

```text
~/Library/Preferences/com.phibrowser.Mac.plist
```

LocalStore files are copied and restored as part of the selected file-system
scope. Time Machine does not create or consume LocalStore schema backups
directly, and restore does not special-case individual LocalStore SQLite files.

## Snapshot Copy Engine

The copy engine should be shared by backup and restore staging:

- Directories are created normally.
- Regular files use `clonefile(2)` first.
- Unsupported clone cases fall back to `FileManager.copyItem`.
- Symlinks should be copied as symlinks, not followed.
- Extended attributes and file permissions should be preserved when using the
  fallback copy path.

The first implementation can fail on special files that are not expected in the
Phi data tree. Any skipped or failed item must be recorded in logs and cause the
snapshot to fail rather than silently producing a partial completed backup.

## Restore Menu

The existing Help menu already has a managed user-data section. Time Machine
should add a separate submenu under Help:

```text
Help
  Time Machine Backups
    Phi 1.6 build 590 on 2026.6.11
```

The submenu is populated from `catalog.json`. If there are no completed backups,
the submenu can contain a disabled item:

```text
No Backups Available
```

Selecting a completed backup shows a confirmation dialog that includes:

- Rollback target version and build
- Backup creation date
- Whether Chromium data will be restored
- A warning that Phi will quit and reopen

After confirmation, Phi downloads and verifies the package, writes an install
plan, launches the installer helper, and terminates.

## Package Download and Verification

The selected backup record determines the rollback package URL and expected
SHA-256. The current policy is not consulted during restore because each backup
must remain bound to the rollback package it was created for.

The package format is:

```text
Phi-<version>-<build>.zip
  Phi.app/
```

For Phi Canary, the top-level app name follows `rollbackAppBundleName`:

```text
Phi-Canary-<version>-<build>.zip
  Phi Canary.app/
```

The first implementation verifies only:

- The downloaded zip SHA-256 equals `rollbackPackageSHA256`.
- The expanded package contains a top-level app named by
  `rollbackAppBundleName`, or `Phi.app` when that field is omitted.
- The staged app's bundle identifier matches the current channel.
- The staged app's `CFBundleVersion` matches `rollbackBuild`.

Download code in the main app should live under `Sources/Networking`, either as
a narrow `APIClient` method or a small networking-layer downloader, instead of
adding unrelated direct networking abstractions in UI or Time Machine code.

## Installer Helper Shape

The installer should be an embedded command-line helper target:

```text
Phi.app/Contents/Helpers/PhiTimeMachineInstaller
```

It is not an XPC service and not a privileged helper. It is launched by the main
app with:

```text
PhiTimeMachineInstaller --plan <install-plan.json>
```

Before launch, Phi copies the helper binary into the pending operation directory:

```text
~/Library/Application Support/com.phibrowser.TimeMachine/<bundle-id>/Pending/<operation-id>/PhiTimeMachineInstaller
```

The copied helper is the process Phi launches. This keeps the helper alive after
Phi quits, avoids replacing the running app from inside its own process, and
prevents the helper from depending on the app bundle it is about to replace.

## Install Plan

The main app writes an install plan under `Pending/<operation-id>/`:

```swift
struct TimeMachineInstallPlan: Codable, Equatable {
    let operationID: UUID
    let hostPID: Int32
    let bundleIdentifier: String
    let currentAppURL: URL
    let stagedAppURL: URL
    let currentApplicationSupportURL: URL
    let snapshotApplicationSupportURL: URL?
    let currentPhiDataURL: URL
    let snapshotPhiDataURL: URL?
    let currentPreferencesURL: URL
    let snapshotPreferencesURL: URL?
    let emergencyBackupURL: URL
    let includeChromiumData: Bool
    let rollbackVersion: String
    let rollbackBuild: Int
    let packageSHA256: String
}
```

Only one of the application-support snapshot or Phi-data snapshot paths is used
for a given plan, based on `includeChromiumData`.

## Installer Helper Flow

The helper performs these steps:

1. Decode and validate the install plan.
2. Wait for `hostPID` to exit.
3. Terminate matching Phi Sentinel login items as best effort.
4. Create the emergency backup directory.
5. Clone/copy the selected snapshot data into restore staging.
6. Move the current data scope and preferences to emergency backup locations if
   they exist. In full mode this means the entire application-support
   directory. In Phi-only mode this means only the `Phi/` child directory, so
   Chromium data remains in place.
7. Move the staged data into the final user-data paths.
8. Move the current app into `Emergency/<operation-id>/App/`.
9. Move the staged rollback app into the final app path.
10. Open the restored app with `/usr/bin/open -n`.
11. Write `result.json`.

The helper must not perform network requests.

## Restore Transaction / Crash Recovery

Restore must be treated as a resumable transaction. The system cannot guarantee
survival from disk corruption or every possible power-loss point, but it must
avoid leaving live Phi data in a partially copied state. After any crash, the
machine should be in one of these states:

- Old app and old data are still live.
- Restored app and restored data are live.
- A pending restore operation exists and must be resumed or reverted before
  Chromium starts.

The transaction has three required safety mechanisms.

### Staging

The helper must never copy directly over live paths. Package expansion,
restored data, restored preferences, and the copied helper all live under
`Pending/<operation-id>/` until they are complete. The helper stages restored
data into same-parent paths such as:

```text
~/Library/Application Support/com.phibrowser.Mac.restoring-<operation-id>
```

Only after staging succeeds may the helper swap or move staged data into the
final live path.

### Journal

The helper writes an operation journal after each phase using atomic file
replacement. Suggested phases:

```text
prepared
dataStaged
dataBackedUp
dataSwapStarted
dataSwapped
appBackedUp
appSwapStarted
appSwapped
completed
failed
reverted
```

The journal must be sufficient for the next launch to decide whether the helper
can resume forward or should revert from emergency backups.

### Startup Recovery Gate

`main.m` must check pending operations before Chromium starts. If the journal is
not `completed`, `failed`, or `reverted`, the app must not continue normal
startup. It should launch the copied pending helper in recovery mode and exit,
or revert the operation itself if the helper is missing and the journal contains
enough emergency-backup paths.

This gate is what prevents the most dangerous failure mode: restored data has
been partially swapped, the machine loses power, and then Chromium launches and
writes into an unknown mixed-version profile.

The app swap happens after the data swap. If power is lost before the app swap,
the next run is still the newer Phi build, which has the startup recovery gate.
If power is lost after the app swap, the restored app should already have the
matching restored data.

Before replacing each live path, the helper creates an emergency backup for that
scope. If a later step fails, it attempts to move those emergency backups back
into place and records `reverted` or `failed` in the journal.

Emergency backups should be retained after a successful first implementation.
Automatic cleanup can be added after the restore path has proven reliable.

If the current app bundle or its containing directory is not writable by the
current user, the main app should fail before launching the helper and explain
that rollback cannot proceed automatically.

## Components

- `TimeMachineRollbackPolicyLoader`
  - Loads and validates the bundled policy.
- `TimeMachineCatalogStore`
  - Reads and writes `catalog.json`.
- `TimeMachineSnapshotManager`
  - Creates completed restore points and records them in the catalog.
- `TimeMachineFileCloner`
  - Implements clone-first recursive copy.
- `TimeMachinePackageDownloader`
  - Downloads the selected backup's rollback zip and verifies SHA-256.
- `TimeMachineRestoreCoordinator`
  - Handles menu selection, confirmation, package preparation, plan creation,
    helper launch, and app termination.
- `TimeMachineRestoreJournal`
  - Persists pending-operation phases atomically and lets startup recovery decide
    whether to resume or revert.
- `TimeMachineStartupRecoveryGate`
  - Runs before Chromium launch and blocks normal startup while an incomplete
    restore operation exists.
- `PhiTimeMachineInstaller`
  - Command-line helper that applies the plan after Phi exits.

## Tests

Unit tests should cover:

- Exact-build trigger behavior.
- No duplicate completed backup for the same trigger build.
- Catalog load/save and menu label generation.
- Policy validation.
- SHA-256 verification.
- Install-plan encoding and validation.
- Clone-first copy fallback behavior with an injectable copy strategy.
- Restore planning for `includeChromiumData = true`.
- Restore planning for `includeChromiumData = false`.
- Journal phase transitions and recovery decisions.
- Startup recovery gate behavior before Chromium launch.

Integration-style tests can use temporary directories to exercise the helper's
move and emergency-restore behavior without touching `/Applications`.

## Open Follow-Ups

- Add stronger package validation, including codesign and Team ID checks.
- Decide whether failed backup attempts should block launch in all 2.0 builds
  or only before destructive migrations.
- Add retention policy for old snapshots and emergency backups.
- Extend the same Time Machine model to Sentinel storage if Sentinel 2.0 state
  also needs downgrade protection.
