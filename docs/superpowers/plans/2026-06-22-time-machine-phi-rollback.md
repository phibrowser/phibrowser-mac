# Phi Time Machine Rollback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Phi-side Time Machine backup and restore with exact-build backup triggers, completed-backup menu entries, rollback zip download with SHA-256 verification, and a crash-resumable installer helper.

**Architecture:** Add a focused `Sources/Application/TimeMachine` feature module for policy, paths, catalog, clone/copy, snapshot, install-plan, and journal logic. The main app creates backups before Chromium launch, shows completed backups in Help, prepares rollback packages, and launches a copied helper from `Pending/<operation-id>`. A new command-line helper target applies restore plans after Phi exits, with staging, journal phases, app-last ordering, and startup recovery.

**Tech Stack:** Swift/Foundation/AppKit, Objective-C `main.m` bridge through `Phi-Swift.h`, `clonefile(2)`, `CryptoKit` for SHA-256, `/usr/bin/unzip`, `xcodebuild`, XCTest.

---

### Task 1: Core Time Machine Models, Paths, Policy, Catalog, and Journal

**Files:**
- Create: `Sources/Application/TimeMachine/TimeMachineModels.swift`
- Create: `Sources/Application/TimeMachine/TimeMachinePaths.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineRollbackPolicyLoader.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineCatalogStore.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineRestoreJournal.swift`
- Create: `Tests/PhiBrowserTests/TimeMachineCoreTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write tests for exact policy trigger, catalog labels, and journal phases**

Add tests that create temporary Time Machine roots and verify:
- `backupTriggerBuild` only matches the exact build.
- completed backup labels render as `Phi 1.6 build 590 on 2026.6.11`.
- catalog writes are atomic and only completed backups are returned.
- journal phases round-trip and incomplete phases require recovery.

- [ ] **Step 2: Run the new tests and verify compile failures**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineCoreTests
```

Expected: fail because the Time Machine types do not exist.

- [ ] **Step 3: Implement minimal core types**

Implement:
- `TimeMachineRollbackPolicy`
- `TimeMachineBackupRecord`
- `TimeMachineCatalog`
- `TimeMachineInstallPlan`
- `TimeMachineJournal`
- `TimeMachineRestorePhase`
- `TimeMachinePaths`
- `TimeMachineRollbackPolicyLoader`
- `TimeMachineCatalogStore`
- `TimeMachineRestoreJournal`

- [ ] **Step 4: Add files to the app target**

Create a `TimeMachine` group under the `Application` group and add the new Swift source files to the main app source build phase.

- [ ] **Step 5: Run tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineCoreTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-22-time-machine-phi-rollback-design.md docs/superpowers/plans/2026-06-22-time-machine-phi-rollback.md Sources/Application/TimeMachine Tests/PhiBrowserTests/TimeMachineCoreTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: add Phi Time Machine rollback core"
```

### Task 2: Clone-First Snapshot and Restore Staging

**Files:**
- Create: `Sources/Application/TimeMachine/TimeMachineFileCloner.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineSnapshotManager.swift`
- Create: `Tests/PhiBrowserTests/TimeMachineSnapshotTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write snapshot tests**

Add tests that verify:
- full mode snapshots the entire application-support directory.
- Phi-only mode snapshots only the `Phi/` child and preferences.
- snapshots are first written to staging and only completed snapshots are cataloged.
- failed snapshots leave no completed catalog entry.

- [ ] **Step 2: Run the snapshot tests and verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineSnapshotTests
```

Expected: fail because snapshot code does not exist.

- [ ] **Step 3: Implement clone-first recursive copy**

Implement `TimeMachineFileCloner`:
- create directories normally.
- copy symlinks as symlinks.
- call `clonefile(2)` for regular files.
- fall back to `FileManager.copyItem` on unsupported clone errors.
- fail the operation on unexpected unsupported file types.

- [ ] **Step 4: Implement snapshot manager**

Implement `TimeMachineSnapshotManager.prepareBackupIfNeeded(currentVersion:currentBuild:)`:
- load policy.
- require exact `currentBuild == backupTriggerBuild`.
- skip if a completed backup exists for the trigger build.
- stage snapshot under `Snapshots/<id>.staging`.
- write snapshot manifest.
- rename staging to `Snapshots/<id>`.
- append completed record to `catalog.json`.

- [ ] **Step 5: Run snapshot tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineSnapshotTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Application/TimeMachine Tests/PhiBrowserTests/TimeMachineSnapshotTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: create Phi Time Machine snapshots"
```

### Task 3: Pre-Chromium Bootstrap and Startup Recovery Gate

**Files:**
- Create: `Sources/Application/TimeMachine/TimeMachineBootstrap.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineStartupRecoveryGate.swift`
- Create: `Tests/PhiBrowserTests/TimeMachineBootstrapTests.swift`
- Modify: `Sources/Other/main.m`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write bootstrap tests**

Add tests that verify:
- incomplete journal phases require recovery.
- completed, failed, and reverted phases do not block startup.
- backup preparation is skipped when recovery is required.

