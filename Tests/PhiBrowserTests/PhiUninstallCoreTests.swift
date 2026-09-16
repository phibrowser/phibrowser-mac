// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import XCTest
@testable import Phi

final class PhiUninstallCoreTests: XCTestCase {
    private let paths = PhiUninstallPaths(
        applicationSupport: URL(
            fileURLWithPath: "/Users/x/Library/Application Support",
            isDirectory: true
        ),
        caches: URL(fileURLWithPath: "/Users/x/Library/Caches", isDirectory: true)
    )
    private let appBundleURL = URL(
        fileURLWithPath: "/Applications/Phi Canary.app",
        isDirectory: true
    )

    func testChannelFromBrowserBundleID() {
        XCTAssertEqual(PhiUninstallChannel.from(browserBundleID: "com.phibrowser.Mac"), .stable)
        XCTAssertEqual(PhiUninstallChannel.from(browserBundleID: "COM.PHIBROWSER.CANARY.MAC"), .canary)
        XCTAssertEqual(PhiUninstallChannel.from(browserBundleID: "com.phibrowser.dev.Mac"), .dev)
        XCTAssertNil(PhiUninstallChannel.from(browserBundleID: "com.example.Other"))
    }

    func testChannelBundleIDs() {
        XCTAssertEqual(PhiUninstallChannel.stable.browserBundleID, "com.phibrowser.Mac")
        XCTAssertEqual(PhiUninstallChannel.canary.browserBundleID, "com.phibrowser.canary.Mac")
        XCTAssertEqual(PhiUninstallChannel.dev.browserBundleID, "com.phibrowser.dev.Mac")
        XCTAssertEqual(PhiUninstallChannel.canary.sentinelBundleID, "com.phibrowser.canary.Sentinel")
    }

    func testPhiChatShimIdentityIsChannelScoped() {
        XCTAssertEqual(
            PhiChatUninstallIdentity.shimBundleIdentifier(
                browserBundleIdentifier: PhiUninstallChannel.canary.browserBundleID
            ),
            "com.phibrowser.canary.Mac.app.hagekpigdlbdgnimipikmpccaogpnimp"
        )
    }

    func testChannelScopedRoots() {
        XCTAssertEqual(
            paths.browserApplicationSupport(.canary).path,
            "/Users/x/Library/Application Support/com.phibrowser.canary.Mac"
        )
        XCTAssertEqual(
            paths.browserCaches(.canary).path,
            "/Users/x/Library/Caches/com.phibrowser.canary.Mac"
        )
        XCTAssertEqual(
            paths.sentinelApplicationSupport(.canary).path,
            "/Users/x/Library/Application Support/com.phibrowser.canary.Sentinel"
        )
        XCTAssertEqual(
            paths.sentinelCaches(.canary).path,
            "/Users/x/Library/Caches/com.phibrowser.canary.Sentinel"
        )
        XCTAssertEqual(
            paths.browserPreferences(.canary).path,
            "/Users/x/Library/Preferences/com.phibrowser.canary.Mac.plist"
        )
        XCTAssertEqual(
            paths.sentinelPreferences(.canary).path,
            "/Users/x/Library/Preferences/com.phibrowser.canary.Sentinel.plist"
        )
        XCTAssertEqual(
            paths.browserWebKit(.canary).path,
            "/Users/x/Library/WebKit/com.phibrowser.canary.Mac"
        )
        XCTAssertEqual(
            paths.sentinelWebKit(.canary).path,
            "/Users/x/Library/WebKit/com.phibrowser.canary.Sentinel"
        )
        XCTAssertEqual(
            paths.browserTimeMachine(.canary).path,
            "/Users/x/Library/Application Support/com.phibrowser.TimeMachine/com.phibrowser.canary.Mac"
        )
        XCTAssertEqual(
            paths.sentinelTimeMachine(.canary).path,
            "/Users/x/Library/Application Support/com.phibrowser.sentinel.TimeMachine/com.phibrowser.canary.Sentinel"
        )
        XCTAssertEqual(
            paths.sentinelLogs(.stable).path,
            "/Users/x/Library/Logs/PhiSentinel"
        )
        XCTAssertEqual(
            paths.sentinelLogs(.canary).path,
            "/Users/x/Library/Logs/PhiSentinel-Canary"
        )
    }

