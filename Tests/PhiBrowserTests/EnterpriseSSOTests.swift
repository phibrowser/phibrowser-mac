// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// `EnterpriseSSOIdentityProvider`: which URLs belong to the Microsoft IdP the
/// device's Extensible SSO extension is configured for. Asking about anything
/// else hands the extension origins it does not own.
final class EnterpriseSSOIdentityProviderTests: XCTestCase {
    func testMicrosoftOriginsAreRecognized() {
        let urls = [
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x",
            "https://LOGIN.MICROSOFTONLINE.COM/",
            "https://sts.windows.net/tenant/",
            "https://login.microsoftonline.us/",
        ]
        for urlString in urls {
            XCTAssertNotNil(EnterpriseSSOIdentityProvider.microsoftIdentityProviderHost(for: urlString),
                            urlString)
        }
    }

    func testOtherHostsAreNotClaimed() {
        let urls = [
            "https://portal.office.com/",
            "https://login.microsoftonline.com.evil.example/",
            "https://example.com/login.microsoftonline.com",
            "chrome://settings",
            "about:blank",
            "",
            nil,
        ]
        for urlString in urls {
            XCTAssertNil(EnterpriseSSOIdentityProvider.microsoftIdentityProviderHost(for: urlString),
                         String(describing: urlString))
        }
    }

    func testOriginIsSchemeAndHostOnly() {
        XCTAssertEqual(EnterpriseSSOIdentityProvider.origin(of: URL(string: "https://a.example:8443/x/y?z=1")!),
                       "https://a.example")
        XCTAssertNil(EnterpriseSSOIdentityProvider.origin(of: URL(string: "file:///tmp/x")!))
        XCTAssertNil(EnterpriseSSOIdentityProvider.origin(of: URL(string: "about:blank")!))
    }

    func testEveryMicrosoftOriginHasAHost() {
        XCTAssertEqual(EnterpriseSSOIdentityProvider.microsoftHosts.count,
                       EnterpriseSSOIdentityProvider.microsoftOrigins.count)
        XCTAssertTrue(EnterpriseSSOIdentityProvider.microsoftHosts.contains("login.microsoftonline.com"))
    }
}

/// `EnterpriseSSOHeaderRequestPolicy`: one request per host per TTL, retried
/// immediately after a failed attempt.
final class EnterpriseSSOHeaderRequestPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testFirstRequestIsAllowed() {
        let policy = EnterpriseSSOHeaderRequestPolicy(ttl: 300)
        XCTAssertTrue(policy.shouldRequest(host: "login.microsoftonline.com", now: start))
    }

    func testRequestIsRateLimitedUntilTTLElapses() {
        var policy = EnterpriseSSOHeaderRequestPolicy(ttl: 300)
        policy.didRequest(host: "login.microsoftonline.com", now: start)

        XCTAssertFalse(policy.shouldRequest(host: "login.microsoftonline.com",
                                            now: start.addingTimeInterval(299)))
        XCTAssertTrue(policy.shouldRequest(host: "login.microsoftonline.com",
                                           now: start.addingTimeInterval(300)))
    }

    func testHostsAreRateLimitedIndependently() {
        var policy = EnterpriseSSOHeaderRequestPolicy(ttl: 300)
        policy.didRequest(host: "login.microsoftonline.com", now: start)

        XCTAssertTrue(policy.shouldRequest(host: "sts.windows.net", now: start))
    }

    func testFailureForgetsTheAttempt() {
        var policy = EnterpriseSSOHeaderRequestPolicy(ttl: 300)
        policy.didRequest(host: "login.microsoftonline.com", now: start)
        policy.didFail(host: "login.microsoftonline.com")

        XCTAssertTrue(policy.shouldRequest(host: "login.microsoftonline.com", now: start))
    }
}

/// `EnterpriseSSOHeaderProvider.requestHeaders(fromResponseHeaders:)`: the
/// shapes the Entra extension answers a `get_sso_cookies` request with.
final class EnterpriseSSOHeaderProviderTests: XCTestCase {
    func testNestedPrtAndDeviceHeadersAreFlattened() {
        let fields: [AnyHashable: Any] = [
            "prt_headers": [
                ["header": ["x-ms-RefreshTokenCredential": "prt-value"],
                 "home_account_id": "account-1"],
            ],
            "device_headers": [
                ["header": ["x-ms-DeviceCredential": "device-value"],
                 "tenant_id": "tenant-1"],
            ],
        ]

        let headers = EnterpriseSSOHeaderProvider.requestHeaders(fromResponseHeaders: fields)

        XCTAssertEqual(headers, [
            "x-ms-RefreshTokenCredential": "prt-value",
            "x-ms-DeviceCredential": "device-value",
        ])
    }

    func testJSONEncodedEntriesAreRead() {
        let json = #"[{"header": {"x-ms-RefreshTokenCredential": "prt-value"}, "home_account_id": "a"}]"#
        let headers = EnterpriseSSOHeaderProvider.requestHeaders(
            fromResponseHeaders: ["prt_headers": json])

        XCTAssertEqual(headers["x-ms-RefreshTokenCredential"], "prt-value")
    }

    func testFlatMSHeadersAreRead() {
        let headers = EnterpriseSSOHeaderProvider.requestHeaders(fromResponseHeaders: [
            "x-ms-RefreshTokenCredential": "prt-value",
            "content-type": "text/html",
        ])

        XCTAssertEqual(headers, ["x-ms-RefreshTokenCredential": "prt-value"])
    }

    func testInvalidNamesAndValuesAreDropped() {
        let fields: [AnyHashable: Any] = [
            "prt_headers": [
                ["header": [
                    "x-ms-Bad Name": "value",
                    "x-ms-Empty": "",
                    "x-ms-Control": "bad\u{0}value",
                    "x-ms-Good": "kept",
                ]],
            ],
        ]

        let headers = EnterpriseSSOHeaderProvider.requestHeaders(fromResponseHeaders: fields)

        XCTAssertEqual(headers, ["x-ms-Good": "kept"])
    }

    func testUnrelatedResponseHeadersAreIgnored() {
        XCTAssertTrue(EnterpriseSSOHeaderProvider.requestHeaders(fromResponseHeaders: [:]).isEmpty)
        XCTAssertTrue(EnterpriseSSOHeaderProvider.requestHeaders(
            fromResponseHeaders: ["content-type": "text/html"]).isEmpty)
    }
}
