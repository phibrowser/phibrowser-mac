// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

enum TimeMachineCatalogStoreError: Error, LocalizedError {
    case invalidSnapshotPath(String)
    case unsafeManagedDirectory(path: String, errnoCode: Int32)
    case managedCatalogOperationFailed(operation: String, errnoCode: Int32)
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
        case .managedCatalogOperationFailed(let operation, let errnoCode):
            return "Time Machine catalog operation \(operation) failed: errno \(errnoCode)"
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
    typealias SnapshotSizeMeasurementHook = (_ backupID: UUID, _ sizeBytes: UInt64) throws -> Void

    private static let lock = NSRecursiveLock()

    private let paths: TimeMachinePaths
    private let fileManager: FileManager
    private let catalogWriter: CatalogWriter?
    private let snapshotSizeMeasurementHook: SnapshotSizeMeasurementHook?

    init(
        paths: TimeMachinePaths = TimeMachinePaths(),
        fileManager: FileManager = .default,
        catalogWriter: CatalogWriter? = nil,
        snapshotSizeMeasurementHook: SnapshotSizeMeasurementHook? = nil
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.catalogWriter = catalogWriter
        self.snapshotSizeMeasurementHook = snapshotSizeMeasurementHook
    }

    /// Reconciles interrupted backup deletions before returning catalog data.
    func load() throws -> TimeMachineCatalog {
        try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            return catalog
        }
    }

    func save(_ catalog: TimeMachineCatalog) throws {
        try withCatalogLock(createRootIfNeeded: true) { snapshotsDirectory in
            try saveWithoutLock(catalog, to: snapshotsDirectory)
        }
    }

    func appendCompletedBackup(_ record: TimeMachineBackupRecord) throws {
        try withCatalogLock(createRootIfNeeded: true) { snapshotsDirectory in
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            catalog.backups.removeAll { $0.id == record.id }
            catalog.backups.append(record)
            try saveWithoutLock(catalog, to: snapshotsDirectory)
        }
    }

    @discardableResult
    func updateSnapshotSizeBytes(id: UUID, sizeBytes: UInt64) throws -> TimeMachineBackupRecord? {
        try updateSnapshotSizeBytes(
            id: id,
            sizeBytes: sizeBytes,
            expectedRootIdentity: nil,
            expectedSnapshotIdentity: nil
        )
    }

    private func updateSnapshotSizeBytes(
        id: UUID,
        sizeBytes: UInt64,
        expectedRootIdentity: TimeMachineDirectoryIdentity?,
        expectedSnapshotIdentity: TimeMachineDirectoryIdentity?
    ) throws -> TimeMachineBackupRecord? {
        try withCatalogLock { snapshotsDirectory in
            guard let snapshotsDirectory else {
                return nil
            }
            if let expectedRootIdentity,
               snapshotsDirectory.rootIdentity != expectedRootIdentity {
                return nil
            }

            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let snapshotName = try managedSnapshotName(for: catalog.backups[index])
            guard let snapshotIdentity = try snapshotsDirectory.directoryIdentity(snapshotName) else {
                return nil
            }
            if let expectedSnapshotIdentity,
               snapshotIdentity != expectedSnapshotIdentity {
                return nil
            }
            catalog.backups[index].snapshotSizeBytes = sizeBytes
            let record = catalog.backups[index]
            try saveWithoutLock(catalog, to: snapshotsDirectory)
            return record
        }
    }

    func snapshotSizeBytes(for record: TimeMachineBackupRecord) throws -> UInt64? {
        try withCatalogLock { snapshotsDirectory in
            let snapshotName = try managedSnapshotName(for: record)
            guard let snapshotsDirectory,
                  try snapshotsDirectory.entryIsDirectory(snapshotName) else {
                return nil
            }
            return record.snapshotSizeBytes
        }
    }

    @discardableResult
    func resolveSnapshotSizeBytes(id: UUID) throws -> UInt64? {
        let context: (
            record: TimeMachineBackupRecord,
            rootIdentity: TimeMachineDirectoryIdentity,
            snapshotIdentity: TimeMachineDirectoryIdentity
        )? = try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let record = catalog.backups.first(where: { $0.id == id }) else {
                return nil
            }
            let snapshotName = try managedSnapshotName(for: record)
            guard let snapshotsDirectory,
                  let snapshotIdentity = try snapshotsDirectory.directoryIdentity(snapshotName) else {
                return nil
            }
            return (record, snapshotsDirectory.rootIdentity, snapshotIdentity)
        }
        guard let context else {
            return nil
        }
        let record = context.record
        if let snapshotSizeBytes = record.snapshotSizeBytes {
            return snapshotSizeBytes
        }

        let snapshotName = try managedSnapshotName(for: record)
        guard let snapshotsDirectory = try TimeMachineManagedSnapshotsDirectory.open(
            paths: paths,
            lockRoot: false
        ),
              snapshotsDirectory.rootIdentity == context.rootIdentity,
              let snapshotSizeBytes = try snapshotsDirectory.logicalSizeBytes(
                  ofDirectory: snapshotName,
                  expectedIdentity: context.snapshotIdentity
              ) else {
            return nil
        }
        try snapshotSizeMeasurementHook?(id, snapshotSizeBytes)

        do {
            guard try updateSnapshotSizeBytes(
                id: id,
                sizeBytes: snapshotSizeBytes,
                expectedRootIdentity: context.rootIdentity,
                expectedSnapshotIdentity: context.snapshotIdentity
            ) != nil else {
                return nil
            }
        } catch {
            // Size metadata is a cache. A write failure must not hide a successfully measured backup.
        }
        return snapshotSizeBytes
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
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
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
                try saveWithoutLock(catalog, to: snapshotsDirectory)
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
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
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
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
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
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let record = catalog.backups.remove(at: index)
            try saveWithoutLock(catalog, to: snapshotsDirectory)
            return record
        }
    }

    @discardableResult
    func removeBackup(snapshotRelativePath: String) throws -> TimeMachineBackupRecord? {
        try withCatalogLock { snapshotsDirectory in
            var catalog = try loadWithoutRecovery(from: snapshotsDirectory)
            try recoverInterruptedDeletions(
                catalog: &catalog,
                snapshotsDirectory: snapshotsDirectory
            )
            guard let index = catalog.backups.firstIndex(where: { $0.snapshotRelativePath == snapshotRelativePath }) else {
                return nil
            }
            let record = catalog.backups.remove(at: index)
            try saveWithoutLock(catalog, to: snapshotsDirectory)
            return record
        }
    }

    private func loadWithoutRecovery(
        from snapshotsDirectory: TimeMachineManagedSnapshotsDirectory?
    ) throws -> TimeMachineCatalog {
        guard let data = try snapshotsDirectory?.readCatalogData() else {
            return TimeMachineCatalog()
        }
        return try Self.decoder.decode(TimeMachineCatalog.self, from: data)
    }

    private func saveWithoutLock(
        _ catalog: TimeMachineCatalog,
        to snapshotsDirectory: TimeMachineManagedSnapshotsDirectory?
    ) throws {
        guard let snapshotsDirectory else {
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.rootURL.path,
                errnoCode: ENOENT
            )
        }
        let data = try Self.encoder.encode(catalog)
        try catalogWriter?(data, paths.catalogURL)
        try snapshotsDirectory.replaceCatalogData(data)
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
                try TimeMachineManagedSnapshotsDirectory.createRootIfNeeded(paths: paths)
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

