import XCTest
@testable import Phi

/// Guards the two things the generated protobuf code has to get right for the
/// phi data type: the payload schema round-trips, and the opaque specifics land
/// on EntitySpecifics field 2000 on the wire.
final class PhiEntityProtoTests: XCTestCase {

    func testPhiEntityRoundTrips() throws {
        var v = Phi_PhiSettingValue()
        v.updatedAtMs = 123
        v.boolValue = true
        var s = Phi_PhiSettingEntity()
        s.values = ["theme.dark": v]
        var e = Phi_PhiEntity()
        e.setting = s

        let data = try e.serializedData()
        let back = try Phi_PhiEntity(serializedBytes: data)

        XCTAssertEqual(back.setting.values["theme.dark"]?.boolValue, true)
        XCTAssertEqual(back.setting.values["theme.dark"]?.updatedAtMs, 123)
    }

    /// The other two `v` variants and the oneof discriminator survive a round trip.
    func testPhiEntityRoundTripsStringAndIntValues() throws {
        var stringValue = Phi_PhiSettingValue()
        stringValue.updatedAtMs = 7
        stringValue.stringValue = "dracula"
        var intValue = Phi_PhiSettingValue()
        intValue.updatedAtMs = 9
        intValue.intValue = -42

        var s = Phi_PhiSettingEntity()
        s.values = ["theme.name": stringValue, "font.size": intValue]
        var e = Phi_PhiEntity()
        e.setting = s

        let back = try Phi_PhiEntity(serializedBytes: try e.serializedData())

        guard case .setting(let setting)? = back.kind else {
            return XCTFail("expected the `setting` variant of PhiEntity.kind")
        }
        XCTAssertEqual(setting.values["theme.name"]?.v, .stringValue("dracula"))
        XCTAssertEqual(setting.values["font.size"]?.v, .intValue(-42))
        XCTAssertEqual(setting.values["font.size"]?.updatedAtMs, 9)
    }

    /// Field-number proof: `phi` must serialise under tag 2000 (wire type 2), i.e.
    /// varint (2000 << 3) | 2 == 16002 -> bytes 0x82 0x7D. If the trimmed
    /// entity_specifics.proto ever drifts off 2000 the server stops seeing the
    /// payload, and this is the test that catches it.
    func testEntitySpecificsPhiUsesFieldNumber2000() throws {
        var phi = SyncPb_PhiSpecifics()
        phi.ciphertext = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var specifics = SyncPb_EntitySpecifics()
        specifics.phi = phi

        let bytes = [UInt8](try specifics.serializedData())

        // tag(2000, .lengthDelimited) == 0x82 0x7D, then the nested length.
        XCTAssertEqual(Array(bytes.prefix(3)), [0x82, 0x7D, 0x06])
        // PhiSpecifics.ciphertext is field 1, wire type 2 -> 0x0A, length 4.
        XCTAssertEqual(Array(bytes.suffix(6)), [0x0A, 0x04, 0xDE, 0xAD, 0xBE, 0xEF])

        let back = try SyncPb_EntitySpecifics(serializedBytes: Data(bytes))
        XCTAssertTrue(back.hasPhi)
        XCTAssertEqual(back.phi.ciphertext, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    /// A GetUpdates + Commit round trip over the trimmed sync_pb messages: the
    /// engine's request shape survives serialisation, and a response built from
    /// the same schema parses back with the phi ciphertext intact.
    func testClientToServerRoundTripCarriesPhiSpecifics() throws {
        var marker = SyncPb_DataTypeProgressMarker()
        marker.dataTypeID = 2000
        marker.token = Data([0x01, 0x02])

        var getUpdates = SyncPb_GetUpdatesMessage()
        getUpdates.fromProgressMarker = [marker]
        getUpdates.getUpdatesOrigin = .newClient

        var message = SyncPb_ClientToServerMessage()
        message.share = "account-id"
        message.messageContents = .getUpdates
        message.getUpdates = getUpdates
        message.storeBirthday = "birthday"

        let request = try SyncPb_ClientToServerMessage(serializedBytes: try message.serializedData())
        XCTAssertEqual(request.messageContents, .getUpdates)
        XCTAssertEqual(request.protocolVersion, 99, "protocol_version keeps its proto2 default")
        XCTAssertEqual(request.getUpdates.fromProgressMarker.first?.dataTypeID, 2000)
        XCTAssertEqual(request.getUpdates.fetchFolders, true, "fetch_folders keeps its proto2 default")

        var phi = SyncPb_PhiSpecifics()
        phi.ciphertext = Data([0x11, 0x22])
        var specifics = SyncPb_EntitySpecifics()
        specifics.phi = phi
        var entity = SyncPb_SyncEntity()
        entity.idString = "server-id"
        entity.version = 42
        entity.clientTagHash = "tag-hash"
        entity.specifics = specifics

        var updates = SyncPb_GetUpdatesResponse()
        updates.entries = [entity]
        updates.changesRemaining = 0
        var response = SyncPb_ClientToServerResponse()
        response.getUpdates = updates
        response.errorCode = .success
        response.storeBirthday = "birthday"

        let parsed = try SyncPb_ClientToServerResponse(serializedBytes: try response.serializedData())
        XCTAssertEqual(parsed.errorCode, .success)
        XCTAssertEqual(parsed.getUpdates.entries.first?.specifics.phi.ciphertext, Data([0x11, 0x22]))
        XCTAssertEqual(parsed.getUpdates.entries.first?.deleted, false, "deleted keeps its proto2 default")

        var entryResponse = SyncPb_CommitResponse.EntryResponse()
        entryResponse.responseType = .success
        entryResponse.idString = "server-id"
        entryResponse.version = 43
        var commit = SyncPb_CommitResponse()
        commit.entryResponse = [entryResponse]

        // EntryResponse is a proto2 *group*: it must encode with the start/end
        // group tags (field 1 -> 0x0B ... 0x0C), not as a length-delimited field.
        let commitBytes = [UInt8](try commit.serializedData())
        XCTAssertEqual(commitBytes.first, 0x0B)
        XCTAssertEqual(commitBytes.last, 0x0C)

        let parsedCommit = try SyncPb_CommitResponse(serializedBytes: Data(commitBytes))
        XCTAssertEqual(parsedCommit.entryResponse.first?.responseType, .success)
        XCTAssertEqual(parsedCommit.entryResponse.first?.version, 43)
    }

    /// Unknown fields survive: the server speaks the full Chromium schema, so the
    /// trimmed copies must not drop what they do not model.
    func testUnknownFieldsSurviveTheTrimmedSchema() throws {
        // EntitySpecifics field 37702 (preference) as a length-delimited empty
        // message, appended to a message the trimmed schema does understand.
        var specifics = SyncPb_EntitySpecifics()
        var phi = SyncPb_PhiSpecifics()
        phi.ciphertext = Data([0xAA])
        specifics.phi = phi
        var wire = try specifics.serializedData()
        wire.append(contentsOf: [0xB2, 0xB4, 0x12, 0x00])  // tag(37702, .lengthDelimited), len 0

        let parsed = try SyncPb_EntitySpecifics(serializedBytes: wire)
        XCTAssertEqual(parsed.phi.ciphertext, Data([0xAA]))
        XCTAssertFalse(parsed.unknownFields.data.isEmpty, "unknown specifics must be preserved")
        XCTAssertEqual(try parsed.serializedData(), wire, "re-serialising must not lose them")
    }
}
