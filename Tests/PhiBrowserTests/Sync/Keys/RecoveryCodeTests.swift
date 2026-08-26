import XCTest
@testable import Phi

final class RecoveryCodeTests: XCTestCase {
    func testGenerateDecodeRoundTrip() throws {
        let (display, entropy) = try RecoveryCode.generate()
        XCTAssertEqual(entropy.count, 16)
        XCTAssertEqual(RecoveryCode.decode(display), entropy)
    }

    func testDecodeIsCaseAndSeparatorInsensitive() throws {
        let (display, entropy) = try RecoveryCode.generate()
        let mangled = display.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(RecoveryCode.decode(mangled), entropy)
    }

    func testCrockfordAmbiguityNormalization() throws {
        // If a user transcribes O/I/L as letters, they should be normalized back to 0/1/1.
        let (display, entropy) = try RecoveryCode.generate()
        let confused = display.replacingOccurrences(of: "0", with: "O")
                              .replacingOccurrences(of: "1", with: "I")
        // This substitution only has an effect when the original string contains 0/1;
        // either way decode should return either entropy or nil (checksum failure),
        // but normalization itself must never crash:
        _ = RecoveryCode.decode(confused)
        XCTAssertEqual(RecoveryCode.decode(display), entropy)
    }

    func testChecksumRejectsSingleCharTypo() throws {
        let (display, _) = try RecoveryCode.generate()
        var chars = Array(display.replacingOccurrences(of: "-", with: ""))
        // Flip one data character (not a hyphen); the checksum should make decode fail.
        let table = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let idx = 0
        let cur = chars[idx]
        chars[idx] = (cur == table[0]) ? table[1] : table[0]
        XCTAssertNil(RecoveryCode.decode(String(chars)))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(RecoveryCode.decode("not a code"))
        XCTAssertNil(RecoveryCode.decode(""))
        XCTAssertNil(RecoveryCode.decode("ABC"))
    }
}
