// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

enum TimeMachinePackageDownloaderError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case sha256Mismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid Time Machine package download response."
        case .httpError(let statusCode):
            return "Time Machine package download failed with HTTP status \(statusCode)."
        case .sha256Mismatch(let expected, let actual):
            return "Time Machine package SHA-256 mismatch. Expected \(expected), got \(actual)."
        }
    }
}

struct TimeMachinePackageDownloader {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func downloadPackage(from sourceURL: URL, expectedSHA256: String, to destinationURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: sourceURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw TimeMachinePackageDownloaderError.httpError(httpResponse.statusCode)
        } else if response as? HTTPURLResponse == nil, !sourceURL.isFileURL {
            throw TimeMachinePackageDownloaderError.invalidResponse
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        do {
            try Self.verifySHA256(fileURL: destinationURL, expectedSHA256: expectedSHA256)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        return destinationURL
    }

    static func verifySHA256(fileURL: URL, expectedSHA256: String) throws {
        let expected = normalizeSHA256(expectedSHA256)
        let actual = try sha256Hex(for: fileURL)
        guard expected == actual else {
            throw TimeMachinePackageDownloaderError.sha256Mismatch(expected: expected, actual: actual)
        }
    }

    static func sha256Hex(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeSHA256(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