    func testPlannerSeparatesAllDataFromFinalAppBundleRemoval() {
        let planner = PhiUninstallPlanner(
            paths: paths,
            channel: .canary,
            appBundleURL: appBundleURL
        )

        XCTAssertEqual(planner.planAllData().steps, [
            .deleteTree(paths.browserApplicationSupport(.canary)),
            .deleteTree(paths.browserCaches(.canary)),
            .deleteTree(paths.sentinelApplicationSupport(.canary)),
            .deleteTree(paths.sentinelCaches(.canary)),
            .deletePreferences(
                domain: PhiUninstallChannel.canary.browserBundleID,
                plistURL: paths.browserPreferences(.canary)
            ),
            .deletePreferences(
                domain: PhiUninstallChannel.canary.sentinelBundleID,
                plistURL: paths.sentinelPreferences(.canary)
            ),
            .deleteTree(paths.browserWebKit(.canary)),
            .deleteTree(paths.sentinelWebKit(.canary)),
            .deleteTree(paths.browserHTTPStorage(.canary)),
            .deleteTree(paths.browserHTTPCookies(.canary)),
            .deleteTree(paths.sentinelHTTPStorage(.canary)),
            .deleteTree(paths.sentinelHTTPCookies(.canary)),
            .deleteTree(paths.browserTimeMachine(.canary)),
            .deleteTree(paths.sentinelTimeMachine(.canary)),
            .deleteTree(paths.sentinelLogs(.stable)),
            .deleteTree(paths.sentinelLogs(.canary)),
            .deleteTree(paths.sentinelLogs(.dev)),
        ])
        XCTAssertEqual(
            planner.planAppBundleRemoval().steps,
            [.deleteTree(appBundleURL)]
        )
    }

    func testPlannerIncludesPhiChatShimWhenPresent() {
        let shimURL = URL(fileURLWithPath: "/Users/x/Applications/Phi Chat.app", isDirectory: true)
        let planner = PhiUninstallPlanner(
            paths: paths,
            channel: .canary,
            appBundleURL: appBundleURL,
            chatShimBundleURL: shimURL
        )

        XCTAssertEqual(
            planner.planAppBundleRemoval().steps,
            [.deleteTree(appBundleURL), .deleteTree(shimURL)]
        )
        let allowlist = PhiUninstallPathAllowlist(
            paths: paths,
            channel: .canary,
            appBundleURL: appBundleURL,
            chatShimBundleURL: shimURL
        )
        XCTAssertTrue(allowlist.isAllowed(shimURL))
    }

    func testPlanRoundTripsThroughJSON() throws {
        let plan = PhiUninstallPlan(
            hostProcessID: 1234,
            channel: .canary,
            appBundleURL: appBundleURL
        )

        let decoded = try JSONDecoder().decode(
            PhiUninstallPlan.self,
            from: JSONEncoder().encode(plan)
        )

        XCTAssertEqual(decoded, plan)
    }

