// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct TimeMachineRestoreJournalStore {
    private let paths: TimeMachinePaths
    private let fileManager: FileManager

    init(paths: TimeMachinePaths = TimeMachinePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func write(_ journal: TimeMachineRestoreJournal) throws {
        let operationURL = paths.pendingOperationURL(id: journal.operationID)
        try fileManager.createDirectory(at: operationURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(journal)
        try data.write(to: paths.journalURL(operationID: journal.operationID), options: .atomic)
    }

    func load(operationID: UUID) throws -> TimeMachineRestoreJournal? {
        let url = paths.journalURL(operationID: operationID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(TimeMachineRestoreJournal.self, from: data)
    }

    func pendingJournalsNeedingRecovery() throws -> [TimeMachineRestoreJournal] {
        try pendingJournals { $0.phase.needsRecovery }
    }

    func completedPendingJournals() throws -> [TimeMachineRestoreJournal] {
        try pendingJournals { $0.phase == .completed }
    }

    private func pendingJournals(
        where shouldInclude: (TimeMachineRestoreJournal) -> Bool
    ) throws -> [TimeMachineRestoreJournal] {
        guard fileManager.fileExists(atPath: paths.pendingRootURL.path) else {
            return []
        }

        let operationURLs = try fileManager.contentsOfDirectory(
            at: paths.pendingRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try operationURLs.compactMap { operationURL in
            let values = try operationURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let operationID = UUID(uuidString: operationURL.lastPathComponent),
                  let journal = try load(operationID: operationID),
                  shouldInclude(journal) else {
                return nil
            }
            return journal
        }
        .sorted { $0.updatedAt < $1.updatedAt }
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
