// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

enum TimeMachineCatalogStoreError: Error, LocalizedError {
    case invalidSnapshotPath(String)
    case unsafeManagedDirectory(path: String, errnoCode: Int32)
    case managedSnapshotOperationFailed(operation: String, entry: String, errnoCode: Int32)
    case conflictingSnapshotEntries(UUID)
    case snapshotStillCataloged(UUID)
    case deletionRollbackFailed(catalogError: Error, rollbackError: Error)

    var errorDescription: String? {
        switch self {
        case .invalidSnapshotPath(let relativePath):
            return "Invalid Time Machine snapshot path: \(relativePath)"
        case .unsafeManagedDirectory(let path, let errnoCode):
            return "Could not safely open the managed Time Machine directory at \(path): errno \(errnoCode)"
        case .managedSnapshotOperationFailed(let operation, let entry, let errnoCode):
            return "Time Machine snapshot operation \(operation) failed for \(entry): errno \(errnoCode)"
        case .conflictingSnapshotEntries(let backupID):
            return "Both active and deletion-pending Time Machine snapshots exist for \(backupID.uuidString)"
        case .snapshotStillCataloged(let backupID):
            return "Refusing to delete Time Machine snapshot \(backupID.uuidString) without updating its catalog record"
        case .deletionRollbackFailed(let catalogError, let rollbackError):
            return "Time Machine catalog update failed and the backup could not be restored to its original location: "
                + "\(catalogError.localizedDescription); rollback: \(rollbackError.localizedDescription)"
        }
    }
}

struct TimeMachineCatalogStore {
    typealias CatalogWriter = (_ data: Data, _ catalogURL: URL) throws -> Void

    private static let lock = NSRecursiveLock()

    private let paths: TimeMachinePaths
    private let fileManager: FileManager
    private let catalogWriter: CatalogWriter

    init(
        paths: TimeMachinePaths = TimeMachinePaths(),
        fileManager: FileManager = .default,
        catalogWriter: @escaping CatalogWriter = { data, catalogURL in
            try data.write(to: catalogURL, options: .atomic)
        }
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.catalogWriter = catalogWriter
    }

