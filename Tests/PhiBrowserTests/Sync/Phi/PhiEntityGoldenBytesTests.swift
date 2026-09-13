import XCTest
@testable import Phi

/// Wire-format constants for the phi payload schema, pinned as LITERAL BYTES.
///
/// Everything here is a cross-device contract that no self-consistent test can
/// protect: a field-number typo in `phi_entity.proto` round-trips perfectly on
/// the machine that made it, and only disagrees with the account's other
/// devices, which by then already hold ciphertext written under the old
/// numbers. The same argument covers the client tags: recomputing the hash with
/// the same helper the product uses stays green while the helper itself is
/// broken, so the three hashes below are frozen strings rather than
/// expressions.
final class PhiEntityGoldenBytesTests: XCTestCase {

    /// A `PhiSettingValue` carrying a non-default timestamp, so a message-typed
    /// field is emitted with a body instead of a bare two-byte header. Mirrors
    /// what `SyncableSpaces` stamps onto every mutable field.
    private func stamped(_ value: String, at updatedAtMs: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.updatedAtMs = updatedAtMs
        v.stringValue = value
        return v
    }

    /// The first byte of a serialized message is the first field's key:
    /// `(fieldNumber << 3) | wireType`. Each case sets exactly one field, so
    /// that byte IS the field number under test.
    private func firstByte(_ bytes: Data, _ label: String,
                           file: StaticString = #filePath, line: UInt = #line) -> UInt8 {
        guard let first = bytes.first else {
            XCTFail("\(label) serialized to zero bytes; the field was not emitted",
                    file: file, line: line)
            return 0
        }
        return first
    }

    // MARK: - CASE 1.1: the `kind` oneof tags

    /// Bookmarks are `kind` field 3 and pinned tabs field 4. If the two are
    /// swapped, or either creeps onto 5 / 6 (reserved for M3-4's URL rules and
    /// profiles), two devices decode the same ciphertext into different kinds.
    func testKindOneofUsesFieldThreeForBookmarkAndFourForPinTab() throws {
        var bookmarkEnvelope = Phi_PhiEntity()
        bookmarkEnvelope.bookmark = Phi_PhiBookmarkEntity()
        XCTAssertEqual([UInt8](try bookmarkEnvelope.serializedData()), [0x1A, 0x00])

        var pinEnvelope = Phi_PhiEntity()
        pinEnvelope.pinTab = Phi_PhiPinTabEntity()
        XCTAssertEqual([UInt8](try pinEnvelope.serializedData()), [0x22, 0x00])
    }

    /// The oneof discriminator itself, so `kind` cannot quietly become two
    /// singular fields that both decode.
    func testKindOneofRoundTripsBothNewVariants() throws {
        var bookmarkEnvelope = Phi_PhiEntity()
        bookmarkEnvelope.bookmark = Phi_PhiBookmarkEntity()
        let decodedBookmark = try Phi_PhiEntity(serializedBytes: try bookmarkEnvelope.serializedData())
        guard case .bookmark? = decodedBookmark.kind else {
            return XCTFail("expected the `bookmark` variant of PhiEntity.kind")
        }

        var pinEnvelope = Phi_PhiEntity()
        pinEnvelope.pinTab = Phi_PhiPinTabEntity()
        let decodedPin = try Phi_PhiEntity(serializedBytes: try pinEnvelope.serializedData())
        guard case .pinTab? = decodedPin.kind else {
            return XCTFail("expected the `pinTab` variant of PhiEntity.kind")
        }
    }

    // MARK: - CASE 1.2: PhiBookmarkEntity's eleven field numbers

