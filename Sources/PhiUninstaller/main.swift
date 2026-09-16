// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

enum PhiUninstallerMainError: Error, LocalizedError {
    case missingValue(String)
    case unsupportedArguments([String])
    case missingPlan(URL)
    case unsupportedPlanVersion(Int)
    case invalidAppSignature(URL)
    case browserStillRunning(String)
    case sentinelDidNotExit(String)
    case chatShimDidNotExit(String)
    case invalidCommitSignal
    case unsafePlan(String)
    case deletionFailures([String])

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .unsupportedArguments(let arguments):
            return "Unsupported Phi uninstaller arguments: \(arguments.joined(separator: " "))."
        case .missingPlan(let url):
            return "The uninstall plan is missing at \(url.path)."
        case .unsupportedPlanVersion(let version):
            return "Unsupported uninstall plan version \(version)."
        case .invalidAppSignature(let url):
            return "The Phi app signature is invalid at \(url.path)."
        case .browserStillRunning(let bundleID):
            return "A Phi process is still running for \(bundleID)."
        case .sentinelDidNotExit(let bundleID):
            return "Phi Sentinel did not exit for \(bundleID)."
        case .chatShimDidNotExit(let bundleID):
            return "Phi Chat did not exit for \(bundleID)."
        case .invalidCommitSignal:
            return "Phi exited before committing the uninstall operation."
        case .unsafePlan(let reason):
            return "The uninstall plan failed validation: \(reason)."
        case .deletionFailures(let failures):
            return failures.joined(separator: "; ")
        }
    }
}

do {
    try PhiUninstallerMain.run(arguments: Array(CommandLine.arguments.dropFirst()))
    exit(0)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    writePhiUninstallerLog(message)
    exit(1)
}

private func writePhiUninstallerLog(_ message: String) {
    let formattedMessage = "PhiUninstaller: \(message)"
    NSLog("%@", formattedMessage)
    FileHandle.standardError.write(Data("\(formattedMessage)\n".utf8))
}

enum PhiUninstallerMain {
    static let sentinelExitTimeout: TimeInterval = 180

    static func run(arguments: [String]) throws {
        guard let planPath = try value(after: "--plan", in: arguments) else {
            throw PhiUninstallerMainError.unsupportedArguments(arguments)
        }
        let planURL = URL(fileURLWithPath: planPath, isDirectory: false)
        let executableURL = URL(
            fileURLWithPath: CommandLine.arguments[0],
            isDirectory: false
        )
        let workspace = try PhiUninstallPreparedWorkspace.validate(
            planURL: planURL,
            executableURL: executableURL
        )
        defer {
            try? FileManager.default.removeItem(at: workspace.directoryURL)
        }

        let plan = try loadPlan(at: workspace.planURL)
        guard plan.schemaVersion == PhiUninstallPlan.currentSchemaVersion else {
            throw PhiUninstallerMainError.unsupportedPlanVersion(plan.schemaVersion)
        }

        guard PhiUninstallSignatureVerifier.verifyAppBundle(
            at: plan.appBundleURL,
            expectedBundleID: plan.channel.browserBundleID
        ) else {
            throw PhiUninstallerMainError.invalidAppSignature(plan.appBundleURL)
        }

        let paths = PhiUninstallPaths.standard()
        let planner = PhiUninstallPlanner(
            paths: paths,
            channel: plan.channel,
            appBundleURL: plan.appBundleURL,
            chatShimBundleURL: plan.chatShimBundleURL
        )
        let dataPlan = planner.planAllData()
        let appBundlePlan = planner.planAppBundleRemoval()
        let allowlist = PhiUninstallPathAllowlist(
            paths: paths,
            channel: plan.channel,
            appBundleURL: plan.appBundleURL,
            chatShimBundleURL: plan.chatShimBundleURL
        )
        do {
            try allowlist.validate(dataPlan)
            try allowlist.validate(appBundlePlan)
            try allowlist.validateAppBundleIsDisjoint(from: dataPlan)
        } catch {
            throw PhiUninstallerMainError.unsafePlan(String(describing: error))
        }

        try FileHandle.standardOutput.write(
            contentsOf: Data(PhiUninstallReadiness.readyToken.utf8)
        )

        let commitSignal = try FileHandle.standardInput.readToEnd()
        guard PhiUninstallReadiness.isValidCommitSignal(commitSignal) else {
            throw PhiUninstallerMainError.invalidCommitSignal
        }
        try FileHandle.standardOutput.write(
            contentsOf: Data(PhiUninstallReadiness.committedToken.utf8)
        )

        _ = PhiUninstallProcessWaiter.waitUntil(timeout: nil) {
            PhiUninstallProcessWaiter.isProcessRunning(plan.hostProcessID)
        }

        guard runningApplications(bundleID: plan.channel.browserBundleID).isEmpty else {
            throw PhiUninstallerMainError.browserStillRunning(plan.channel.browserBundleID)
        }
        guard PhiUninstallProcessWaiter.waitUntil(timeout: sentinelExitTimeout, isRunning: {
            !runningApplications(bundleID: plan.channel.sentinelBundleID).isEmpty
        }) else {
            throw PhiUninstallerMainError.sentinelDidNotExit(plan.channel.sentinelBundleID)
        }

        let chatShimID = PhiChatUninstallIdentity.shimBundleIdentifier(
            browserBundleIdentifier: plan.channel.browserBundleID
        )
        terminateRunningApplications(bundleID: chatShimID)
        guard PhiUninstallProcessWaiter.waitUntil(timeout: sentinelExitTimeout, isRunning: {
            !runningApplications(bundleID: chatShimID).isEmpty
        }) else {
            throw PhiUninstallerMainError.chatShimDidNotExit(chatShimID)
        }

        guard PhiUninstallSignatureVerifier.verifyAppBundle(
            at: plan.appBundleURL,
            expectedBundleID: plan.channel.browserBundleID
        ) else {
            throw PhiUninstallerMainError.invalidAppSignature(plan.appBundleURL)
        }

        let executor = PhiUninstallDeletionExecutor(
            allowlist: allowlist,
            logger: { message in
                writePhiUninstallerLog(message)
            }
        )
        var failures = executor.execute(dataPlan)

        if runningApplications(bundleID: plan.channel.browserBundleID).isEmpty {
            failures.append(contentsOf: executor.execute(appBundlePlan))
        } else {
            failures.append(
                "Skipped app-bundle deletion because Phi restarted for "
                + plan.channel.browserBundleID
            )
        }
        if !failures.isEmpty {
            throw PhiUninstallerMainError.deletionFailures(failures)
        }
    }

    static func loadPlan(at planURL: URL) throws -> PhiUninstallPlan {
        guard FileManager.default.fileExists(atPath: planURL.path) else {
            throw PhiUninstallerMainError.missingPlan(planURL)
        }
        return try JSONDecoder().decode(
            PhiUninstallPlan.self,
            from: Data(contentsOf: planURL)
        )
    }

    private static func runningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
    }

    private static func terminateRunningApplications(bundleID: String) {
        for application in runningApplications(bundleID: bundleID) {
            application.terminate()
            writePhiUninstallerLog("Requested termination of \(bundleID) pid=\(application.processIdentifier)")
        }
    }

    private static func value(after flag: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw PhiUninstallerMainError.missingValue(flag)
        }
        return arguments[valueIndex]
    }
}