    /// Reconciles interrupted backup deletions before returning catalog data.
    func load() throws -> TimeMachineCatalog {
        try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            return catalog
        }
    }

    func save(_ catalog: TimeMachineCatalog) throws {
        try withCatalogLock(createRootIfNeeded: true) { _ in
            try saveWithoutLock(catalog)
        }
    }

    func appendCompletedBackup(_ record: TimeMachineBackupRecord) throws {
        try withCatalogLock(createRootIfNeeded: true) { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            catalog.backups.removeAll { $0.id == record.id }
            catalog.backups.append(record)
            try saveWithoutLock(catalog)
        }
    }

    @discardableResult
    func updateSnapshotSizeBytes(id: UUID, sizeBytes: UInt64) throws -> TimeMachineBackupRecord? {
        try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            catalog.backups[index].snapshotSizeBytes = sizeBytes
            let record = catalog.backups[index]
            try saveWithoutLock(catalog)
            return record
        }
    }

    func snapshotSizeBytes(for record: TimeMachineBackupRecord) throws -> UInt64? {
        try withCatalogLock { snapshotsDirectory in
            let snapshotName = try managedSnapshotName(for: record)
            guard let snapshotsDirectory,
                  try snapshotsDirectory.entryExists(snapshotName) else {
                return nil
            }
            return record.snapshotSizeBytes
        }
    }

    @discardableResult
    func deleteBackup(id: UUID) throws -> TimeMachineBackupRecord? {
        try deleteBackup(id: id, retainDeletionMarker: false)
    }

    @discardableResult
    func deleteBackupAtUserRequest(id: UUID) throws -> TimeMachineBackupRecord? {
        try deleteBackup(id: id, retainDeletionMarker: true)
    }

    private func deleteBackup(
        id: UUID,
        retainDeletionMarker: Bool
    ) throws -> TimeMachineBackupRecord? {
        let outcome: (record: TimeMachineBackupRecord?, purgingName: POSIXFileName?) = try withCatalogLock {
            snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.id == id }) else {
                return (nil, nil)
            }

            let record = catalog.backups[index]
            let snapshotName = try managedSnapshotName(for: record)
            let deletionName = Self.deletionName(for: record.id)
            let quarantined = try snapshotsDirectory?.renameIfExists(
                from: snapshotName,
                to: deletionName
            ) ?? false

            if retainDeletionMarker {
                let trigger = TimeMachineSuppressedBackupTrigger(
                    backupTriggerBuild: record.backupTriggerBuild,
                    creatingVersion: record.creatingVersion
                )
                catalog.suppressedBackupTriggers.removeAll { $0 == trigger }
                catalog.suppressedBackupTriggers.append(trigger)
            }
            catalog.backups.remove(at: index)
            do {
                try saveWithoutLock(catalog)
            } catch {
                guard quarantined, let snapshotsDirectory else {
                    throw error
                }
                do {
                    _ = try snapshotsDirectory.renameIfExists(from: deletionName, to: snapshotName)
                } catch let rollbackError {
                    throw TimeMachineCatalogStoreError.deletionRollbackFailed(
                        catalogError: error,
                        rollbackError: rollbackError
                    )
                }
                throw error
            }

            var purgingName: POSIXFileName?
            if quarantined {
                let candidate = Self.purgingName(for: record.id)
                do {
                    if try snapshotsDirectory?.renameIfExists(from: deletionName, to: candidate) == true {
                        purgingName = candidate
                    }
                } catch {
                    // The catalog commit is authoritative. Startup maintenance retries disk cleanup.
                }
            }
            return (record, purgingName)
        }

        if let purgingName = outcome.purgingName {
            do {
                try removePurgingEntryIfExists(purgingName)
            } catch {
                // The catalog commit is authoritative. Startup maintenance retries disk cleanup.
            }
        }
        return outcome.record
    }

    @discardableResult
    func deleteUncatalogedSnapshotIfExists(id: UUID) throws -> Bool {
        let purgingName: POSIXFileName? = try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            let expectedRelativePath = "\(TimeMachinePaths.snapshotsDirectoryName)/\(id.uuidString)"
            guard !catalog.backups.contains(where: {
                $0.id == id || $0.snapshotRelativePath == expectedRelativePath
            }) else {
                throw TimeMachineCatalogStoreError.snapshotStillCataloged(id)
            }

            guard let snapshotsDirectory else {
                return nil
            }
            let snapshotName = POSIXFileName(id.uuidString)
            let deletionName = Self.deletionName(for: id)
            let candidate = Self.purgingName(for: id)
            if try snapshotsDirectory.entryExists(candidate) {
                return candidate
            }
            if try snapshotsDirectory.entryExists(deletionName) {
                _ = try snapshotsDirectory.renameIfExists(from: deletionName, to: candidate)
                return candidate
            }
            guard try snapshotsDirectory.renameIfExists(from: snapshotName, to: deletionName) else {
                return nil
            }
            _ = try snapshotsDirectory.renameIfExists(from: deletionName, to: candidate)
            return candidate
        }

        guard let purgingName else {
            return false
        }
        try removePurgingEntryIfExists(purgingName)
        return true
    }

    func purgeCommittedDeletionTombstones() throws {
        let purgingNames: [POSIXFileName] = try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let snapshotsDirectory else {
                return []
            }

            let entries = try snapshotsDirectory.entryNames()
            var names = entries.filter {
                guard let backupID = Self.backupID(fromPurgingName: $0.string) else {
                    return false
                }
                return !catalog.backups.contains(where: { $0.id == backupID })
            }
            for deletionName in entries {
                guard let backupID = Self.backupID(fromDeletionName: deletionName.string),
                      !catalog.backups.contains(where: { $0.id == backupID }) else {
                    continue
                }
                let purgingName = Self.purgingName(for: backupID)
                if try snapshotsDirectory.entryExists(purgingName) {
                    continue
                }
                _ = try snapshotsDirectory.renameIfExists(from: deletionName, to: purgingName)
                names.append(purgingName)
            }
            return names
        }

        var firstError: Error?
        for purgingName in purgingNames {
            do {
                try removePurgingEntryIfExists(purgingName)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    @discardableResult
    func removeBackup(id: UUID) throws -> TimeMachineBackupRecord? {
        try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let record = catalog.backups.remove(at: index)
            try saveWithoutLock(catalog)
            return record
        }
    }

    @discardableResult
    func removeBackup(snapshotRelativePath: String) throws -> TimeMachineBackupRecord? {
        try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery()
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.snapshotRelativePath == snapshotRelativePath }) else {
                return nil
            }
            let record = catalog.backups.remove(at: index)
            try saveWithoutLock(catalog)
            return record
        }
    }

    private func loadWithoutRecovery() throws -> TimeMachineCatalog {
        guard fileManager.fileExists(atPath: paths.catalogURL.path) else {
            return TimeMachineCatalog()
        }

        let data = try Data(contentsOf: paths.catalogURL)
        return try Self.decoder.decode(TimeMachineCatalog.self, from: data)
    }

    private func saveWithoutLock(_ catalog: TimeMachineCatalog) throws {
        try fileManager.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(catalog)
        try catalogWriter(data, paths.catalogURL)
    }

    private func recoverInterruptedDeletions(
        catalog: inout TimeMachineCatalog,
        snapshotsDirectory: TimeMachineManagedSnapshotsDirectory?
    ) throws {
        guard let snapshotsDirectory else {
            return
        }

        for deletionName in try snapshotsDirectory.entryNames() {
            let backupID = Self.backupID(fromDeletionName: deletionName.string)
                ?? Self.backupID(fromPurgingName: deletionName.string)
            guard let backupID else {
                continue
            }

            let snapshotName = POSIXFileName(backupID.uuidString)
            if try snapshotsDirectory.entryExists(snapshotName) {
                throw TimeMachineCatalogStoreError.conflictingSnapshotEntries(backupID)
            }
            if let record = catalog.backups.first(where: { $0.id == backupID }) {
                _ = try managedSnapshotName(for: record)
                _ = try snapshotsDirectory.renameIfExists(from: deletionName, to: snapshotName)
            }
        }
    }

    private func removePurgingEntryIfExists(_ purgingName: POSIXFileName) throws {
        guard let snapshotsDirectory = try TimeMachineManagedSnapshotsDirectory.open(
            paths: paths,
            lockRoot: false
        ) else {
            return
        }
        try snapshotsDirectory.removeEntryIfExists(purgingName)
    }

    private func managedSnapshotName(for record: TimeMachineBackupRecord) throws -> POSIXFileName {
        let expectedRelativePath = "\(TimeMachinePaths.snapshotsDirectoryName)/\(record.id.uuidString)"
        guard record.snapshotRelativePath == expectedRelativePath else {
            throw TimeMachineCatalogStoreError.invalidSnapshotPath(record.snapshotRelativePath)
        }
        return POSIXFileName(record.id.uuidString)
    }

    private static func deletionName(for id: UUID) -> POSIXFileName {
        POSIXFileName("\(id.uuidString).deleting")
    }

    private static func purgingName(for id: UUID) -> POSIXFileName {
        POSIXFileName("\(id.uuidString).purging")
    }

    private static func backupID(fromDeletionName name: String) -> UUID? {
        backupID(fromManagedName: name, suffix: ".deleting")
    }

    private static func backupID(fromPurgingName name: String) -> UUID? {
        backupID(fromManagedName: name, suffix: ".purging")
    }

    private static func backupID(fromManagedName name: String, suffix: String) -> UUID? {
        guard name.hasSuffix(suffix) else {
            return nil
        }
        let idString = String(name.dropLast(suffix.count))
        guard let id = UUID(uuidString: idString), name == "\(id.uuidString)\(suffix)" else {
            return nil
        }
        return id
    }

    private func withCatalogLock<Result>(
        createRootIfNeeded: Bool = false,
        operation: (TimeMachineManagedSnapshotsDirectory?) throws -> Result
    ) throws -> Result {
        try Self.synchronized {
            if createRootIfNeeded {
                try fileManager.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
            }
            let snapshotsDirectory = try TimeMachineManagedSnapshotsDirectory.open(paths: paths)
            return try operation(snapshotsDirectory)
        }
    }

    private static func synchronized<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct POSIXFileName: Equatable {
    let bytes: [CChar]

    init(_ string: String) {
        bytes = Array(string.utf8CString)
    }

    init(directoryEntry: dirent) {
        let length = Int(directoryEntry.d_namlen)
        var entry = directoryEntry
        bytes = withUnsafePointer(to: &entry.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                Array(UnsafeBufferPointer(start: $0, count: length)) + [0]
            }
        }
    }

    var string: String {
        bytes.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
    }

    var isDotEntry: Bool {
        bytes == POSIXFileName(".").bytes || bytes == POSIXFileName("..").bytes
    }

    func withCString<Result>(_ operation: (UnsafePointer<CChar>) throws -> Result) rethrows -> Result {
        try bytes.withUnsafeBufferPointer { buffer in
            try operation(buffer.baseAddress!)
        }
    }
}

