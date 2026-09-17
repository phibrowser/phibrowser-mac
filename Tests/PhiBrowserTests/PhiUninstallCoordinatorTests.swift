// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class PhiUninstallCoordinatorTests: XCTestCase {
    private final class Recorder {
        var events: [String] = []
    }

    private enum TestError: Error {
        case expected
    }

    func testConfirmationAddsUninstallBeforeCancelAndMarksItDestructive() {
        let alert = PhiUninstallCoordinator.makeConfirmationAlert()

        XCTAssertEqual(alert.buttons.map(\.title), ["Uninstall", "Cancel"])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertFalse(alert.buttons[1].hasDestructiveAction)
    }

    func testCancellationHasNoSideEffects() {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.presentConfirmation = {
            recorder.events.append("confirm")
            return false
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        coordinator.start()

        XCTAssertEqual(recorder.events, ["confirm"])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testConfirmedUninstallClearsAccountWithoutNotificationBeforeQuitting() async {
        let recorder = Recorder()
        let coordinator = PhiUninstallCoordinator(environment: makeEnvironment(recorder: recorder))

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, [
            "makePlan",
            "prepareHelper",
            "stopSentinelWatchdog",
            "unregisterSentinel",
            "requestSentinelTermination",
            "launchHelper",
            "clearLocalAccountData:false",
            "clearBitwardenSession",
            "commitHelper",
            "quit",
        ])
        XCTAssertEqual(coordinator.state, .committed)
    }

    func testPreparationFailureDoesNotTouchSentinelOrQuit() async {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.prepareHelper = { _ in
            recorder.events.append("prepareHelper")
            throw TestError.expected
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, ["makePlan", "prepareHelper", "presentFailure"])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testLaunchFailureCleansHelperAndRestoresSentinel() async {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.launchHelper = { _ in
            recorder.events.append("launchHelper")
            throw TestError.expected
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, [
            "makePlan",
            "prepareHelper",
            "stopSentinelWatchdog",
            "unregisterSentinel",
            "requestSentinelTermination",
            "launchHelper",
            "cleanupHelper",
            "restoreSentinel",
            "presentFailure",
        ])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testSentinelShutdownFailureStopsBeforeHelperLaunchOrCredentialCleanup() async {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.requestSentinelTermination = {
            recorder.events.append("requestSentinelTermination")
            return false
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, [
            "makePlan",
            "prepareHelper",
            "stopSentinelWatchdog",
            "unregisterSentinel",
            "requestSentinelTermination",
            "cleanupHelper",
            "restoreSentinel",
            "presentFailure",
        ])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testAccountCleanupFailureCancelsHelperAndDoesNotQuit() async {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.clearLocalAccountData = { postSharedTokenChange in
            recorder.events.append("clearLocalAccountData:\(postSharedTokenChange)")
            return false
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, [
            "makePlan",
            "prepareHelper",
            "stopSentinelWatchdog",
            "unregisterSentinel",
            "requestSentinelTermination",
            "launchHelper",
            "clearLocalAccountData:false",
            "cancelHelper",
            "cleanupHelper",
            "restoreSentinel",
            "presentFailure",
        ])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testBitwardenCleanupFailureCancelsHelperAndDoesNotQuit() async {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.clearBitwardenSession = {
            recorder.events.append("clearBitwardenSession")
            throw TestError.expected
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, [
            "makePlan",
            "prepareHelper",
            "stopSentinelWatchdog",
            "unregisterSentinel",
            "requestSentinelTermination",
            "launchHelper",
            "clearLocalAccountData:false",
            "clearBitwardenSession",
            "cancelHelper",
            "cleanupHelper",
            "restoreSentinel",
            "presentFailure",
        ])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testCommitFailureCancelsHelperAndDoesNotQuit() async {
        let recorder = Recorder()
        var environment = makeEnvironment(recorder: recorder)
        environment.launchHelper = { _ in
            recorder.events.append("launchHelper")
            return RunningPhiUninstaller(
                commit: {
                    recorder.events.append("commitHelper")
                    throw TestError.expected
                },
                cancel: {
                    recorder.events.append("cancelHelper")
                }
            )
        }
        let coordinator = PhiUninstallCoordinator(environment: environment)

        await coordinator.performConfirmedUninstall()

        XCTAssertEqual(recorder.events, [
            "makePlan",
            "prepareHelper",
            "stopSentinelWatchdog",
            "unregisterSentinel",
            "requestSentinelTermination",
            "launchHelper",
            "clearLocalAccountData:false",
            "clearBitwardenSession",
            "commitHelper",
            "cancelHelper",
            "resumeBitwardenSession",
            "cleanupHelper",
            "restoreSentinel",
            "presentFailure",
        ])
        XCTAssertEqual(coordinator.state, .idle)
    }

    private func makeEnvironment(recorder: Recorder) -> PhiUninstallCoordinator.Environment {
        let appBundleURL = URL(fileURLWithPath: "/Applications/Phi Canary.app", isDirectory: true)
        let plan = PhiUninstallPlan(
            hostProcessID: 1234,
            channel: .canary,
            appBundleURL: appBundleURL
        )
        let prepared = PreparedPhiUninstaller(
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/phi-uninstall"),
            executableURL: URL(fileURLWithPath: "/tmp/phi-uninstall/PhiUninstaller"),
            planURL: URL(fileURLWithPath: "/tmp/phi-uninstall/uninstall-plan.json")
        )
        return PhiUninstallCoordinator.Environment(
            presentConfirmation: { true },
            makePlan: {
                recorder.events.append("makePlan")
                return plan
            },
            prepareHelper: { receivedPlan in
                recorder.events.append("prepareHelper")
                XCTAssertEqual(receivedPlan, plan)
                return prepared
            },
            unregisterSentinel: {
                recorder.events.append("unregisterSentinel")
            },
            stopSentinelWatchdog: {
                recorder.events.append("stopSentinelWatchdog")
            },
            requestSentinelTermination: {
                recorder.events.append("requestSentinelTermination")
                return true
            },
            launchHelper: { receivedPrepared in
                recorder.events.append("launchHelper")
                XCTAssertEqual(receivedPrepared, prepared)
                return RunningPhiUninstaller(
                    commit: {
                        recorder.events.append("commitHelper")
                    },
                    cancel: {
                        recorder.events.append("cancelHelper")
                    }
                )
            },
            clearLocalAccountData: { postSharedTokenChange in
                recorder.events.append("clearLocalAccountData:\(postSharedTokenChange)")
                return true
            },
            clearBitwardenSession: {
                recorder.events.append("clearBitwardenSession")
            },
            resumeBitwardenSession: {
                recorder.events.append("resumeBitwardenSession")
            },
            cleanupHelper: { receivedPrepared in
                recorder.events.append("cleanupHelper")
                XCTAssertEqual(receivedPrepared, prepared)
            },
            restoreSentinel: {
                recorder.events.append("restoreSentinel")
            },
            presentFailure: { _ in
                recorder.events.append("presentFailure")
            },
            quit: {
                recorder.events.append("quit")
            }
        )
    }
}
