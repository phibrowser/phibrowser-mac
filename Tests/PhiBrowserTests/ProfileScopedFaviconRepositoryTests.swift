// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ProfileScopedFaviconRepositoryTests: XCTestCase {
    func testInternalPagesReturnDefaultImageWithoutEncodedBytesOrFetches() {
        let fetcher = Fetcher()
        let repository = ProfileScopedFaviconRepository(fetcher: fetcher)
        for url in ["chrome://newtab", "phi://newtab", "chrome://memory"] {
            var deliveries = 0
            for _ in 0..<10 {
                let handle = repository.loadFavicon(for: .init(
                    profileId: "profile", pageURLString: url, snapshotData: nil
                )) { result in
                    deliveries += 1
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertTrue(result.image.isValid)
                    XCTAssertEqual(result.image.size, NSImage.phiDefaultFavicon.size)
                    XCTAssertEqual(result.source, .placeholder)
                    XCTAssertNil(result.data, "displaying a default icon must not serialize it")
                }
                XCTAssertNil(handle)
            }
            XCTAssertEqual(deliveries, 10, "default icons should be available synchronously")
        }
        XCTAssertEqual(fetcher.calls, 0)
    }

    func testWebsiteSnapshotAndUpdatedChromiumBytesRemainAvailable() async throws {
        let fetcher = Fetcher()
        let repository = ProfileScopedFaviconRepository(fetcher: fetcher)
        let snapshot = try iconData(red: 255)
        let updated = try iconData(red: 0)
        XCTAssertNotEqual(snapshot, updated)
        XCTAssertNotNil(NSImage(data: updated))
        let refreshed = expectation(description: "Chromium favicon delivered")
        var sources: [ProfileScopedFaviconSource] = []
        var payloads: [Data?] = []
        repository.loadFavicon(for: .init(
            profileId: "profile", pageURLString: "https://example.com", snapshotData: snapshot
        )) { result in
            XCTAssertTrue(Thread.isMainThread)
            sources.append(result.source)
            payloads.append(result.data)
            if result.source == .chromium { refreshed.fulfill() }
        }
        XCTAssertEqual(sources, [.snapshot])
        XCTAssertEqual(payloads, [snapshot])
        XCTAssertEqual(fetcher.calls, 1)

        fetcher.completion?(updated)
        await fulfillment(of: [refreshed], timeout: 2)
        withExtendedLifetime(repository) {}
        XCTAssertEqual(sources, [.snapshot, .chromium])
        XCTAssertEqual(payloads, [snapshot, updated])
    }

    func testCancellationSuppressesQueuedResultAfterCellReuse() async throws {
        let fetcher = Fetcher()
        let repository = ProfileScopedFaviconRepository(fetcher: fetcher)
        var deliveries = 0
        let handle = repository.loadFavicon(for: .init(
            profileId: "profile", pageURLString: "https://example.com", snapshotData: nil
        )) { _ in deliveries += 1 }
        fetcher.completion?(try iconData(red: 0))
        try XCTUnwrap(handle).cancel()

        let drained = expectation(description: "Queued result drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        withExtendedLifetime(repository) {}
        XCTAssertEqual(deliveries, 0)
    }

    func testSnapshotWithoutURLRetainsImageBytes() throws {
        let fetcher = Fetcher()
        let repository = ProfileScopedFaviconRepository(fetcher: fetcher)
        let data = try iconData(red: 255)
        var delivered: ProfileScopedFaviconResult?
        repository.loadFavicon(for: .init(
            profileId: "profile", pageURLString: nil, snapshotData: data
        )) { delivered = $0 }
        XCTAssertEqual(try XCTUnwrap(delivered).source, .snapshot)
        XCTAssertEqual(delivered?.data, data)
        XCTAssertEqual(fetcher.calls, 0)
    }

    private func iconData(red: UInt8) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ))
        let pixel = try XCTUnwrap(bitmap.bitmapData)
        pixel[0] = red
        pixel[1] = 0
        pixel[2] = 255 - red
        pixel[3] = 255
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private final class Fetcher: ProfileScopedFaviconFetching {
        var calls = 0
        var completion: ((Data?) -> Void)?

        func getFavicon(profileId: String, pageURLString: String, completion: @escaping (Data?) -> Void) {
            calls += 1
            self.completion = completion
        }
    }
}
