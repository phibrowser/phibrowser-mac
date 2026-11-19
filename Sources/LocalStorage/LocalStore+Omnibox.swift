// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension LocalStore {
    // Only called by the admitted coordinator read closure. Resolve the active
    // persisted pin scope in the writer context, never from a UI mirror.
    func readOmniboxSnapshot(profileID: String, spaceID: String,
                             ticket: OmniboxQueryTicket) async throws -> OmniboxNativeSearchSnapshot {
        try await readForOmnibox { context, epoch in
            let scope = try self.pinnedTabScope(in: context)
            return try OmniboxNativeSnapshotReader.read(context: context, profileID: profileID,
                spaceID: spaceID, pinScope: scope, epoch: epoch, ticket: ticket)
        }
    }

    @MainActor
    func performOmniboxEntitySelection<Result: Sendable>(
        _ entity: OmniboxNativeEntity, expectedEpoch: String, expectedPinScope: String,
        profileID: String, spaceID: String, ticket: OmniboxQueryTicket,
        dispatch: @escaping @MainActor @Sendable (OmniboxNativeEntity) throws -> Result
    ) async throws -> Result {
        try await performOmniboxSelection(ticket: ticket, validate: { context, epoch in
            let scope = try self.pinnedTabScope(in: context)
            return try OmniboxNativeSnapshotReader.validate(entity, expectedEpoch: expectedEpoch,
                expectedPinScope: expectedPinScope, context: context, profileID: profileID,
                spaceID: spaceID, pinScope: scope, epoch: epoch, ticket: ticket)
        }, dispatch: dispatch)
    }
}