private struct TimeMachineDirectoryIdentity: Equatable {
    let deviceID: dev_t
    let inode: ino_t

    init(status: stat) {
        deviceID = status.st_dev
        inode = status.st_ino
    }
}

private final class TimeMachineManagedSnapshotsDirectory {
    private let rootDescriptor: Int32
    private let descriptor: Int32?
    private let deviceID: dev_t
    private let releasesRootLock: Bool
    let rootIdentity: TimeMachineDirectoryIdentity

    private init(
        rootDescriptor: Int32,
        descriptor: Int32?,
        deviceID: dev_t,
        releasesRootLock: Bool,
        rootIdentity: TimeMachineDirectoryIdentity
    ) {
        self.rootDescriptor = rootDescriptor
        self.descriptor = descriptor
        self.deviceID = deviceID
        self.releasesRootLock = releasesRootLock
        self.rootIdentity = rootIdentity
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
                    releasesRootLock: lockRoot,
                    rootIdentity: TimeMachineDirectoryIdentity(status: rootStatus)
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
            releasesRootLock: lockRoot,
            rootIdentity: TimeMachineDirectoryIdentity(status: rootStatus)
        )
    }

    static func createRootIfNeeded(paths: TimeMachinePaths) throws {
        let rootURL = paths.rootURL.standardizedFileURL
        let pathComponents = rootURL.pathComponents
        guard rootURL.isFileURL,
              pathComponents.first == "/" else {
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.rootURL.path,
                errnoCode: EINVAL
            )
        }

        var parentDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                path: paths.rootURL.path,
                errnoCode: errno
            )
        }
        defer { Darwin.close(parentDescriptor) }

        for component in pathComponents.dropFirst() {
            guard !component.isEmpty,
                  component != ".",
                  component != ".." else {
                throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                    path: paths.rootURL.path,
                    errnoCode: EINVAL
                )
            }

            let name = POSIXFileName(component)
            var childDescriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if childDescriptor < 0 && errno == ENOENT {
                let createResult = name.withCString {
                    Darwin.mkdirat(
                        parentDescriptor,
                        $0,
                        mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
                    )
                }
                guard createResult == 0 || errno == EEXIST else {
                    throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                        path: paths.rootURL.path,
                        errnoCode: errno
                    )
                }
                childDescriptor = name.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
            }
            guard childDescriptor >= 0 else {
                throw TimeMachineCatalogStoreError.unsafeManagedDirectory(
                    path: paths.rootURL.path,
                    errnoCode: errno
                )
            }

            Darwin.close(parentDescriptor)
            parentDescriptor = childDescriptor
        }
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

    func entryIsDirectory(_ name: POSIXFileName) throws -> Bool {
        try directoryIdentity(name) != nil
    }

    func directoryIdentity(_ name: POSIXFileName) throws -> TimeMachineDirectoryIdentity? {
        guard let descriptor,
              let status = try entryStatus(name, in: descriptor, displayPath: name.string),
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_dev == deviceID else {
            return nil
        }
        return TimeMachineDirectoryIdentity(status: status)
    }

    func readCatalogData() throws -> Data? {
        let catalogName = POSIXFileName(TimeMachinePaths.catalogFilename)
        let catalogDescriptor = catalogName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard catalogDescriptor >= 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return nil
            }
            throw catalogOperationError(operation: "open-read", errnoCode: errnoCode)
        }
        defer { Darwin.close(catalogDescriptor) }

        var status = stat()
        guard Darwin.fstat(catalogDescriptor, &status) == 0 else {
            throw catalogOperationError(operation: "inspect-read", errnoCode: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_dev == deviceID else {
            throw catalogOperationError(operation: "verify-read", errnoCode: EINVAL)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(catalogDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                continue
            }
            if bytesRead == 0 {
                return data
            }
            if errno == EINTR {
                continue
            }
            throw catalogOperationError(operation: "read", errnoCode: errno)
        }
    }

    func replaceCatalogData(_ data: Data) throws {
        let catalogName = POSIXFileName(TimeMachinePaths.catalogFilename)
        let temporaryName = POSIXFileName(".\(TimeMachinePaths.catalogFilename).\(UUID().uuidString).tmp")
        var temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw catalogOperationError(operation: "open-write", errnoCode: errno)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if temporaryDescriptor >= 0 {
                Darwin.close(temporaryDescriptor)
            }
            if shouldRemoveTemporaryFile {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(rootDescriptor, $0, 0)
                }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let bytesWritten = Darwin.write(
                    temporaryDescriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if bytesWritten > 0 {
                    offset += bytesWritten
                    continue
                }
                if bytesWritten < 0 && errno == EINTR {
                    continue
                }
                throw catalogOperationError(
                    operation: "write",
                    errnoCode: bytesWritten == 0 ? EIO : errno
                )
            }
        }

        var syncResult: Int32
        repeat {
            syncResult = Darwin.fsync(temporaryDescriptor)
        } while syncResult != 0 && errno == EINTR
        guard syncResult == 0 else {
            throw catalogOperationError(operation: "sync-write", errnoCode: errno)
        }

        guard Darwin.close(temporaryDescriptor) == 0 else {
            let errnoCode = errno
            temporaryDescriptor = -1
            throw catalogOperationError(operation: "close-write", errnoCode: errnoCode)
        }
        temporaryDescriptor = -1

        let renameResult = temporaryName.withCString { temporaryPath in
            catalogName.withCString { catalogPath in
                Darwin.renameat(rootDescriptor, temporaryPath, rootDescriptor, catalogPath)
            }
        }
        guard renameResult == 0 else {
            throw catalogOperationError(operation: "commit-write", errnoCode: errno)
        }
        shouldRemoveTemporaryFile = false
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

    func logicalSizeBytes(
        ofDirectory name: POSIXFileName,
        expectedIdentity: TimeMachineDirectoryIdentity
    ) throws -> UInt64? {
        guard let descriptor,
              let initialStatus = try entryStatus(name, in: descriptor, displayPath: name.string),
              initialStatus.st_mode & S_IFMT == S_IFDIR,
              TimeMachineDirectoryIdentity(status: initialStatus) == expectedIdentity else {
            return nil
        }
        return try logicalDirectorySizeBytes(
            name,
            initialStatus: initialStatus,
            from: descriptor,
            displayPath: name.string
        )
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

    private func logicalEntrySizeBytes(
        _ name: POSIXFileName,
        from parentDescriptor: Int32,
        displayPath: String
    ) throws -> UInt64? {
        guard let initialStatus = try entryStatus(
            name,
            in: parentDescriptor,
            displayPath: displayPath
        ) else {
            return nil
        }

        switch initialStatus.st_mode & S_IFMT {
        case S_IFDIR:
            return try logicalDirectorySizeBytes(
                name,
                initialStatus: initialStatus,
                from: parentDescriptor,
                displayPath: displayPath
            )
        case S_IFREG, S_IFLNK:
            return UInt64(max(initialStatus.st_size, 0))
        default:
            // Special entries contribute no snapshot data.
            return 0
        }
    }

    private func logicalDirectorySizeBytes(
        _ name: POSIXFileName,
        initialStatus: stat,
        from parentDescriptor: Int32,
        displayPath: String
    ) throws -> UInt64 {
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
            throw operationError(operation: "open-directory", entry: displayPath, errnoCode: errno)
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

        var total: UInt64 = 0
        for childName in try entryNames(in: childDescriptor, displayPath: displayPath) {
            guard let childSize = try logicalEntrySizeBytes(
                childName,
                from: childDescriptor,
                displayPath: "\(displayPath)/\(childName.string)"
            ) else {
                continue
            }
            let (newTotal, overflow) = total.addingReportingOverflow(childSize)
            guard !overflow else {
                throw operationError(operation: "measure-size", entry: displayPath, errnoCode: EOVERFLOW)
            }
            total = newTotal
        }

        guard let currentStatus = try entryStatus(
            name,
            in: parentDescriptor,
            displayPath: displayPath
        ),
              currentStatus.st_mode & S_IFMT == S_IFDIR,
              currentStatus.st_dev == openedStatus.st_dev,
              currentStatus.st_ino == openedStatus.st_ino else {
            throw operationError(operation: "verify-directory-size", entry: displayPath, errnoCode: ESTALE)
        }
        return total
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

    private func catalogOperationError(
        operation: String,
        errnoCode: Int32
    ) -> TimeMachineCatalogStoreError {
        .managedCatalogOperationFailed(
            operation: operation,
            errnoCode: errnoCode
        )
    }
}
