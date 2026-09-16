// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import Security

enum PhiUninstallChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case canary
    case dev

    static func from(browserBundleID: String) -> PhiUninstallChannel? {
        switch browserBundleID.lowercased() {
        case "com.phibrowser.mac":
            return .stable
        case "com.phibrowser.canary.mac":
            return .canary
        case "com.phibrowser.dev.mac":
            return .dev
        default:
            return nil
        }
    }

    var browserBundleID: String {
        switch self {
        case .stable:
            return "com.phibrowser.Mac"
        case .canary:
            return "com.phibrowser.canary.Mac"
        case .dev:
            return "com.phibrowser.dev.Mac"
        }
    }

    var sentinelBundleID: String {
        switch self {
        case .stable:
            return "com.phibrowser.Sentinel"
        case .canary:
            return "com.phibrowser.canary.Sentinel"
        case .dev:
            return "com.phibrowser.dev.Sentinel"
        }
    }
}

enum PhiChatUninstallIdentity {
    static let appID = "hagekpigdlbdgnimipikmpccaogpnimp"

    static func shimBundleIdentifier(browserBundleIdentifier: String) -> String {
        "\(browserBundleIdentifier).app.\(appID)"
    }
}

struct PhiUninstallPaths: Equatable, Sendable {
    let applicationSupport: URL
    let caches: URL
    let preferences: URL
    let webKit: URL
    let httpStorages: URL
    let logs: URL

    init(
        applicationSupport: URL,
        caches: URL,
        preferences: URL? = nil,
        webKit: URL? = nil,
        httpStorages: URL? = nil,
        logs: URL? = nil
    ) {
        let library = applicationSupport.deletingLastPathComponent()
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.preferences = preferences
            ?? library.appendingPathComponent("Preferences", isDirectory: true)
        self.webKit = webKit
            ?? library.appendingPathComponent("WebKit", isDirectory: true)
        self.httpStorages = httpStorages
            ?? library.appendingPathComponent("HTTPStorages", isDirectory: true)
        self.logs = logs
            ?? library.appendingPathComponent("Logs", isDirectory: true)
    }

    static func standard(fileManager: FileManager = .default) -> PhiUninstallPaths {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return PhiUninstallPaths(applicationSupport: applicationSupport, caches: caches)
    }

    func browserApplicationSupport(_ channel: PhiUninstallChannel) -> URL {
        applicationSupport.appendingPathComponent(channel.browserBundleID, isDirectory: true)
    }

    func browserCaches(_ channel: PhiUninstallChannel) -> URL {
        caches.appendingPathComponent(channel.browserBundleID, isDirectory: true)
    }

    func sentinelApplicationSupport(_ channel: PhiUninstallChannel) -> URL {
        applicationSupport.appendingPathComponent(channel.sentinelBundleID, isDirectory: true)
    }

    func sentinelCaches(_ channel: PhiUninstallChannel) -> URL {
        caches.appendingPathComponent(channel.sentinelBundleID, isDirectory: true)
    }

    func browserPreferences(_ channel: PhiUninstallChannel) -> URL {
        preferences.appendingPathComponent("\(channel.browserBundleID).plist", isDirectory: false)
    }

    func sentinelPreferences(_ channel: PhiUninstallChannel) -> URL {
        preferences.appendingPathComponent("\(channel.sentinelBundleID).plist", isDirectory: false)
    }

    func browserWebKit(_ channel: PhiUninstallChannel) -> URL {
        webKit.appendingPathComponent(channel.browserBundleID, isDirectory: true)
    }

    func sentinelWebKit(_ channel: PhiUninstallChannel) -> URL {
        webKit.appendingPathComponent(channel.sentinelBundleID, isDirectory: true)
    }

    func browserHTTPStorage(_ channel: PhiUninstallChannel) -> URL {
        httpStorages.appendingPathComponent(channel.browserBundleID, isDirectory: true)
    }

    func sentinelHTTPStorage(_ channel: PhiUninstallChannel) -> URL {
        httpStorages.appendingPathComponent(channel.sentinelBundleID, isDirectory: true)
    }