- [ ] **Step 2: Run bootstrap tests and verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineBootstrapTests
```

Expected: fail because bootstrap code does not exist.

- [ ] **Step 3: Implement Obj-C-visible bootstrap**

Add:

```swift
@objc final class TimeMachineBootstrap: NSObject {
    @objc static func recoverPendingRestoreIfNeeded() -> Bool
    @objc static func prepareBackupIfNeeded()
}
```

`recoverPendingRestoreIfNeeded()` launches a copied pending helper in recovery mode when possible and returns `true` when the current process should exit before Chromium starts.

- [ ] **Step 4: Wire `main.m` before Chromium launch**

Insert after shared logging install and before `ChromiumLauncher.sharedInstance()`:

```objc
if ([TimeMachineBootstrap recoverPendingRestoreIfNeeded]) {
    return 0;
}
[TimeMachineBootstrap prepareBackupIfNeeded];
```

- [ ] **Step 5: Run bootstrap tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineBootstrapTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Application/TimeMachine Sources/Other/main.m Tests/PhiBrowserTests/TimeMachineBootstrapTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: gate Time Machine restore before Chromium launch"
```

### Task 4: Rollback Package Download and Restore Coordinator

**Files:**
- Create: `Sources/Networking/TimeMachinePackageDownloader.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineRestoreCoordinator.swift`
- Create: `Tests/PhiBrowserTests/TimeMachineRestoreCoordinatorTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write package and coordinator tests**

Add tests that verify:
- SHA-256 mismatch fails.
- zip without top-level `Phi.app` fails.
- staged app bundle id and `CFBundleVersion` are validated.
- install plans are created from the selected completed backup, not the current policy.
- helper binary is copied into the pending operation directory before launch.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineRestoreCoordinatorTests
```

Expected: fail because package downloader and coordinator do not exist.

- [ ] **Step 3: Implement downloader under networking**

Implement a small networking-layer downloader that uses `URLSession` inside `Sources/Networking`, writes the zip to `Pending/<operation-id>/package.zip`, and verifies SHA-256 with `CryptoKit`.

- [ ] **Step 4: Implement restore coordinator**

Implement confirmation-independent coordination methods:
- prepare pending directory.
- call downloader.
- unzip via `/usr/bin/unzip`.
- validate staged `Phi.app`.
- copy helper binary into pending directory.
- write `install-plan.json`.
- launch helper with `--plan`.

- [ ] **Step 5: Run tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineRestoreCoordinatorTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Networking/TimeMachinePackageDownloader.swift Sources/Application/TimeMachine Tests/PhiBrowserTests/TimeMachineRestoreCoordinatorTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: prepare Phi Time Machine rollback packages"
```

### Task 5: Installer Helper Target and Crash-Resumable Restore

**Files:**
- Create: `Sources/TimeMachineInstaller/main.swift`
- Create: `Sources/Application/TimeMachine/TimeMachineInstallerCore.swift`
- Create: `Tests/PhiBrowserTests/TimeMachineInstallerCoreTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write installer-core tests**

Add temp-directory tests that verify:
- data is staged before live paths are touched.
- journal advances through `dataStaged`, `dataBackedUp`, `dataSwapped`, `appBackedUp`, `appSwapped`, and `completed`.
- a failure after `dataSwapped` restores emergency backups.
- app swap happens after data swap.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineInstallerCoreTests
```

Expected: fail because installer core does not exist.

- [ ] **Step 3: Implement installer core**

Implement restore application against injected paths:
- decode plan.
- wait for host PID unless disabled for tests.
- terminate Sentinel best-effort.
- stage data.
- back up data scope.
- swap data.
- back up app.
- swap app.
- open app.
- write journal and result.

- [ ] **Step 4: Add command-line helper target**

Add `PhiTimeMachineInstaller` as a macOS command-line target. Include shared Time Machine files needed by the helper and copy the built executable into `Phi.app/Contents/Helpers/`.

- [ ] **Step 5: Run installer tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineInstallerCoreTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TimeMachineInstaller Sources/Application/TimeMachine Tests/PhiBrowserTests/TimeMachineInstallerCoreTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: add Phi Time Machine installer helper"
```

### Task 6: Help Menu Integration

**Files:**
- Create: `Sources/Application/TimeMachine/TimeMachineMenuPresenter.swift`
- Modify: `Sources/Application/AppController+Menu.swift`
- Create: `Tests/PhiBrowserTests/TimeMachineMenuPresenterTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write menu presenter tests**

Add tests that verify:
- empty catalogs produce `No Backups Available`.
- completed backup labels use rollback version/build/date.
- selected backup IDs map back to records.

- [ ] **Step 2: Run menu tests and verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineMenuPresenterTests
```

Expected: fail because presenter code does not exist.

- [ ] **Step 3: Implement presenter and AppController menu actions**

Add Help menu submenu:

```text
Time Machine Backups
  Phi 1.6 build 590 on 2026.6.11
```

Selecting a backup shows a confirmation dialog and calls `TimeMachineRestoreCoordinator`.

- [ ] **Step 4: Run menu tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineMenuPresenterTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Application/TimeMachine Sources/Application/AppController+Menu.swift Tests/PhiBrowserTests/TimeMachineMenuPresenterTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: show Phi Time Machine backups in Help"
```

### Task 7: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run targeted Time Machine tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/TimeMachineCoreTests -only-testing:PhiBrowserTests/TimeMachineSnapshotTests -only-testing:PhiBrowserTests/TimeMachineBootstrapTests -only-testing:PhiBrowserTests/TimeMachineRestoreCoordinatorTests -only-testing:PhiBrowserTests/TimeMachineInstallerCoreTests -only-testing:PhiBrowserTests/TimeMachineMenuPresenterTests
```

Expected: pass.

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'
```

Expected: build succeeds.

- [ ] **Step 3: Check diff hygiene**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only expected Time Machine files are modified or committed.