    /// One assertion per field, each on a message with only that field set.
    /// A `generate.sh` run that renumbers a field passes every self-consistent
    /// round-trip test in the suite and fails only here.
    func testBookmarkEntityFieldNumbersArePinned() throws {
        var bookmarkUuid = Phi_PhiBookmarkEntity()
        bookmarkUuid.bookmarkUuid = "b"
        XCTAssertEqual(firstByte(try bookmarkUuid.serializedData(), "bookmark_uuid"), 0x0A)

        var spaceUuid = Phi_PhiBookmarkEntity()
        spaceUuid.spaceUuid = stamped("s", at: 1)
        XCTAssertEqual(firstByte(try spaceUuid.serializedData(), "space_uuid"), 0x12)

        var parentUuid = Phi_PhiBookmarkEntity()
        parentUuid.parentUuid = stamped("p", at: 1)
        XCTAssertEqual(firstByte(try parentUuid.serializedData(), "parent_uuid"), 0x1A)

        var rank = Phi_PhiBookmarkEntity()
        rank.rank = stamped("n", at: 1)
        XCTAssertEqual(firstByte(try rank.serializedData(), "rank"), 0x22)

        var isFolder = Phi_PhiBookmarkEntity()
        isFolder.isFolder = true
        XCTAssertEqual(firstByte(try isFolder.serializedData(), "is_folder"), 0x28)

        var title = Phi_PhiBookmarkEntity()
        title.title = stamped("t", at: 1)
        XCTAssertEqual(firstByte(try title.serializedData(), "title"), 0x32)

        var url = Phi_PhiBookmarkEntity()
        url.url = stamped("u", at: 1)
        XCTAssertEqual(firstByte(try url.serializedData(), "url"), 0x3A)

        var secondaryURL = Phi_PhiBookmarkEntity()
        secondaryURL.secondaryURL = stamped("u2", at: 1)
        XCTAssertEqual(firstByte(try secondaryURL.serializedData(), "secondary_url"), 0x42)

        var secondaryTitle = Phi_PhiBookmarkEntity()
        secondaryTitle.secondaryTitle = stamped("t2", at: 1)
        XCTAssertEqual(firstByte(try secondaryTitle.serializedData(), "secondary_title"), 0x4A)

        var source = Phi_PhiBookmarkEntity()
        source.source = 1
        XCTAssertEqual(firstByte(try source.serializedData(), "source"), 0x50)

        var createdAtMs = Phi_PhiBookmarkEntity()
        createdAtMs.createdAtMs = 1
        XCTAssertEqual(firstByte(try createdAtMs.serializedData(), "created_at_ms"), 0x58)
    }

    // MARK: - CASE 1.3: the reserved range 12-15 is claimed by nothing

    /// Field 12, wire type 2, one byte of payload. A build that reuses a
    /// reserved number would decode this into a known field and drop it from
    /// the re-serialized bytes; SwiftProtobuf parks an unknown field verbatim,
    /// which is the preservation contract older clients depend on.
    func testBookmarkEntityKeepsAReservedFieldInUnknownFields() throws {
        let wire = Data([0x62, 0x01, 0x41])

        let decoded = try Phi_PhiBookmarkEntity(serializedBytes: wire)

        XCTAssertEqual(decoded.bookmarkUuid, "")
        XCTAssertFalse(decoded.isFolder)
        XCTAssertEqual(decoded.source, 0)
        XCTAssertEqual(decoded.createdAtMs, 0)
        XCTAssertEqual([UInt8](try decoded.serializedData()), [UInt8](wire))
    }

    // MARK: - CASE 1.4: PhiPinTabEntity's nine field numbers

    func testPinTabEntityFieldNumbersArePinned() throws {
        var pinUuid = Phi_PhiPinTabEntity()
        pinUuid.pinUuid = "l"
        XCTAssertEqual(firstByte(try pinUuid.serializedData(), "pin_uuid"), 0x0A)

        var spaceOwner = Phi_PhiPinTabEntity()
        spaceOwner.spaceUuid = "s"
        XCTAssertEqual(firstByte(try spaceOwner.serializedData(), "owner.space_uuid"), 0x12)

        var profileOwner = Phi_PhiPinTabEntity()
        profileOwner.profileUuid = "p"
        XCTAssertEqual(firstByte(try profileOwner.serializedData(), "owner.profile_uuid"), 0x1A)

        var rank = Phi_PhiPinTabEntity()
        rank.rank = stamped("n", at: 1)
        XCTAssertEqual(firstByte(try rank.serializedData(), "rank"), 0x22)

        var title = Phi_PhiPinTabEntity()
        title.title = stamped("t", at: 1)
        XCTAssertEqual(firstByte(try title.serializedData(), "title"), 0x2A)

        var url = Phi_PhiPinTabEntity()
        url.url = stamped("u", at: 1)
        XCTAssertEqual(firstByte(try url.serializedData(), "url"), 0x32)

        var splitPartnerUuid = Phi_PhiPinTabEntity()
        splitPartnerUuid.splitPartnerUuid = stamped("l2", at: 1)
        XCTAssertEqual(firstByte(try splitPartnerUuid.serializedData(), "split_partner_uuid"), 0x3A)

        var source = Phi_PhiPinTabEntity()
        source.source = 1
        XCTAssertEqual(firstByte(try source.serializedData(), "source"), 0x40)

        var createdAtMs = Phi_PhiPinTabEntity()
        createdAtMs.createdAtMs = 1
        XCTAssertEqual(firstByte(try createdAtMs.serializedData(), "created_at_ms"), 0x48)
    }

    /// The same reserved-range guard for pins, whose range starts at 10.
    func testPinTabEntityKeepsAReservedFieldInUnknownFields() throws {
        let wire = Data([0x52, 0x01, 0x41])

        let decoded = try Phi_PhiPinTabEntity(serializedBytes: wire)

        XCTAssertEqual(decoded.pinUuid, "")
        XCTAssertNil(decoded.owner)
        XCTAssertEqual([UInt8](try decoded.serializedData()), [UInt8](wire))
    }