    func browserHTTPCookies(_ channel: PhiUninstallChannel) -> URL {
        httpStorages.appendingPathComponent("\(channel.browserBundleID).binarycookies", isDirectory: false)
    }

    func sentinelHTTPCookies(_ channel: PhiUninstallChannel) -> URL {
        httpStorages.appendingPathComponent("\(channel.sentinelBundleID).binarycookies", isDirectory: false)
    }

    func browserTimeMachine(_ channel: PhiUninstallChannel) -> URL {
        applicationSupport
            .appendingPathComponent("com.phibrowser.TimeMachine", isDirectory: true)
            .appendingPathComponent(channel.browserBundleID, isDirectory: true)
    }

    func sentinelTimeMachine(_ channel: PhiUninstallChannel) -> URL {
        applicationSupport
            .appendingPathComponent("com.phibrowser.sentinel.TimeMachine", isDirectory: true)
            .appendingPathComponent(channel.sentinelBundleID, isDirectory: true)
    }

    func sentinelLogs(_ channel: PhiUninstallChannel) -> URL {
        let directoryName: String
        switch channel {
        case .stable:
            directoryName = "PhiSentinel"
        case .canary:
            directoryName = "PhiSentinel-Canary"
        case .dev:
            directoryName = "PhiSentinel-Dev"
        }
        return logs.appendingPathComponent(directoryName, isDirectory: true)
    }
}

struct PhiUninstallPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let hostProcessID: Int32
    let channel: PhiUninstallChannel
    let appBundleURL: URL
    let chatShimBundleURL: URL?

    init(
        schemaVersion: Int = currentSchemaVersion,
        hostProcessID: Int32,
        channel: PhiUninstallChannel,
        appBundleURL: URL,
        chatShimBundleURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.hostProcessID = hostProcessID
        self.channel = channel
        self.appBundleURL = appBundleURL
        self.chatShimBundleURL = chatShimBundleURL
    }
}

enum PhiUninstallReadiness {
    static let readyToken = "PHI_UNINSTALLER_READY_V1\n"
    static let commitToken = "PHI_UNINSTALLER_COMMIT_V1\n"
    static let committedToken = "PHI_UNINSTALLER_COMMITTED_V1\n"
    static let timeout: TimeInterval = 10

    static func isValidCommitSignal(_ data: Data?) -> Bool {
        data == Data(commitToken.utf8)
    }
}

enum PhiUninstallWorkspaceError: Error, Equatable, LocalizedError {
    case unsafeWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .unsafeWorkspace(let reason):
            return "The prepared Phi uninstaller workspace is unsafe: \(reason)."
        }
    }
}

struct PhiUninstallPreparedWorkspace: Equatable, Sendable {
    static let directoryPrefix = "com.phibrowser.uninstall-"
    static let helperFilename = "PhiUninstaller"
    static let planFilename = "uninstall-plan.json"

    let directoryURL: URL
    let executableURL: URL
    let planURL: URL