    func testAllowlistAcceptsOnlyCurrentChannelRootsAndAppBundle() {
        let allowlist = makeAllowlist()

        XCTAssertTrue(allowlist.isAllowed(paths.browserApplicationSupport(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.browserCaches(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelApplicationSupport(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelCaches(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.browserPreferences(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelPreferences(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.browserWebKit(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelWebKit(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.browserHTTPStorage(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelHTTPStorage(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.browserTimeMachine(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelTimeMachine(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelLogs(.stable)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelLogs(.canary)))
        XCTAssertTrue(allowlist.isAllowed(paths.sentinelLogs(.dev)))
        XCTAssertTrue(allowlist.isAllowed(appBundleURL))
        XCTAssertFalse(allowlist.isAllowed(paths.browserApplicationSupport(.stable)))
        XCTAssertFalse(allowlist.isAllowed(paths.sentinelApplicationSupport(.stable)))
        XCTAssertFalse(allowlist.isAllowed(paths.browserPreferences(.stable)))
        XCTAssertFalse(allowlist.isAllowed(paths.browserWebKit(.stable)))
        XCTAssertFalse(allowlist.isAllowed(paths.browserTimeMachine(.stable)))
        XCTAssertFalse(allowlist.isAllowed(URL(fileURLWithPath: "/")))
        XCTAssertFalse(allowlist.isAllowed(paths.applicationSupport))
        XCTAssertFalse(allowlist.isAllowed(paths.caches))
        XCTAssertFalse(allowlist.isAllowed(paths.preferences))
        XCTAssertFalse(allowlist.isAllowed(paths.webKit))
        XCTAssertFalse(allowlist.isAllowed(paths.httpStorages))
        XCTAssertFalse(allowlist.isAllowed(paths.logs))
        XCTAssertFalse(allowlist.isAllowed(
            paths.sentinelApplicationSupport(.canary)
                .appendingPathComponent("../../../etc", isDirectory: true)
        ))
    }

    func testAllowlistRejectsForeignAndDangerousPlans() {
        let allowlist = makeAllowlist()
        let foreign = paths.sentinelApplicationSupport(.stable)
        XCTAssertThrowsError(try allowlist.validate(
            PhiUninstallDeletionPlan(steps: [.deleteTree(foreign)])
        )) { error in
            XCTAssertEqual(
                error as? PhiUninstallSafetyError,
                .pathNotAllowed(foreign.standardizedFileURL.path)
            )
        }

        let library = paths.applicationSupport.deletingLastPathComponent()
        XCTAssertThrowsError(try allowlist.validate(
            PhiUninstallDeletionPlan(steps: [.deleteTree(library)])
        )) { error in
            XCTAssertEqual(
                error as? PhiUninstallSafetyError,
                .dangerousPath(library.standardizedFileURL.path)
            )
        }
    }

    func testAllowlistRejectsEscapingSymlink() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let managedRoot = fixture.paths.sentinelApplicationSupport(.canary)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let realFile = managedRoot.appendingPathComponent("real.txt", isDirectory: false)
        try Data("managed".utf8).write(to: realFile)

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt", isDirectory: false)
        try Data("outside".utf8).write(to: secret)
        let escape = managedRoot.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        let allowlist = PhiUninstallPathAllowlist(
            paths: fixture.paths,
            channel: .canary,
            appBundleURL: fixture.appBundleURL
        )
        XCTAssertTrue(allowlist.isAllowed(realFile))
        XCTAssertTrue(allowlist.isAllowedResolvingSymlinks(realFile))
        XCTAssertTrue(allowlist.isAllowed(escape))
        XCTAssertFalse(allowlist.isAllowedResolvingSymlinks(escape))
        XCTAssertFalse(allowlist.isAllowedResolvingSymlinks(
            escape.appendingPathComponent("secret.txt", isDirectory: false)
        ))
    }

    func testAllowlistRejectsTargetBehindSymlinkedParent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let library = fixture.root.appendingPathComponent("Library", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let applicationSupport = library.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: applicationSupport,
            withDestinationURL: outside
        )
        let symlinkedPaths = PhiUninstallPaths(
            applicationSupport: applicationSupport,
            caches: fixture.paths.caches
        )
        let target = symlinkedPaths.browserApplicationSupport(.canary)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let retainedFile = target.appendingPathComponent("retained.txt", isDirectory: false)
        try Data("outside".utf8).write(to: retainedFile)

        let allowlist = PhiUninstallPathAllowlist(
            paths: symlinkedPaths,
            channel: .canary,
            appBundleURL: fixture.appBundleURL
        )
        XCTAssertTrue(allowlist.isAllowed(target))
        XCTAssertFalse(allowlist.isAllowedResolvingSymlinks(target))

        let failures = PhiUninstallDeletionExecutor(allowlist: allowlist).execute(
            PhiUninstallDeletionPlan(steps: [.deleteTree(target)])
        )
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedFile.path))
    }

    func testAllowlistRejectsAppBundleNestedInsideDataRoot() {
        let overlappingAppBundleURL = paths.browserApplicationSupport(.canary)
            .appendingPathComponent("Phi Canary.app", isDirectory: true)
        let planner = PhiUninstallPlanner(
            paths: paths,
            channel: .canary,
            appBundleURL: overlappingAppBundleURL
        )
        let allowlist = PhiUninstallPathAllowlist(
            paths: paths,
            channel: .canary,
            appBundleURL: overlappingAppBundleURL
        )

        XCTAssertThrowsError(
            try allowlist.validateAppBundleIsDisjoint(from: planner.planAllData())
        ) { error in
            XCTAssertEqual(
                error as? PhiUninstallSafetyError,
                .appBundleOverlapsDataPath(
                    appBundle: overlappingAppBundleURL.standardizedFileURL.path,
                    dataPath: paths.browserApplicationSupport(.canary).standardizedFileURL.path
                )
            )
        }
    }

    func testExecutorDeletesAllPlannedDataAndFinalAppBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let directoryTargets = [
            fixture.paths.browserApplicationSupport(.canary),
            fixture.paths.browserCaches(.canary),
            fixture.paths.sentinelApplicationSupport(.canary),
            fixture.paths.sentinelCaches(.canary),
            fixture.paths.browserWebKit(.canary),
            fixture.paths.sentinelWebKit(.canary),
            fixture.paths.browserHTTPStorage(.canary),
            fixture.paths.sentinelHTTPStorage(.canary),
            fixture.paths.browserTimeMachine(.canary),
            fixture.paths.sentinelTimeMachine(.canary),
            fixture.paths.sentinelLogs(.stable),
            fixture.paths.sentinelLogs(.canary),
            fixture.paths.sentinelLogs(.dev),
            fixture.appBundleURL,
        ]
        for target in directoryTargets {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("data".utf8).write(to: target.appendingPathComponent("file"))
        }
        let fileTargets = [
            fixture.paths.browserPreferences(.canary),
            fixture.paths.sentinelPreferences(.canary),
            fixture.paths.browserHTTPCookies(.canary),
            fixture.paths.sentinelHTTPCookies(.canary),
        ]
        for target in fileTargets {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("data".utf8).write(to: target)
        }

        let planner = PhiUninstallPlanner(
            paths: fixture.paths,
            channel: .canary,
            appBundleURL: fixture.appBundleURL
        )
        let allowlist = PhiUninstallPathAllowlist(
            paths: fixture.paths,
            channel: .canary,
            appBundleURL: fixture.appBundleURL
        )
        let dataPlan = planner.planAllData()
        let appBundlePlan = planner.planAppBundleRemoval()
        XCTAssertNoThrow(try allowlist.validate(dataPlan))
        XCTAssertNoThrow(try allowlist.validate(appBundlePlan))
        XCTAssertNoThrow(try allowlist.validateAppBundleIsDisjoint(from: dataPlan))

        var removedPreferenceDomains: [String] = []
        let executor = PhiUninstallDeletionExecutor(
            allowlist: allowlist,
            preferencesDomainRemover: { removedPreferenceDomains.append($0) }
        )
        let failures = executor.execute(dataPlan) + executor.execute(appBundlePlan)

        XCTAssertTrue(failures.isEmpty)
        for target in directoryTargets + fileTargets {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
        XCTAssertEqual(removedPreferenceDomains, [
            PhiUninstallChannel.canary.browserBundleID,
            PhiUninstallChannel.canary.sentinelBundleID,
        ])
    }

    func testExecutorRefusesSymlinkTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt", isDirectory: false)
        try Data("outside".utf8).write(to: secret)
        let browserRoot = fixture.paths.browserApplicationSupport(.canary)
        try FileManager.default.createDirectory(
            at: browserRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: browserRoot, withDestinationURL: outside)

        let allowlist = PhiUninstallPathAllowlist(
            paths: fixture.paths,
            channel: .canary,
            appBundleURL: fixture.appBundleURL
        )
        let failures = PhiUninstallDeletionExecutor(allowlist: allowlist).execute(
            PhiUninstallDeletionPlan(steps: [.deleteTree(browserRoot)])
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }

    func testProcessWaiterCompletesAndTimesOut() {
        var pollsRemaining = 2
        XCTAssertTrue(PhiUninstallProcessWaiter.waitUntil(
            timeout: 0.1,
            pollInterval: 0.001,
            isRunning: {
                defer { pollsRemaining -= 1 }
                return pollsRemaining > 0
            }
        ))
        XCTAssertFalse(PhiUninstallProcessWaiter.waitUntil(
            timeout: 0,
            pollInterval: 0.001,
            isRunning: { true }
        ))
    }

    private func makeAllowlist() -> PhiUninstallPathAllowlist {
        PhiUninstallPathAllowlist(
            paths: paths,
            channel: .canary,
            appBundleURL: appBundleURL
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        paths: PhiUninstallPaths,
        appBundleURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("phi-uninstall-tests-\(UUID().uuidString)", isDirectory: true)
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return (
            root,
            PhiUninstallPaths(applicationSupport: applicationSupport, caches: caches),
            root.appendingPathComponent("Phi Canary.app", isDirectory: true)
        )
    }
}

final class PhiUninstallHelperLauncherTests: XCTestCase {
    func testPrepareCopiesHelperAndWritesPrivatePlan() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("phi-uninstall-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let appBundleURL = root.appendingPathComponent("Phi Canary.app", isDirectory: true)
        let helpersURL = appBundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try fileManager.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        let sourceHelperURL = helpersURL.appendingPathComponent(
            PhiUninstallHelperLauncher.helperFilename,
            isDirectory: false
        )
        try Data("helper".utf8).write(to: sourceHelperURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceHelperURL.path
        )
        let plan = PhiUninstallPlan(
            hostProcessID: 1234,
            channel: .canary,
            appBundleURL: appBundleURL
        )

        let prepared = try PhiUninstallHelperLauncher.prepare(
            plan: plan,
            appBundleURL: appBundleURL,
            temporaryDirectoryURL: root,
            fileManager: fileManager
        )
        let workspace = try PhiUninstallPreparedWorkspace.validate(
            planURL: prepared.planURL,
            executableURL: prepared.executableURL,
            temporaryDirectoryURL: root,
            fileManager: fileManager
        )

        XCTAssertEqual(workspace.directoryURL, prepared.workingDirectoryURL)
        XCTAssertTrue(fileManager.isExecutableFile(atPath: prepared.executableURL.path))
        XCTAssertEqual(try Data(contentsOf: prepared.executableURL), Data("helper".utf8))
        let decodedPlan = try JSONDecoder().decode(
            PhiUninstallPlan.self,
            from: Data(contentsOf: prepared.planURL)
        )
        XCTAssertEqual(decodedPlan, plan)
        XCTAssertEqual(try permissions(at: prepared.workingDirectoryURL), 0o700)
        XCTAssertEqual(try permissions(at: prepared.executableURL), 0o755)
        XCTAssertEqual(try permissions(at: prepared.planURL), 0o600)
    }

    func testWorkspaceValidationRejectsPlanOutsideHelperDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "phi-uninstall-workspace-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: root) }

        let appBundleURL = root.appendingPathComponent("Phi Canary.app", isDirectory: true)
        let helpersURL = appBundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try fileManager.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        let sourceHelperURL = helpersURL.appendingPathComponent(
            PhiUninstallHelperLauncher.helperFilename,
            isDirectory: false
        )
        try Data("helper".utf8).write(to: sourceHelperURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceHelperURL.path
        )
        let plan = PhiUninstallPlan(
            hostProcessID: 1234,
            channel: .canary,
            appBundleURL: appBundleURL
        )
        let prepared = try PhiUninstallHelperLauncher.prepare(
            plan: plan,
            appBundleURL: appBundleURL,
            temporaryDirectoryURL: root,
            fileManager: fileManager
        )

        let unrelatedDirectoryURL = root.appendingPathComponent(
            "unrelated-directory",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: unrelatedDirectoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unrelatedPlanURL = unrelatedDirectoryURL.appendingPathComponent(
            PhiUninstallPreparedWorkspace.planFilename,
            isDirectory: false
        )
        try JSONEncoder().encode(plan).write(to: unrelatedPlanURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: unrelatedPlanURL.path
        )

        XCTAssertThrowsError(try PhiUninstallPreparedWorkspace.validate(
            planURL: unrelatedPlanURL,
            executableURL: prepared.executableURL,
            temporaryDirectoryURL: root,
            fileManager: fileManager
        )) { error in
            guard case PhiUninstallWorkspaceError.unsafeWorkspace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedDirectoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedPlanURL.path))
    }

    func testPrepareFailsWhenEmbeddedHelperIsMissing() {
        let appBundleURL = URL(fileURLWithPath: "/tmp/Missing Phi.app", isDirectory: true)
        let plan = PhiUninstallPlan(
            hostProcessID: 1234,
            channel: .canary,
            appBundleURL: appBundleURL
        )

        XCTAssertThrowsError(try PhiUninstallHelperLauncher.prepare(
            plan: plan,
            appBundleURL: appBundleURL
        )) { error in
            guard case PhiUninstallHelperLauncherError.helperUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLaunchAcceptsExactReadinessSignal() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        printf 'PHI_UNINSTALLER_READY_V1\\n'
        exec sleep 10
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let running = try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 1
        )
        running.cancel()
    }

    func testLaunchCommitsOnlyAfterTwoWayHandshake() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        printf 'PHI_UNINSTALLER_READY_V1\\n'
        IFS= read -r signal
        [ "$signal" = 'PHI_UNINSTALLER_COMMIT_V1' ] || exit 3
        printf 'PHI_UNINSTALLER_COMMITTED_V1\\n'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let running = try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 1
        )
        XCTAssertNoThrow(try running.commit())
    }

    func testCommitRejectsHelperThatExitsAfterReadiness() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        printf 'PHI_UNINSTALLER_READY_V1\\n'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let running = try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 1
        )
        XCTAssertThrowsError(try running.commit()) { error in
            switch error {
            case PhiUninstallHelperLauncherError.helperCommitWriteFailed,
                 PhiUninstallHelperLauncherError.helperExitedBeforeCommit:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCommitRejectsInvalidAcknowledgement() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        printf 'PHI_UNINSTALLER_READY_V1\\n'
        IFS= read -r signal
        printf 'WRONG\\n'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let running = try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 1
        )
        XCTAssertThrowsError(try running.commit()) { error in
            guard case PhiUninstallHelperLauncherError.invalidHelperCommitSignal = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCommitTimesOutAndReapsHelperWithoutAcknowledgement() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        printf '%s' "$$" > "$2.pid"
        printf 'PHI_UNINSTALLER_READY_V1\\n'
        IFS= read -r signal
        exec sleep 10
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidURL = URL(fileURLWithPath: "\(fixture.prepared.planURL.path).pid")

        let running = try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 0.05
        )
        XCTAssertThrowsError(try running.commit()) { error in
            guard case PhiUninstallHelperLauncherError.helperCommitTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let pidString = try String(contentsOf: pidURL, encoding: .utf8)
        let processID = try XCTUnwrap(Int32(pidString))
        XCTAssertEqual(Darwin.kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCommitSignalRejectsEOFAndExtraData() {
        XCTAssertTrue(PhiUninstallReadiness.isValidCommitSignal(
            Data(PhiUninstallReadiness.commitToken.utf8)
        ))
        XCTAssertFalse(PhiUninstallReadiness.isValidCommitSignal(nil))
        XCTAssertFalse(PhiUninstallReadiness.isValidCommitSignal(Data()))
        XCTAssertFalse(PhiUninstallReadiness.isValidCommitSignal(
            Data("\(PhiUninstallReadiness.commitToken)extra".utf8)
        ))
    }

    func testLaunchRejectsEarlyExitBeforeReadiness() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        exit 2
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 1
        )) { error in
            guard case PhiUninstallHelperLauncherError.helperExitedBeforeReady = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLaunchRejectsInvalidReadinessSignal() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        printf 'WRONG\\n'
        exec sleep 10
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 1
        )) { error in
            guard case PhiUninstallHelperLauncherError.invalidHelperReadinessSignal = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLaunchTimesOutWithoutReadinessSignal() throws {
        let fixture = try makeLaunchFixture(script: """
        #!/bin/sh
        exec sleep 10
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try PhiUninstallHelperLauncher.launch(
            fixture.prepared,
            readinessTimeout: 0.05
        )) { error in
            guard case PhiUninstallHelperLauncherError.helperReadinessTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeLaunchFixture(
        script: String
    ) throws -> (root: URL, prepared: PreparedPhiUninstaller) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "phi-uninstall-launch-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let executableURL = root.appendingPathComponent("PhiUninstaller", isDirectory: false)
        try Data(script.utf8).write(to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let planURL = root.appendingPathComponent("uninstall-plan.json", isDirectory: false)
        try Data().write(to: planURL)
        return (
            root,
            PreparedPhiUninstaller(
                workingDirectoryURL: root,
                executableURL: executableURL,
                planURL: planURL
            )
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
