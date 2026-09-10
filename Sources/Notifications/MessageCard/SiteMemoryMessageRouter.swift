// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SiteMemoryMessageRouter {
    static let queryType = "memory.getSiteCollectionEnabled"

    private struct Query: Decodable {
        let profileId: String
        let host: String
    }
    private struct Response: Encodable {
        let profileId: String
        let host: String
        let enabled: Bool
    }

    static func handle(_ context: ExtensionMessageContext) {
        Task { @MainActor in
            do {
                try authorize(context.senderId)
                let service = try SiteMemoryService.currentAccount()
                let response = try query(
                    payload: context.payload, senderID: context.senderId, settings: service.settings)
                ExtensionMessaging.shared.sendResponse(response, requestId: context.requestId)
            } catch {
                ExtensionMessaging.shared.sendError(
                    "Site memory query failed: \(error)", requestId: context.requestId)
            }
        }
    }

    static func query(payload: String, senderID: String, settings: SiteMemorySettingsStore) throws -> String {
        try authorize(senderID)
        let request = try JSONDecoder().decode(Query.self, from: Data(payload.utf8))
        let host = try SiteMemorySettingsStore.normalizedHost(request.host)
        let enabled = try settings.collectionEnabled(for: host, profileID: request.profileId)
        let response = Response(profileId: request.profileId, host: host, enabled: enabled)
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    private static func authorize(_ senderID: String) throws {
        guard senderID == ServiceBrokerExtensionProtocol.allowedCanaryLexingtonExtensionID else {
            throw SiteMemoryError.unauthorizedSender
        }
    }
}