    static func validate(
        planURL: URL,
        executableURL: URL,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        expectedOwnerID: uid_t = getuid()
    ) throws -> PhiUninstallPreparedWorkspace {
        let planURL = planURL.standardizedFileURL
        let executableURL = executableURL.standardizedFileURL
        let directoryURL = planURL.deletingLastPathComponent()
        let temporaryDirectoryURL = temporaryDirectoryURL.standardizedFileURL

        guard planURL.lastPathComponent == planFilename else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace("unexpected plan filename")
        }
        guard executableURL.lastPathComponent == helperFilename else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace("unexpected helper filename")
        }
        guard executableURL.deletingLastPathComponent() == directoryURL else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace(
                "the plan and helper are not in the same directory"
            )
        }
        guard directoryURL.deletingLastPathComponent() == temporaryDirectoryURL,
              directoryURL.resolvingSymlinksInPath().deletingLastPathComponent()
                == temporaryDirectoryURL.resolvingSymlinksInPath() else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace(
                "the helper directory is outside the trusted temporary directory"
            )
        }

        let directoryName = directoryURL.lastPathComponent
        guard directoryName.hasPrefix(directoryPrefix),
              UUID(uuidString: String(directoryName.dropFirst(directoryPrefix.count))) != nil else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace("unexpected helper directory name")
        }

        try requireItem(
            at: directoryURL,
            kind: .directory,
            permissions: 0o700,
            ownerID: expectedOwnerID,
            fileManager: fileManager
        )
        try requireItem(
            at: executableURL,
            kind: .regularFile,
            permissions: 0o755,
            ownerID: expectedOwnerID,
            fileManager: fileManager
        )
        try requireItem(
            at: planURL,
            kind: .regularFile,
            permissions: 0o600,
            ownerID: expectedOwnerID,
            fileManager: fileManager
        )
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace("the helper is not executable")
        }

        return PhiUninstallPreparedWorkspace(
            directoryURL: directoryURL,
            executableURL: executableURL,
            planURL: planURL
        )
    }

    private enum ItemKind {
        case directory
        case regularFile
    }

    private static func requireItem(
        at url: URL,
        kind: ItemKind,
        permissions: Int,
        ownerID: uid_t,
        fileManager: FileManager
    ) throws {
        let resourceValues = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard resourceValues.isSymbolicLink != true else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace(
                "a workspace item is a symbolic link: \(url.path)"
            )
        }
        switch kind {
        case .directory:
            guard resourceValues.isDirectory == true else {
                throw PhiUninstallWorkspaceError.unsafeWorkspace(
                    "the workspace directory is not a directory"
                )
            }
        case .regularFile:
            guard resourceValues.isRegularFile == true else {
                throw PhiUninstallWorkspaceError.unsafeWorkspace(
                    "a workspace file is not a regular file: \(url.path)"
                )
            }
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualOwnerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard actualOwnerID == ownerID else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace(
                "unexpected owner for \(url.path)"
            )
        }
        let actualPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard actualPermissions == permissions else {
            throw PhiUninstallWorkspaceError.unsafeWorkspace(
                "unexpected permissions for \(url.path)"
            )
        }
    }
}

enum PhiUninstallStep: Equatable, Sendable {
    case deleteTree(URL)
    case deletePreferences(domain: String, plistURL: URL)
}

struct PhiUninstallDeletionPlan: Equatable, Sendable {
    let steps: [PhiUninstallStep]
}

struct PhiUninstallPlanner {
    let paths: PhiUninstallPaths
    let channel: PhiUninstallChannel
    let appBundleURL: URL
    let chatShimBundleURL: URL?

    init(paths: PhiUninstallPaths, channel: PhiUninstallChannel, appBundleURL: URL,
         chatShimBundleURL: URL? = nil) {
        self.paths = paths
        self.channel = channel
        self.appBundleURL = appBundleURL
        self.chatShimBundleURL = chatShimBundleURL
    }

    func planAllData() -> PhiUninstallDeletionPlan {
        PhiUninstallDeletionPlan(steps: [
            .deleteTree(paths.browserApplicationSupport(channel)),
            .deleteTree(paths.browserCaches(channel)),
            .deleteTree(paths.sentinelApplicationSupport(channel)),
            .deleteTree(paths.sentinelCaches(channel)),
            .deletePreferences(
                domain: channel.browserBundleID,
                plistURL: paths.browserPreferences(channel)
            ),
            .deletePreferences(
                domain: channel.sentinelBundleID,
                plistURL: paths.sentinelPreferences(channel)
            ),
            .deleteTree(paths.browserWebKit(channel)),
            .deleteTree(paths.sentinelWebKit(channel)),
            .deleteTree(paths.browserHTTPStorage(channel)),
            .deleteTree(paths.browserHTTPCookies(channel)),
            .deleteTree(paths.sentinelHTTPStorage(channel)),
            .deleteTree(paths.sentinelHTTPCookies(channel)),
            .deleteTree(paths.browserTimeMachine(channel)),
            .deleteTree(paths.sentinelTimeMachine(channel)),
            .deleteTree(paths.sentinelLogs(.stable)),
            .deleteTree(paths.sentinelLogs(.canary)),
            .deleteTree(paths.sentinelLogs(.dev)),
        ])
    }

