// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

final class ServiceBrokerClient: Sendable {
    private let socketPath: String
    private let nonStreamingResponseBytes: Int

    init(socketPath: String, nonStreamingResponseBytes: Int = 16 * 1024 * 1024) {
        self.socketPath = socketPath
        self.nonStreamingResponseBytes = nonStreamingResponseBytes
    }

    convenience init(socketPath: String, limits: ServiceBrokerLimits) {
        self.init(
            socketPath: socketPath,
            nonStreamingResponseBytes: limits.nonStreamingResponseBytes
        )
    }

    convenience init(storagePath: String, nonStreamingResponseBytes: Int = 16 * 1024 * 1024) {
        self.init(
            socketPath: ServiceBrokerSocketPath.dataSocketPath(storagePath: storagePath),
            nonStreamingResponseBytes: nonStreamingResponseBytes
        )
    }

    convenience init(storagePath: String, limits: ServiceBrokerLimits) {
        self.init(
            socketPath: ServiceBrokerSocketPath.dataSocketPath(storagePath: storagePath),
            limits: limits
        )
    }

    func request(_ request: BrokerHTTPRequest) async throws -> BrokerHTTPResponse {
        let stream = try await openStream(request)
        defer { stream.cancel() }

        var body = Data()
        while let chunk = try await stream.read(maxBytes: 64 * 1024) {
            guard chunk.count <= nonStreamingResponseBytes,
                  body.count <= nonStreamingResponseBytes - chunk.count else {
                throw ServiceBrokerHTTPError.responseTooLarge
            }
            body.append(chunk)
        }
        return BrokerHTTPResponse(
            statusCode: stream.response.statusCode,
            headers: stream.response.headers,
            body: body
        )
    }

    func openStream(_ request: BrokerHTTPRequest) async throws -> BrokerHTTPStream {
        let connection = ServiceBrokerHTTPConnection(
            socketPath: socketPath,
            bodyLimit: nil
        )
        return try await connection.execute(request)
    }
}
