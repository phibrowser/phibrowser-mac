// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#if ATHENA_CANARY_TRIAL
import Foundation

enum AthenaCanaryInstaller {
    static let identifier = "com.phibrowser.canary.athena"
    private static let appName = "Athena Canary.app"

    static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var candidateURLs: [URL] {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return [installURL, applications.appendingPathComponent(appName, isDirectory: true),
                applications.appendingPathComponent("Phi Athena Canary Trial").appendingPathComponent(appName, isDirectory: true),
                Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(appName, isDirectory: true)]
    }

    private static func verified(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) &&
            AgentPeerIdentity.verifiesCompanion(at: url, identifier: identifier)
    }

    static func prepare(bundle: Bundle = .main, candidates: [URL] = candidateURLs,
                        destination: URL = installURL) throws -> URL {
        if let installed = candidates.first(where: verified) { return installed }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: destination])
        }
        guard let archive = bundle.url(forResource: "Athena Canary", withExtension: "zip"),
              let digest = bundle.object(forInfoDictionaryKey: "PhiAthenaPackageSHA256") as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        guard try FileSystemUtils.sha256Hex(for: archive) == digest else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? files.removeItem(at: stage) }
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", archive.path, stage.path]
        try extract.run()
        extract.waitUntilExit()
        let staged = stage.appendingPathComponent(appName, isDirectory: true)
        guard extract.terminationStatus == 0, verified(staged) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        // Publish only the complete bundle. Another installer may have won the race.
        if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let error = POSIXErrorCode(rawValue: errno) ?? .EIO
            guard error == .EEXIST, verified(destination) else { throw POSIXError(error) }
        }
        return destination
    }
}
#endif
