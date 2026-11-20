// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

@main
struct TimeMachineDirectoryEnumerationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let manager = FileManager.default
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.test")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID()
        let snapshot = paths.snapshotURL(id: id)
        let directory = snapshot.appendingPathComponent("nested/files", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Short records fill multiple readdir buffers. Guard Malloc catches a
        // whole-dirent copy when a record is near the end of one of those buffers.
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        precondition(descriptor >= 0)
        defer { close(descriptor) }
        let names = (0..<4_096).map { "file-\($0)" } + [
            String(repeating: "x", count: 255), "caf\u{00e9}-\u{1f4be}"
        ]
        for name in names {
            let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            precondition(file >= 0, "Could not create fixture: \(errno)")
            var byte: UInt8 = 1
            precondition(write(file, &byte, 1) == 1)
            close(file)
        }

        let record = TimeMachineBackupRecord(
            id: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000), creatingVersion: "2.17.0", creatingBuild: 979,
            backupTriggerBuild: 600, rollbackVersion: "1.6.0", rollbackBuild: 590,
            rollbackPackageURL: URL(string: "https://example.com/Phi.zip")!,
            rollbackPackageSHA256: "fixture", includeChromiumData: true,
            snapshotRelativePath: paths.relativePath(for: snapshot), status: .completed
        )
        try store.save(TimeMachineCatalog(backups: [record]))

        if CommandLine.arguments[2] == "measure" {
            let size = try store.resolveSnapshotSizeBytes(id: id)
            precondition(size == UInt64(names.count), "Enumeration lost or changed a filename")
            print("PASS large-directory size measurement")
            return
        }

        let external = root.appendingPathComponent("external", isDirectory: true)
        try manager.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("keep.bin")
        try Data([42]).write(to: sentinel)
        try manager.createSymbolicLink(at: directory.appendingPathComponent("outside"), withDestinationURL: external)

        if CommandLine.arguments[2] == "resume" {
            let purging = paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).purging")
            try manager.moveItem(at: snapshot, to: purging)
            try store.save(TimeMachineCatalog())
            try store.purgeCommittedDeletionTombstones()
            precondition(!manager.fileExists(atPath: purging.path), "Interrupted purge was not completed")
        } else {
            let deleted = try store.deleteBackup(id: id)
            precondition(deleted == record)
        }

        let catalog = try store.load()
        let remaining = try manager.contentsOfDirectory(atPath: paths.snapshotsRootURL.path)
        let sentinelData = try Data(contentsOf: sentinel)
        precondition(catalog.backups.isEmpty && remaining.isEmpty, "Snapshot or catalog entry survived deletion")
        precondition(sentinelData == Data([42]), "Deletion followed an external symlink")
        print("PASS large-directory \(CommandLine.arguments[2]) with long and Unicode names; external symlink target preserved")
    }
}
