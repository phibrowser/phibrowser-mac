// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelAccountDeletedEventTests: XCTestCase {
    private let signingKey = Data((0..<32).map(UInt8.init))

    func testMatchesPublishedCompatibilityVector() throws {
        let event = try SentinelAccountDeletedEvent.make(
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            auth0Sub: "auth0|user-1",
            signingKey: signingKey,
            requestID: "request-1",
            issuedAt: "1784800000"
        )

        XCTAssertEqual(
            SentinelAccountDeletedEvent.notificationName.rawValue,
            "com.phibrowser.sentinel.accountDeleted"
        )
        XCTAssertEqual(event.sentinelBundleID, "com.phibrowser.Sentinel")
        XCTAssertEqual(event.signature, "YU0BmgiXGqCSVOqdghK1/rsVOxE1KWKwpd0l6o9ipgY=")
        XCTAssertEqual(
            event.userInfo,
            [
                "signatureVersion": "1",
                "requestID": "request-1",
                "browserBundleID": "com.phibrowser.Mac",
                "auth0Sub": "auth0|user-1",
                "issuedAt": "1784800000",
                "signature": "YU0BmgiXGqCSVOqdghK1/rsVOxE1KWKwpd0l6o9ipgY="
            ]
        )
    }

    func testSignedContentIncludesStableAndCanaryBundlePairs() throws {
        let stable = try SentinelAccountDeletedEvent.make(
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            auth0Sub: "auth0|user-1",
            signingKey: signingKey,
            requestID: "stable-request",
            issuedAt: "1784800000"
        )
        let canary = try SentinelAccountDeletedEvent.make(
            sentinelBundleID: "com.phibrowser.canary.Sentinel",
            browserBundleID: "com.phibrowser.canary.Mac",
            auth0Sub: "auth0|user-1",
            signingKey: signingKey,
            requestID: "canary-request",
            issuedAt: "1784800000"
        )

        XCTAssertEqual(
            stable.signedContent,
            AccountDeletedSignedContent(
                signatureVersion: "1",
                notificationName: "com.phibrowser.sentinel.accountDeleted",
                sentinelBundleID: "com.phibrowser.Sentinel",
                browserBundleID: "com.phibrowser.Mac",
                requestID: "stable-request",
                auth0Sub: "auth0|user-1",
                issuedAt: "1784800000"
            )
        )
        XCTAssertEqual(
            canary.signedContent,
            AccountDeletedSignedContent(
                signatureVersion: "1",
                notificationName: "com.phibrowser.sentinel.accountDeleted",
                sentinelBundleID: "com.phibrowser.canary.Sentinel",
                browserBundleID: "com.phibrowser.canary.Mac",
                requestID: "canary-request",
                auth0Sub: "auth0|user-1",
                issuedAt: "1784800000"
            )
        )
    }

    func testRejectsMissingOrEmptyAuth0Sub() {
        for auth0Sub in [nil, ""] {
            XCTAssertThrowsError(
                try SentinelAccountDeletedEvent.make(
                    sentinelBundleID: "com.phibrowser.Sentinel",
                    browserBundleID: "com.phibrowser.Mac",
                    auth0Sub: auth0Sub,
                    signingKey: signingKey,
                    requestID: "request-1",
                    issuedAt: "1784800000"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SentinelAccountDeletedEventError,
                    .missingField("auth0Sub")
                )
            }
        }
    }

    func testRejectsMissingOrMalformedSigningKey() {
        let keys: [Data?] = [nil, Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 33)]

        for key in keys {
            XCTAssertThrowsError(
                try SentinelAccountDeletedEvent.make(
                    sentinelBundleID: "com.phibrowser.Sentinel",
                    browserBundleID: "com.phibrowser.Mac",
                    auth0Sub: "auth0|user-1",
                    signingKey: key,
                    requestID: "request-1",
                    issuedAt: "1784800000"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SentinelAccountDeletedEventError,
                    .signingKeyUnavailable
                )
            }
        }
    }

    func testEverySignedFieldChangesTheSignature() throws {
        let content = AccountDeletedSignedContent(
            signatureVersion: "1",
            notificationName: "com.phibrowser.sentinel.accountDeleted",
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            requestID: "request-1",
            auth0Sub: "auth0|user-1",
            issuedAt: "1784800000"
        )
        let original = try AccountDeletedEventAuthentication.signature(
            for: content,
            key: signingKey
        )
        let changedContents = [
            AccountDeletedSignedContent(
                signatureVersion: "2",
                notificationName: content.notificationName,
                sentinelBundleID: content.sentinelBundleID,
                browserBundleID: content.browserBundleID,
                requestID: content.requestID,
                auth0Sub: content.auth0Sub,
                issuedAt: content.issuedAt
            ),
            AccountDeletedSignedContent(
                signatureVersion: content.signatureVersion,
                notificationName: "com.phibrowser.sentinel.other",
                sentinelBundleID: content.sentinelBundleID,
                browserBundleID: content.browserBundleID,
                requestID: content.requestID,
                auth0Sub: content.auth0Sub,
                issuedAt: content.issuedAt
            ),
            AccountDeletedSignedContent(
                signatureVersion: content.signatureVersion,
                notificationName: content.notificationName,
                sentinelBundleID: "com.phibrowser.canary.Sentinel",
                browserBundleID: content.browserBundleID,
                requestID: content.requestID,
                auth0Sub: content.auth0Sub,
                issuedAt: content.issuedAt
            ),
            AccountDeletedSignedContent(
                signatureVersion: content.signatureVersion,
                notificationName: content.notificationName,
                sentinelBundleID: content.sentinelBundleID,
                browserBundleID: "com.phibrowser.canary.Mac",
                requestID: content.requestID,
                auth0Sub: content.auth0Sub,
                issuedAt: content.issuedAt
            ),
            AccountDeletedSignedContent(
                signatureVersion: content.signatureVersion,
                notificationName: content.notificationName,
                sentinelBundleID: content.sentinelBundleID,
                browserBundleID: content.browserBundleID,
                requestID: "request-2",
                auth0Sub: content.auth0Sub,
                issuedAt: content.issuedAt
            ),
            AccountDeletedSignedContent(
                signatureVersion: content.signatureVersion,
                notificationName: content.notificationName,
                sentinelBundleID: content.sentinelBundleID,
                browserBundleID: content.browserBundleID,
                requestID: content.requestID,
                auth0Sub: "auth0|user-2",
                issuedAt: content.issuedAt
            ),
            AccountDeletedSignedContent(
                signatureVersion: content.signatureVersion,
                notificationName: content.notificationName,
                sentinelBundleID: content.sentinelBundleID,
                browserBundleID: content.browserBundleID,
                requestID: content.requestID,
                auth0Sub: content.auth0Sub,
                issuedAt: "1784800001"
            )
        ]

        for changedContent in changedContents {
            XCTAssertNotEqual(
                try AccountDeletedEventAuthentication.signature(
                    for: changedContent,
                    key: signingKey
                ),
                original
            )
        }
    }

    func testRejectsNonIntegerIssuedAt() {
        XCTAssertThrowsError(
            try SentinelAccountDeletedEvent.make(
                sentinelBundleID: "com.phibrowser.Sentinel",
                browserBundleID: "com.phibrowser.Mac",
                auth0Sub: "auth0|user-1",
                signingKey: signingKey,
                requestID: "request-1",
                issuedAt: "1784800000.5"
            )
        ) { error in
            XCTAssertEqual(
                error as? SentinelAccountDeletedEventError,
                .invalidIssuedAt
            )
        }
    }

    func testRejectsEmptyBundleAndRequestIdentifiers() {
        let cases = [
            ("", "com.phibrowser.Mac", "request-1", "sentinelBundleID"),
            ("com.phibrowser.Sentinel", "", "request-1", "browserBundleID"),
            ("com.phibrowser.Sentinel", "com.phibrowser.Mac", "", "requestID")
        ]

        for (sentinelBundleID, browserBundleID, requestID, missingField) in cases {
            XCTAssertThrowsError(
                try SentinelAccountDeletedEvent.make(
                    sentinelBundleID: sentinelBundleID,
                    browserBundleID: browserBundleID,
                    auth0Sub: "auth0|user-1",
                    signingKey: signingKey,
                    requestID: requestID,
                    issuedAt: "1784800000"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SentinelAccountDeletedEventError,
                    .missingField(missingField)
                )
            }
        }
    }
}
