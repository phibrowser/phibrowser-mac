import XCTest
import CryptoKit
@testable import Phi

final class PhiEntityCodecTests: XCTestCase {
    func testCodecRoundTripAndWrongKeyFails() throws {
        let key = SymmetricKey(size: .bits256)
        var e = Phi_PhiEntity(); var s = Phi_PhiSettingEntity()
        var v = Phi_PhiSettingValue(); v.updatedAtMs = 1; v.boolValue = true
        s.values = ["k": v]; e.setting = s
        let ct = try PhiEntityCodec.encrypt(e, key: key)
        XCTAssertEqual(try PhiEntityCodec.decrypt(ct, key: key).setting.values["k"]?.boolValue, true)
        XCTAssertThrowsError(try PhiEntityCodec.decrypt(ct, key: SymmetricKey(size: .bits256)))
    }
}
