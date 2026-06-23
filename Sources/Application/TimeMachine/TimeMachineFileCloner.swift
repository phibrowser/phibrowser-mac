// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

enum TimeMachineFileClonerError: Error, LocalizedError {
    case unsupportedFileType(URL)
    case unresolvedFileSystemPath(URL)
    case cloneFailed(source: URL, destination: URL, errnoCode: Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let url):
            return "Unsupported Time Machine file type at \(url.path)"
        case .unresolvedFileSystemPath(let url):
            return "Unable to resolve file-system path for \(url.path)"
        case .cloneFailed(let source, let destination, let errnoCode):
            return "Failed to clone \(source.path) to \(destination.path): errno \(errnoCode)"
        }
    }
}

struct TimeMachineFileCloner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        if let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: sourceURL.path) {
            try copySymbolicLink(destination: linkDestination, to: destinationURL)
            return
        }

        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if resourceValues.isDirectory == true {
            try copyDirectory(at: sourceURL, to: destinationURL)
            return
        }

        if resourceValues.isRegularFile == true {
            try copyRegularFile(at: sourceURL, to: destinationURL)
            return
        }

        throw TimeMachineFileClonerError.unsupportedFileType(sourceURL)
    }

    private func copyDirectory(at sourceURL: URL, to destinationURL: URL) throws {
        try createParentDirectory(for: destinationURL)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)

        let childURLs = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )

        for childURL in childURLs {
            try copyItem(
                at: childURL,
                to: destinationURL.appendingPathComponent(childURL.lastPathComponent)
            )
        }
    }

    private func copySymbolicLink(destination linkDestination: String, to destinationURL: URL) throws {
        try createParentDirectory(for: destinationURL)
        try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: linkDestination)
    }

    private func copyRegularFile(at sourceURL: URL, to destinationURL: URL) throws {
        try createParentDirectory(for: destinationURL)

        let errnoCode = cloneRegularFile(at: sourceURL, to: destinationURL)
        if errnoCode == 0 {
            return
        }

        guard shouldFallbackToRegularCopy(errnoCode: errnoCode) else {
            throw TimeMachineFileClonerError.cloneFailed(
                source: sourceURL,
                destination: destinationURL,
                errnoCode: errnoCode
            )
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func cloneRegularFile(at sourceURL: URL, to destinationURL: URL) -> Int32 {
        sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else {
                return EINVAL
            }

            return destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else {
                    return EINVAL
                }

                if clonefile(sourcePath, destinationPath, 0) == 0 {
                    return 0
                }

                return errno
            }
        }
    }

    private func shouldFallbackToRegularCopy(errnoCode: Int32) -> Bool {
        switch errnoCode {
        case EXDEV, ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL:
            return true
        default:
            return false
        }
    }

    private func createParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