    func planAppBundleRemoval() -> PhiUninstallDeletionPlan {
        var steps: [PhiUninstallStep] = [.deleteTree(appBundleURL)]
        if let chatShimBundleURL {
            steps.append(.deleteTree(chatShimBundleURL))
        }
        return PhiUninstallDeletionPlan(steps: steps)
    }
}

enum PhiUninstallSafetyError: Error, Equatable {
    case dangerousPath(String)
    case pathNotAllowed(String)
    case appBundleOverlapsDataPath(appBundle: String, dataPath: String)
}

struct PhiUninstallPathAllowlist: Sendable {
    let paths: PhiUninstallPaths
    let channel: PhiUninstallChannel
    let appBundleURL: URL
    let chatShimBundleURL: URL?

    init(paths: PhiUninstallPaths, channel: PhiUninstallChannel, appBundleURL: URL,
         chatShimBundleURL: URL? = nil) {
        self.paths = paths
        self.channel = channel
        self.appBundleURL = appBundleURL
        self.chatShimBundleURL = chatShimBundleURL
    }

    private var directoryRoots: [URL] {
        [
            paths.browserApplicationSupport(channel),
            paths.browserCaches(channel),
            paths.sentinelApplicationSupport(channel),
            paths.sentinelCaches(channel),
            paths.browserWebKit(channel),
            paths.sentinelWebKit(channel),
            paths.browserHTTPStorage(channel),
            paths.sentinelHTTPStorage(channel),
            paths.browserTimeMachine(channel),
            paths.sentinelTimeMachine(channel),
            paths.sentinelLogs(.stable),
            paths.sentinelLogs(.canary),
            paths.sentinelLogs(.dev),
        ]
    }

    private var exactFiles: [URL] {
        [
            paths.browserPreferences(channel),
            paths.sentinelPreferences(channel),
            paths.browserHTTPCookies(channel),
            paths.sentinelHTTPCookies(channel),
        ]
    }

    private var preferencesTargets: [String: URL] {
        [
            channel.browserBundleID: paths.browserPreferences(channel),
            channel.sentinelBundleID: paths.sentinelPreferences(channel),
        ]
    }

    private var dangerousPaths: Set<String> {
        let library = paths.applicationSupport.deletingLastPathComponent().standardizedFileURL.path
        return [
            "/",
            paths.applicationSupport.standardizedFileURL.path,
            paths.caches.standardizedFileURL.path,
            paths.preferences.standardizedFileURL.path,
            paths.webKit.standardizedFileURL.path,
            paths.httpStorages.standardizedFileURL.path,
            paths.logs.standardizedFileURL.path,
            library,
            paths.applicationSupport.deletingLastPathComponent()
                .deletingLastPathComponent().standardizedFileURL.path,
        ]
    }

    func isAllowed(_ url: URL) -> Bool {
        isAllowed(
            url,
            roots: directoryRoots,
            exactFiles: exactFiles,
            appBundleURLs: [appBundleURL, chatShimBundleURL].compactMap { $0 },
            resolveSymlinks: false
        )
    }

    func isAllowedResolvingSymlinks(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        let resolvedURL = normalized(url, resolveSymlinks: true)
        return isAllowed(
            resolvedURL,
            roots: directoryRoots,
            exactFiles: exactFiles,
            appBundleURLs: [appBundleURL, chatShimBundleURL].compactMap { $0 },
            resolveSymlinks: false
        )
    }

    func isAllowed(_ step: PhiUninstallStep) -> Bool {
        switch step {
        case .deleteTree(let url):
            return isAllowed(url)
        case .deletePreferences(let domain, let plistURL):
            guard let expectedURL = preferencesTargets[domain] else { return false }
            return plistURL.standardizedFileURL == expectedURL.standardizedFileURL
                && isAllowed(plistURL)
        }
    }

    func validate(_ plan: PhiUninstallDeletionPlan) throws {
        for step in plan.steps {
            switch step {
            case .deleteTree(let url):
                try validate(url)
            case .deletePreferences(_, let plistURL):
                try validate(plistURL)
                guard isAllowed(step) else {
                    throw PhiUninstallSafetyError.pathNotAllowed(plistURL.standardizedFileURL.path)
                }
            }
        }
    }