private final class TimeMachineManagedSnapshotsDirectory {
    private let rootDescriptor: Int32
    private let descriptor: Int32?
    private let deviceID: dev_t
    private let releasesRootLock: Bool

    private init(
        rootDescriptor: Int32,
        descriptor: Int32?,
        deviceID: dev_t,
        releasesRootLock: Bool
    ) {
        self.rootDescriptor = rootDescriptor
        self.descriptor = descriptor
        self.deviceID = deviceID
        self.releasesRootLock = releasesRootLock
    }

    deinit {
        if let descriptor {
            Darwin.close(descriptor)
        }
        if releasesRootLock {
            flock(rootDescriptor, LOCK_UN)
        }
        Darwin.close(rootDescriptor)
    }

    static func open(
        paths: TimeMachinePaths,
        lockRoot: Bool = true
    ) throws -> TimeMachineManagedSnapshotsDirectory? {
        let rootDescriptor = paths.rootURL.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
            guard let fileSystemPath else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(
                fileSystemPath,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard rootDescriptor >= 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return nil
            }
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.rootURL.path,
                errnoCode: errnoCode
            )
        }

        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0 else {
            let errnoCode = errno
            Darwin.close(rootDescriptor)
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.rootURL.path,
                errnoCode: errnoCode
            )
        }

        if lockRoot {
            var lockResult: Int32
            repeat {
                lockResult = flock(rootDescriptor, LOCK_EX)
            } while lockResult != 0 && errno == EINTR
            guard lockResult == 0 else {
                let errnoCode = errno
                Darwin.close(rootDescriptor)
                throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                    path: paths.rootURL.path,
                    errnoCode: errnoCode
                )
            }
        }

        let snapshotsName = POSIXFileName(TimeMachinePaths.snapshotsDirectoryName)
        let snapshotsDescriptor = snapshotsName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard snapshotsDescriptor >= 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return TimeMachineManagedSnapshotsDirectory(
                    rootDescriptor: rootDescriptor,
                    descriptor: nil,
                    deviceID: rootStatus.st_dev,
                    releasesRootLock: lockRoot
                )
            }
            if lockRoot {
                flock(rootDescriptor, LOCK_UN)
            }
            Darwin.close(rootDescriptor)
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.snapshotsRootURL.path,
                errnoCode: errnoCode
            )
        }

        var directoryStatus = stat()
        guard Darwin.fstat(snapshotsDescriptor, &directoryStatus) == 0 else {
            let errnoCode = errno
            Darwin.close(snapshotsDescriptor)
            if lockRoot {
                flock(rootDescriptor, LOCK_UN)
            }
            Darwin.close(rootDescriptor)
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.snapshotsRootURL.path,
                errnoCode: errnoCode
            )
        }
        guard directoryStatus.st_dev == rootStatus.st_dev else {
            Darwin.close(snapshotsDescriptor)
            if lockRoot {
                flock(rootDescriptor, LOCK_UN)
            }
            Darwin.close(rootDescriptor)
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.snapshotsRootURL.path,
                errnoCode: EXDEV
            )
        }
        return TimeMachineManagedSnapshotsDirectory(
            rootDescriptor: rootDescriptor,
            descriptor: snapshotsDescriptor,
            deviceID: directoryStatus.st_dev,
            releasesRootLock: lockRoot
        )
    }

    func entryNames() throws -> [POSIXFileName] {
        guard let descriptor else {
            return []
        }
        return try entryNames(in: descriptor, displayPath: TimeMachinePaths.snapshotsDirectoryName)
    }

    func entryExists(_ name: POSIXFileName) throws -> Bool {
        guard let descriptor else {
            return false
        }
        return try entryStatus(name, in: descriptor, displayPath: name.string) != nil
    }

    @discardableResult
    func renameIfExists(from source: POSIXFileName, to destination: POSIXFileName) throws -> Bool {
        guard let descriptor else {
            return false
        }
        let result = source.withCString { sourcePath in
            destination.withCString { destinationPath in
                Darwin.renameatx_np(
                    descriptor,
                    sourcePath,
                    descriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return false
            }
            throw operationError(
                operation: "rename",
                entry: "\(source.string) -> \(destination.string)",
                errnoCode: errnoCode
            )
        }
        return true
    }

    func removeEntryIfExists(_ name: POSIXFileName) throws {
        guard let descriptor else {
            return
        }
        try removeEntryIfExists(name, from: descriptor, displayPath: name.string)
    }

    private func removeEntryIfExists(
        _ name: POSIXFileName,
        from parentDescriptor: Int32,
        displayPath: String
    ) throws {
        guard let initialStatus = try entryStatus(name, in: parentDescriptor, displayPath: displayPath) else {
            return
        }

        guard initialStatus.st_mode & S_IFMT == S_IFDIR else {
            let result = name.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            guard result == 0 || errno == ENOENT else {
                throw operationError(operation: "unlink", entry: displayPath, errnoCode: errno)
            }
            return
        }

        guard initialStatus.st_dev == deviceID else {
            throw operationError(operation: "refuse-cross-device", entry: displayPath, errnoCode: EXDEV)
        }

        let childDescriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard childDescriptor >= 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return
            }
            throw operationError(operation: "open-directory", entry: displayPath, errnoCode: errnoCode)
        }
        defer { Darwin.close(childDescriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(childDescriptor, &openedStatus) == 0 else {
            throw operationError(operation: "inspect-directory", entry: displayPath, errnoCode: errno)
        }
        guard openedStatus.st_mode & S_IFMT == S_IFDIR,
              openedStatus.st_dev == initialStatus.st_dev,
              openedStatus.st_ino == initialStatus.st_ino else {
            throw operationError(operation: "verify-directory", entry: displayPath, errnoCode: ESTALE)
        }

        for childName in try entryNames(in: childDescriptor, displayPath: displayPath) {
            try removeEntryIfExists(
                childName,
                from: childDescriptor,
                displayPath: "\(displayPath)/\(childName.string)"
            )
        }

        guard let currentStatus = try entryStatus(name, in: parentDescriptor, displayPath: displayPath) else {
            return
        }
        guard currentStatus.st_mode & S_IFMT == S_IFDIR,
              currentStatus.st_dev == openedStatus.st_dev,
              currentStatus.st_ino == openedStatus.st_ino else {
            throw operationError(operation: "verify-directory-removal", entry: displayPath, errnoCode: ESTALE)
        }

        let result = name.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 || errno == ENOENT else {
            throw operationError(operation: "remove-directory", entry: displayPath, errnoCode: errno)
        }
    }

    private func entryNames(in directoryDescriptor: Int32, displayPath: String) throws -> [POSIXFileName] {
        let currentDirectoryName = POSIXFileName(".")
        let enumerationDescriptor = currentDirectoryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard enumerationDescriptor >= 0 else {
            throw operationError(operation: "open-directory-enumeration", entry: displayPath, errnoCode: errno)
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            let errnoCode = errno
            Darwin.close(enumerationDescriptor)
            throw operationError(operation: "enumerate-directory", entry: displayPath, errnoCode: errnoCode)
        }
        defer { Darwin.closedir(directory) }

        var names: [POSIXFileName] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                let errnoCode = errno
                if errnoCode != 0 {
                    throw operationError(operation: "read-directory", entry: displayPath, errnoCode: errnoCode)
                }
                break
            }
            let name = POSIXFileName(directoryEntry: entry.pointee)
            if !name.isDotEntry {
                names.append(name)
            }
        }
        return names
    }

    private func entryStatus(
        _ name: POSIXFileName,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws -> stat? {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return nil
            }
            throw operationError(operation: "inspect-entry", entry: displayPath, errnoCode: errnoCode)
        }
        return status
    }

    private func operationError(
        operation: String,
        entry: String,
        errnoCode: Int32
    ) -> TimeMachineCatalogStoreError {
        .managedSnapshotOperationFailed(
            operation: operation,
            entry: entry,
            errnoCode: errnoCode
        )
    }
}
