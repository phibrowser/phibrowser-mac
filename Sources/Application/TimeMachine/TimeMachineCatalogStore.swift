// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct TimeMachineCatalogStore {
    private let paths: TimeMachinePaths
    private let fileManager: FileManager

    init(paths: TimeMachinePaths = TimeMachinePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> TimeMachineCatalog {
        guard fileManager.fileExists(atPath: paths.catalogURL.path) else {
            return TimeMachineCatalog()
        }

        let data = try Data(contentsOf: paths.catalogURL)
        return try Self.decoder.decode(TimeMachineCatalog.self, from: data)
    }

    func save(_ catalog: TimeMachineCatalog) throws {
        try fileManager.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(catalog)
        try data.write(to: paths.catalogURL, options: .atomic)
    }

    func appendCompletedBackup(_ record: TimeMachineBackupRecord) throws {
        var catalog = try load()
        catalog.backups.removeAll { $0.id == record.id }
        catalog.backups.append(record)
        try save(catalog)
    }

    @discardableResult
    func removeBackup(id: UUID) throws -> TimeMachineBackupRecord? {
        var catalog = try load()
        guard let index = catalog.backups.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let record = catalog.backups.remove(at: index)
        try save(catalog)
        return record
    }

    @discardableResult
    func removeBackup(snapshotRelativePath: String) throws -> TimeMachineBackupRecord? {
        var catalog = try load()
        guard let index = catalog.backups.firstIndex(where: { $0.snapshotRelativePath == snapshotRelativePath }) else {
            return nil
        }
        let record = catalog.backups.remove(at: index)
        try save(catalog)
        return record
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
