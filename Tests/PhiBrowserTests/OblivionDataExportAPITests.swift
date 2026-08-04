// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class OblivionDataExportAPITests: XCTestCase {
    private let requestID = "74a69ac7-a47c-48ad-a8d2-84b86301cdae"

    func testPendingVerificationMapsToCodeSent() throws {
        let expiresAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-04T10:10:00Z")
        )
        let body = Data(
            #"{"status":"pending_verification","request_id":"74a69ac7-a47c-48ad-a8d2-84b86301cdae","expires_at":"2026-08-04T10:10:00Z"}"#.utf8
        )

        XCTAssertEqual(
            try OblivionDataExportAPI.requestOutcome(statusCode: 202, body: body),
            .verificationCodeSent(
                requestID: requestID,
                expiresAt: expiresAt
            )
        )
    }

    func testKnownTaskStatusesMapToExistingTask() throws {
        for status in AccountDataExportTaskStatus.allCases {
            let body = Data(
                #"{"status":"\#(status.rawValue)","request_id":"req-123","task_id":"task-9"}"#.utf8
            )

            XCTAssertEqual(
                try OblivionDataExportAPI.requestOutcome(statusCode: 202, body: body),
                .existingTask(taskID: "task-9", status: status)
            )
        }
    }

    func testAcceptedResponseMustContainFieldsRequiredByItsStatus() {
        let bodies = [
            #"{"status":"pending_verification"}"#,
            #"{"status":"pending_verification","request_id":"74a69ac7-a47c-48ad-a8d2-84b86301cdae"}"#,
            #"{"status":"pending_verification","request_id":"74a69ac7-a47c-48ad-a8d2-84b86301cdae","expires_at":"not-a-date"}"#,
            #"{"status":"queued","request_id":"req-123"}"#,
            #"{"status":"unknown","request_id":"req-123","task_id":"task-9"}"#,
            "not json",
        ]

        for body in bodies {
            XCTAssertThrowsError(
                try OblivionDataExportAPI.requestOutcome(
                    statusCode: 202,
                    body: Data(body.utf8)
                )
            ) { error in
                XCTAssertEqual(
                    error as? AccountDataExportServiceError,
                    .unexpectedResponse(statusCode: 202)
                )
            }
        }
    }

    func testRequestErrorStatusesMapToDomainErrors() {
        let expectations: [(Int, AccountDataExportServiceError)] = [
            (400, .invalidRequest),
            (401, .unauthorized),
            (404, .notFound),
            (410, .expired),
            (429, .rateLimited),
            (500, .serverError(statusCode: 500, requestID: nil)),
            (503, .serverError(statusCode: 503, requestID: nil)),
            (301, .unexpectedResponse(statusCode: 301)),
        ]

        for (statusCode, expected) in expectations {
            XCTAssertThrowsError(
                try OblivionDataExportAPI.requestOutcome(statusCode: statusCode, body: Data())
            ) { error in
                XCTAssertEqual(error as? AccountDataExportServiceError, expected)
            }
        }
    }

    func testVerifyMapsKnownTaskStatus() throws {
        let body = Data(#"{"task_id":"task-9","status":"queued"}"#.utf8)

        XCTAssertEqual(
            try OblivionDataExportAPI.verificationOutcome(statusCode: 202, body: body),
            AccountDataExportVerificationOutcome(taskID: "task-9", status: .queued)
        )
    }

    func testVerifyRejectsMissingOrUnknownFields() {
        for body in [#"{"status":"queued"}"#, #"{"task_id":"task-9","status":"unknown"}"#] {
            XCTAssertThrowsError(
                try OblivionDataExportAPI.verificationOutcome(
                    statusCode: 202,
                    body: Data(body.utf8)
                )
            ) { error in
                XCTAssertEqual(
                    error as? AccountDataExportServiceError,
                    .unexpectedResponse(statusCode: 202)
                )
            }
        }
    }

    func testVerifyErrorStatusesMapToDomainErrors() {
        let expectations: [(Int, AccountDataExportServiceError)] = [
            (400, .invalidRequest),
            (401, .unauthorized),
            (404, .notFound),
            (410, .expired),
            (429, .rateLimited),
            (502, .serverError(statusCode: 502, requestID: nil)),
            (301, .unexpectedResponse(statusCode: 301)),
        ]

        for (statusCode, expected) in expectations {
            XCTAssertThrowsError(
                try OblivionDataExportAPI.verificationOutcome(
                    statusCode: statusCode,
                    body: Data()
                )
            ) { error in
                XCTAssertEqual(error as? AccountDataExportServiceError, expected)
            }
        }
    }

    func testVerificationURLTreatsRequestIDAsOneValidatedPathSegment() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://oblivion.stag.phibrowser.com"))

        XCTAssertEqual(
            try OblivionDataExportAPI.verificationURL(
                baseURL: baseURL,
                requestID: requestID
            ).absoluteString,
            "https://oblivion.stag.phibrowser.com/v1/data-export-requests/" +
                "74a69ac7-a47c-48ad-a8d2-84b86301cdae/verify"
        )

        for invalidID in ["../other", "segment/other", "not-a-uuid"] {
            XCTAssertThrowsError(
                try OblivionDataExportAPI.verificationURL(
                    baseURL: baseURL,
                    requestID: invalidID
                )
            ) { error in
                XCTAssertEqual(
                    error as? AccountDataExportServiceError,
                    .invalidRequest
                )
            }
        }
    }

    func testServerErrorRetainsSafeCorrelationID() {
        let body = Data(#"{"requestId":"body-request-id"}"#.utf8)

        XCTAssertThrowsError(
            try OblivionDataExportAPI.requestOutcome(
                statusCode: 503,
                body: body,
                responseRequestID: "header-request-id"
            )
        ) { error in
            XCTAssertEqual(
                error as? AccountDataExportServiceError,
                .serverError(statusCode: 503, requestID: "header-request-id")
            )
        }
    }

    func testServerErrorRejectsUnsafeCorrelationID() {
        let body = Data(#"{"requestId":"contains a space"}"#.utf8)

        XCTAssertThrowsError(
            try OblivionDataExportAPI.requestOutcome(statusCode: 500, body: body)
        ) { error in
            XCTAssertEqual(
                error as? AccountDataExportServiceError,
                .serverError(statusCode: 500, requestID: nil)
            )
        }
    }
}