    // MARK: - CASE 1.5: an absent owner oneof IS the App scope

    /// The one place this schema does not follow "always emitted": absence here
    /// is one of three exhaustive values, not "the peer did not know". A future
    /// change that gives `owner` a default variant would make an App-scoped pin
    /// decode as a Space-scoped one with an empty uuid.
    func testPinTabEntityWithNoOwnerRoundTripsAsAppScope() throws {
        var pin = Phi_PhiPinTabEntity()
        pin.pinUuid = "l"

        let decoded = try Phi_PhiPinTabEntity(serializedBytes: try pin.serializedData())

        XCTAssertEqual(decoded.pinUuid, "l")
        XCTAssertNil(decoded.owner)
    }

    // MARK: - CASE 1.6: PhiSpaceEntity's field numbers are unchanged

    /// M3-2's message is already on the wire in real accounts. Adding
    /// `reserved 11 to 14;` must not disturb it.
    func testSpaceEntityFieldNumbersAreUnchanged() throws {
        var spaceUuid = Phi_PhiSpaceEntity()
        spaceUuid.spaceUuid = "s"
        XCTAssertEqual(firstByte(try spaceUuid.serializedData(), "space_uuid"), 0x0A)

        var name = Phi_PhiSpaceEntity()
        name.name = stamped("n", at: 1)
        XCTAssertEqual(firstByte(try name.serializedData(), "name"), 0x12)

        var createdAtMs = Phi_PhiSpaceEntity()
        createdAtMs.createdAtMs = 1
        XCTAssertEqual(firstByte(try createdAtMs.serializedData(), "created_at_ms"), 0x50)
    }

    // MARK: - CASE 1.7: the textual shape of the two new client tags

    func testClientTagTextualShapes() {
        XCTAssertEqual(PhiSyncEntity.bookmarkTagPrefix, "phi-bookmark:")
        XCTAssertEqual(PhiSyncEntity.bookmarkClientTag("0123abcd"), "phi-bookmark:0123abcd")

        XCTAssertEqual(PhiSyncEntity.pinTagPrefix, "phi-pin:")
        XCTAssertEqual(PhiSyncEntity.pinClientTag("0123abcd", ownerKey: "app"),
                       "phi-pin:0123abcd:app")
    }

    // MARK: - CASE 1.8: the three client tag hashes, as literals

    /// `base64(SHA1(<serialized empty phi specifics> + tag))`. Recomputing the
    /// hash inside the assertion would stay green through any change to the
    /// derivation; only a frozen string catches a reordered `pinClientTag`
    /// argument pair, a changed separator, or an un-normalized uppercase
    /// lineage reaching the tag.
    func testClientTagHashesArePinnedLiterals() {
        XCTAssertEqual(PhiSyncEntity.settingsClientTagHash,
                       "0bjDcWaaKM/1uIOEEoacv38mMKg=")
        XCTAssertEqual(
            PhiSyncEntity.clientTagHash(for: PhiSyncEntity.bookmarkClientTag("0123abcd")),
            "yrs08MKmC9DIHH1HfjVCz9x3kco=")
        XCTAssertEqual(
            PhiSyncEntity.clientTagHash(
                for: PhiSyncEntity.pinClientTag("0123abcd", ownerKey: "app")),
            "L+Zp5yYI1PDDiiQSO2/ebBDSOPI=")
    }

    // MARK: - CASE 1.9: the server-visible plaintext name is one constant per kind

    /// The server persists `SyncEntity.name` in PLAINTEXT (`commitName` ->
    /// `entities.name`). A title, a URL or a tag carrying a uuid would break
    /// zero knowledge outright; a per-kind constant also satisfies the server's
    /// `ON CONFLICT ... WHERE entities.name IS DISTINCT FROM ...` idempotence
    /// check, so a repeated commit is not a write.
    func testEntityNamesAreConstantsPerKind() {
        XCTAssertEqual(PhiSyncEntity.clientTag, "phi-settings")
        XCTAssertEqual(PhiSyncEntity.spaceEntityName, "phi-space")
        XCTAssertEqual(PhiSyncEntity.bookmarkEntityName, "phi-bookmark")
        XCTAssertEqual(PhiSyncEntity.pinEntityName, "phi-pin")

        for name in [PhiSyncEntity.clientTag,
                     PhiSyncEntity.spaceEntityName,
                     PhiSyncEntity.bookmarkEntityName,
                     PhiSyncEntity.pinEntityName] {
            XCTAssertFalse(name.contains(":"),
                           "a plaintext entity name must never carry a tag separator or a uuid")
        }
    }
}
