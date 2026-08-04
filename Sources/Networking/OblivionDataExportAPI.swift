// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum AccountDataExportTaskStatus: String, CaseIterable, Decodable, Equatable {
    case queued
    case collecting
    case retrying
    case delivering
    case delivered
    case failed
    case cancelled
    case expired

    var isActive: Bool {
        switch self {
        case .queued, .collecting, .retrying, .delivering:
            return true
        case .delivered, .failed, .cancelled, .expired:
            return false
        }
    }
}

enum AccountDataExportRequestOutcome: Equatable {
    case verificationCodeSent(requestID: String, expiresAt: Date)
    case existingTask(taskID: String, status: AccountDataExportTaskStatus)
}

struct AccountDataExportVerificationOutcome: Equatable {
    let taskID: String
    let status: AccountDataExportTaskStatus
}

enum AccountDataExportServiceError: Error, Equatable {
    case invalidRequest
    case unauthorized
    case notFound
    case expired
    case rateLimited
    case serverError(statusCode: Int, requestID: String?)
    case unexpectedResponse(statusCode: Int)
}

/// Maps the two data-export endpoints to domain results. Keeping this pure
/// makes the protocol's two accepted first-step shapes explicit: a new
/// challenge sends a code, while an existing task skips verification.
enum OblivionDataExportAPI {
    static func requestOutcome(
        statusCode: Int,
        body: Data,
        responseRequestID: String? = nil
    ) throws -> AccountDataExportRequestOutcome {
        guard (200...299).contains(statusCode) else {
            throw serviceError(
                statusCode: statusCode,
                requestID: correlationID(body: body, headerValue: responseRequestID)
            )
        }
        guard let payload = try? JSONDecoder().decode(TaskPayload.self, from: body) else {
            throw AccountDataExportServiceError.unexpectedResponse(statusCode: statusCode)
        }

        if payload.status == "pending_verification" {
            guard let requestID = payload.requestID,
                  !requestID.isEmpty,
                  let expiresAtValue = payload.expiresAt,
                  let expiresAt = parseISO8601Date(expiresAtValue) else {
                throw AccountDataExportServiceError.unexpectedResponse(statusCode: statusCode)
            }
            return .verificationCodeSent(
                requestID: requestID,
                expiresAt: expiresAt
            )
        }

        guard let taskID = payload.taskID,
              !taskID.isEmpty,
              let status = AccountDataExportTaskStatus(rawValue: payload.status) else {
            throw AccountDataExportServiceError.unexpectedResponse(statusCode: statusCode)
        }
        return .existingTask(taskID: taskID, status: status)
    }

    static func verificationOutcome(
        statusCode: Int,
        body: Data,
        responseRequestID: String? = nil
    ) throws -> AccountDataExportVerificationOutcome {
        guard (200...299).contains(statusCode) else {
            throw serviceError(
                statusCode: statusCode,
                requestID: correlationID(body: body, headerValue: responseRequestID)
            )
        }
        guard let payload = try? JSONDecoder().decode(TaskPayload.self, from: body),
              let taskID = payload.taskID,
              !taskID.isEmpty,
              let status = AccountDataExportTaskStatus(rawValue: payload.status) else {
            throw AccountDataExportServiceError.unexpectedResponse(statusCode: statusCode)
        }
        return AccountDataExportVerificationOutcome(taskID: taskID, status: status)
    }

    static func verificationURL(
        baseURL: URL,
        requestID: String
    ) throws -> URL {
        guard let requestUUID = UUID(uuidString: requestID) else {
            throw AccountDataExportServiceError.invalidRequest
        }

        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("data-export-requests")
            .appendingPathComponent(requestUUID.uuidString.lowercased())
            .appendingPathComponent("verify")
    }

    private static func serviceError(
        statusCode: Int,
        requestID: String?
    ) -> AccountDataExportServiceError {
        switch statusCode {
        case 400:
            return .invalidRequest
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 410:
            return .expired
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError(statusCode: statusCode, requestID: requestID)
        default:
            return .unexpectedResponse(statusCode: statusCode)
        }
    }

    private static func correlationID(body: Data, headerValue: String?) -> String? {
        if let headerValue, let value = validatedCorrelationID(headerValue) {
            return value
        }
        guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: body) else {
            return nil
        }
        return validatedCorrelationID(payload.requestID)
    }

    private static func validatedCorrelationID(_ value: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private struct TaskPayload: Decodable {
        let requestID: String?
        let taskID: String?
        let status: String
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case taskID = "task_id"
            case status
            case expiresAt = "expires_at"
        }
    }

    private struct ErrorPayload: Decodable {
        let requestID: String

        enum CodingKeys: String, CodingKey {
            case requestID = "requestId"
        }
    }
}