    func validateAppBundleIsDisjoint(from dataPlan: PhiUninstallDeletionPlan) throws {
        for step in dataPlan.steps {
            let dataURL: URL
            switch step {
            case .deleteTree(let url):
                dataURL = url
            case .deletePreferences(_, let plistURL):
                dataURL = plistURL
            }

            if pathsOverlap(appBundleURL, dataURL, resolveSymlinks: false)
                || pathsOverlap(appBundleURL, dataURL, resolveSymlinks: true) {
                throw PhiUninstallSafetyError.appBundleOverlapsDataPath(
                    appBundle: appBundleURL.standardizedFileURL.path,
                    dataPath: dataURL.standardizedFileURL.path
                )
            }
        }
    }

    private func validate(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if dangerousPaths.contains(path) {
            throw PhiUninstallSafetyError.dangerousPath(path)
        }
        guard isAllowed(url) else {
            throw PhiUninstallSafetyError.pathNotAllowed(path)
        }
    }

    private func isAllowed(
        _ url: URL,
        roots: [URL],
        exactFiles: [URL],
        appBundleURLs: [URL],
        resolveSymlinks: Bool
    ) -> Bool {
        let normalizedURL = normalized(url, resolveSymlinks: resolveSymlinks)
        let path = normalizedURL.path
        if appBundleURLs.contains(where: {
            let normalizedURL = normalized($0, resolveSymlinks: resolveSymlinks)
            return path == normalizedURL.path && normalizedURL.pathExtension == "app"
        }) {
            return true
        }

        if exactFiles.contains(where: {
            normalized($0, resolveSymlinks: resolveSymlinks).path == path
        }) {
            return true
        }

        for root in roots {
            let rootPath = normalized(root, resolveSymlinks: resolveSymlinks).path
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                return true
            }
        }
        return false
    }

    private func normalized(_ url: URL, resolveSymlinks: Bool) -> URL {
        let standardized = url.standardizedFileURL
        return resolveSymlinks ? standardized.resolvingSymlinksInPath() : standardized
    }

    private func pathsOverlap(_ lhs: URL, _ rhs: URL, resolveSymlinks: Bool) -> Bool {
        let lhsPath = normalized(lhs, resolveSymlinks: resolveSymlinks).path
        let rhsPath = normalized(rhs, resolveSymlinks: resolveSymlinks).path
        return lhsPath == rhsPath
            || lhsPath.hasPrefix(rhsPath + "/")
            || rhsPath.hasPrefix(lhsPath + "/")
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }
}

struct PhiUninstallDeletionExecutor {
    typealias Logger = (String) -> Void
    typealias PreferencesDomainRemover = (String) -> Void

    let allowlist: PhiUninstallPathAllowlist
    var fileManager: FileManager = .default
    var logger: Logger = { _ in }
    var preferencesDomainRemover: PreferencesDomainRemover = {
        UserDefaults.standard.removePersistentDomain(forName: $0)
    }

    func execute(_ plan: PhiUninstallDeletionPlan) -> [String] {
        var failures: [String] = []
        for step in plan.steps {
            guard allowlist.isAllowed(step) else {
                failures.append("Refused non-allowlisted uninstall step: \(step)")
                continue
            }

            switch step {
            case .deleteTree(let url):
                remove(url, failures: &failures)
            case .deletePreferences(let domain, let plistURL):
                preferencesDomainRemover(domain)
                logger("Removed preferences domain \(domain)")
                remove(plistURL, failures: &failures)
            }
        }
        return failures
    }

    private func remove(_ url: URL, failures: inout [String]) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard allowlist.isAllowedResolvingSymlinks(url) else {
            failures.append("Refused symlink or escaping path: \(url.path)")
            return
        }
        do {
            try fileManager.removeItem(at: url)
            logger("Removed \(url.path)")
        } catch {
            failures.append("Failed \(url.path): \(error.localizedDescription)")
        }
    }
}

enum PhiUninstallProcessWaiter {
    static func waitUntil(
        timeout: TimeInterval?,
        pollInterval: TimeInterval = 0.1,
        isRunning: () -> Bool
    ) -> Bool {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while isRunning() {
            if let deadline, Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return true
    }

    static func isProcessRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
