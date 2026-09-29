# Time Machine backup and recovery

Phi's Time Machine feature creates policy-triggered local snapshots and can
restore data together with a matching application package. It is a native
application feature, distinct from macOS Time Machine. It does not imply that
every companion application's data is included.

## Policy and snapshot ownership

`TimeMachineRollbackPolicyLoader` supplies the policy. Its model records trigger
version/build, rollback package identity, SHA-256, optional bundle name and
whether Chromium data is included. The current trigger mode compares build
numbers for Canary and versions for other configurations; do not assume every
channel triggers by the exact build number.

`TimeMachineBootstrap` enters recovery and backup preparation before ordinary
browser startup. `TimeMachineSnapshotManager` stages the configured data and
records a completed backup only after the snapshot is ready. The catalog also
records suppressed triggers so a deliberately handled trigger is not recreated
on every launch.

Storage is channel-scoped beneath
`~/Library/Application Support/com.phibrowser.TimeMachine/<bundle-id>/`.
The paths model owns snapshots, pending operations, emergency data and journals.
Keep path derivation there rather than reconstructing paths in a menu or helper.

## Backup scope

`includeChromiumData` determines which channel-scoped Application Support data
is copied into a snapshot:

| Policy | Copied data |
| --- | --- |
| `true` | The entire channel Application Support directory, including `Phi/` native data and Chromium data such as `Default/` and `Local State` when present |
| `false` | Only its `Phi/` native-data directory; Chromium data is not included |

In both modes, the channel's preferences plist is copied separately when it
exists; its absence does not fail backup. The manifest records the actual
Application Support, `Phi/` and preferences paths copied, rather than implying
that a missing optional path exists. Native data under `Phi/` is captured by
the directory copy, not by a separate per-model export. This policy does not
include arbitrary companion-service or account data outside those paths.

## Restore transaction

Restore preparation belongs to `TimeMachineRestoreCoordinator`; package transport
belongs to `TimeMachinePackageDownloader`. Validate the selected package digest
and intended application identity before destructive installation. A download
URL or successful extraction alone does not establish package correctness.

The selected backup record supplies the rollback package URL, SHA-256, bundle
name and build. Do not substitute the current policy: it may have changed since
that backup was created. Verify the staged application's channel bundle ID and
build as well as the archive digest, so restored data stays paired with its
intended application.

The separate installer helper consumes a prepared operation and durable journal
after the app exits. Staging, data replacement, app replacement and recovery are
transaction phases, not independent UI actions. Preserve emergency/recovery data
until the journal authorizes cleanup. The startup recovery gate handles pending
operations before allowing ordinary startup to consume partially replaced data.

Data replacement must finish before app replacement. If interruption happens
before the app swap, the newer application still contains the startup recovery
gate and can prevent Chromium from opening partially restored data. The rollback
application may predate that gate; once installed, it must already have matching
restored data. The swap order is therefore a compatibility requirement, not an
interchangeable sequence of filesystem operations.

Do not turn cancellation or missing-helper paths into success, bypass the startup
gate, or delete a journal merely to allow launch. Any change to swap order,
cleanup or recovery needs failure-path tests against temporary directories.

## Source and verification

- [Policy and records](../Sources/Application/TimeMachine/TimeMachineModels.swift)
- [Snapshot manager](../Sources/Application/TimeMachine/TimeMachineSnapshotManager.swift)
- [Paths](../Sources/Application/TimeMachine/TimeMachinePaths.swift)
- [Restore coordinator](../Sources/Application/TimeMachine/TimeMachineRestoreCoordinator.swift)
- [Installer core](../Sources/Application/TimeMachine/TimeMachineInstallerCore.swift)
- [Startup recovery](../Sources/Application/TimeMachine/TimeMachineStartupRecoveryGate.swift)
- [Package downloader](../Sources/Networking/TimeMachinePackageDownloader.swift)
- [Selected-backup restore tests](../Tests/PhiBrowserTests/TimeMachineRestoreCoordinatorTests.swift)
- [Installer ordering and recovery tests](../Tests/PhiBrowserTests/TimeMachineInstallerCoreTests.swift)

The `TimeMachineCoreTests`, `TimeMachineSnapshotTests`,
`TimeMachineRestoreCoordinatorTests`, `TimeMachineInstallerCoreTests` and
`TimeMachineBootstrapTests` cover different parts of the transaction. Follow
[testing](testing.md) for execution. Real installation acceptance needs a disposable
application/data environment and the matching package; do not use a developer's
active profile as a test fixture.
