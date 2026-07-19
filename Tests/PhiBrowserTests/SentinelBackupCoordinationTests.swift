// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelBackupCoordinationTests: XCTestCase {
    func testExportContractNamesAndPayload() {
        XCTAssertEqual(SentinelAIDataExport.requestName.rawValue, "com.phibrowser.sentinel.exportAIData.request")
        XCTAssertEqual(SentinelAIDataExport.responseName.rawValue, "com.phibrowser.sentinel.exportAIData.response")

        let userInfo = SentinelAIDataExport.requestUserInfo(requestID: "req-1", destinationPath: "/tmp/ai-data.tar.gz")
        XCTAssertEqual(userInfo, ["requestID": "req-1", "destinationPath": "/tmp/ai-data.tar.gz"])

        let ok = SentinelAIDataExport.parseResponse(["requestID": "req-1", "status": "completed", "path": "/tmp/ai-data.tar.gz"])
        XCTAssertEqual(ok?.status, .completed)
        XCTAssertEqual(ok?.path, "/tmp/ai-data.tar.gz")
        XCTAssertNil(ok?.error)

        let failed = SentinelAIDataExport.parseResponse(["requestID": "req-1", "status": "error", "error": "boom"])
        XCTAssertEqual(failed?.status, .error)
        XCTAssertEqual(failed?.error, "boom")

        XCTAssertNil(SentinelAIDataExport.parseResponse(["requestID": "req-1"]))
        XCTAssertNil(SentinelAIDataExport.parseResponse(["requestID": "req-1", "status": "bogus"]))
    }

    func testImportContractNamesAndPayload() {
        XCTAssertEqual(SentinelAIDataImport.requestName.rawValue, "com.phibrowser.sentinel.importAIData.request")
        XCTAssertEqual(SentinelAIDataImport.responseName.rawValue, "com.phibrowser.sentinel.importAIData.response")

        let userInfo = SentinelAIDataImport.requestUserInfo(requestID: "req-2", path: "/tmp/ai-data.tar.gz", confirmed: true)
        XCTAssertEqual(userInfo, ["requestID": "req-2", "path": "/tmp/ai-data.tar.gz", "confirmed": "true"])

        let attention = SentinelAIDataImport.parseResponse(["requestID": "req-2", "status": "completed", "needsAttention": "true"])
        XCTAssertEqual(attention?.status, .completed)
        XCTAssertTrue(attention?.needsAttention ?? false)

        let clean = SentinelAIDataImport.parseResponse(["requestID": "req-2", "status": "completed", "needsAttention": "false"])
        XCTAssertFalse(clean?.needsAttention ?? true)

        let missingAttention = SentinelAIDataImport.parseResponse(["requestID": "req-2", "status": "completed"])
        XCTAssertEqual(missingAttention?.needsAttention, false)
    }

    func testPrepareForRollbackContractNamesAndPayload() {
        XCTAssertEqual(SentinelPrepareForRollback.requestName.rawValue, "com.phibrowser.sentinel.prepareForRollback.request")
        XCTAssertEqual(SentinelPrepareForRollback.responseName.rawValue, "com.phibrowser.sentinel.prepareForRollback.response")

        let userInfo = SentinelPrepareForRollback.requestUserInfo(requestID: "req-3", targetBrowserVersion: "1.6", fromBrowserVersion: "2.0", operationID: "op-9")
        XCTAssertEqual(userInfo, ["requestID": "req-3", "targetBrowserVersion": "1.6", "fromBrowserVersion": "2.0", "operationID": "op-9"])

        XCTAssertEqual(SentinelPrepareForRollback.parseResponse(["requestID": "req-3", "status": "restored"])?.status, .restored)
        XCTAssertEqual(SentinelPrepareForRollback.parseResponse(["requestID": "req-3", "status": "noSnapshot"])?.status, .noSnapshot)
        XCTAssertEqual(SentinelPrepareForRollback.parseResponse(["requestID": "req-3", "status": "error"])?.status, .error)
        XCTAssertNil(SentinelPrepareForRollback.parseResponse(["requestID": "req-3", "status": "restored-ish"]))
    }
}
